package Perlbal::Plugin::ConditionalFallback;

use strict;
use warnings;

=pod

=head1 USAGE

  ## proposed scenario: You have an old site and a newer one
  ## sharing the same uri namespace, you want to slowly migrate from the
  ## old one to the new one. Every GET request will be sent first
  ## to the new site, and if the response code is 404, then you
  ## fallback to the old site.

  LOAD ConditionalFallback
  CREATE POOL new
    POOL new ADD 127.0.0.1:10000

  CREATE POOL old
    POOL old ADD 127.0.0.1:10001

  CREATE SERVICE old_service
    SET role            = reverse_proxy
    SET pool            = old
  ENABLE old_service

  CREATE SERVICE bouncer
    SET listen           = 0.0.0.0:10081
    SET role             = reverse_proxy
    SET pool             = new            # first proxy to there...
    SET fallback_if_rc   = 404,415        # ... if response code is 404 or 415
    SET fallback_service = old_service    # ... then fallback to old stack
  SET plugins            = ConditionalFallback
  ENABLE bouncer

  ## Alternatively one can write
  ## SET fallback_if_rc = !200,302
  ## to always fallback unless response code is 200 or 302

=cut

use Perlbal;
use Perlbal::BackendHTTP;
use Perlbal::ClientHTTPBase;
use Perlbal::ClientProxy;
use Perlbal::Service;
use Perlbal::HTTPHeaders;

use constant CONTINUE_PROCESSING => 0;
use constant STOP_PROCESSING     => 1;

sub load {
    my $class = shift;
    Perlbal::Service::add_tunable(
        fallback_service => {
            default => "",
            des => "Which service to fallback to",
            check_type => sub {
                my ($self, $val, $errref) = @_;
                return 1 unless $val;
                if (Perlbal->service($val)) {
                    return 1;
                }
                $$errref = "Unknown service $val";
                return 0;
            },
            check_role => "reverse_proxy",
        },
    );
    Perlbal::Service::add_tunable(
        fallback_if_rc => {
            default => "404",
            des => "comma separated list of status codes triggering a fallback. Alternatively, if the list start with a bang '!' then the logical clause is negated.",
            check_type => [
                "regexp",
                qr/^!?[1-5]\d\d(,[1-5]\d\d)*$/,
                "Expecting a comma separated list of numeric status codes, optionally starting by '!'.",
            ],
            check_role => "reverse_proxy",
        },
    );
    return 1;
}

sub unload {
    my $class = shift;
    Perlbal::Service::remove_tunable('fallback_service');
    Perlbal::Service::remove_tunable('fallback_if_rc');
    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    $svc->selector(undef);
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    unless ($svc && $svc->{role} eq "reverse_proxy") {
        die "ConditionalFallback must run as ROLE=reverse_proxy, "
          . "not $svc->{role}";
    }


    # return_to_base hook:
    # After a response comes back from the fallback service,
    # we need to return to the original service (the reverse_proxy
    # service this plugin is initially registered to).
    # The behavior without this hook would be to return_to_base
    # on the fallback service, which is not what we want.
    $svc->register_hook(
        ConditionalFallback => return_to_base => sub {
            my Perlbal::ClientHTTPBase $client = shift;
            $client->{service} = $svc;
            return STOP_PROCESSING;
        }
    );

    #backend_response_received hook
    $svc->register_hook(
        ConditionalFallback => backend_response_received => sub {
            my Perlbal::BackendHTTP $be = shift;
            print "ConditionalFallback backend_response_received\n"
                if Perlbal::DEBUG >= 3;
            return CONTINUE_PROCESSING unless $be;

            ## we cannot fallback if the request has a body
            return CONTINUE_PROCESSING unless $be->{req_headers};
            my $content_length = $be->{req_headers}->content_length;
            return CONTINUE_PROCESSING
                if defined $content_length && $content_length > 0;

            my $res_headers = $be->{res_headers};
            return CONTINUE_PROCESSING unless $res_headers;

            ## conditionally fallback
            if (should_fallback($svc, $res_headers->response_code)) {
                my $client = $be->{client};

                my $cfg = $svc->{extra_config};
                my $fallback_svc = $cfg->{_fallback_service}
                               ||= Perlbal->service($cfg->{fallback_service});

                return CONTINUE_PROCESSING unless $fallback_svc;
                fallback($client, $be, $fallback_svc);
                print "Condition Succeeded: fallback "
                    . "to $cfg->{fallback_service}\n" if Perlbal::DEBUG >= 3;
                return STOP_PROCESSING;
            }
            print "Condition Failed: no fallback\n" if Perlbal::DEBUG >= 3;
            return CONTINUE_PROCESSING;
        }
    );

    return 1;
}

sub should_fallback {
    my ($svc, $rc) = @_;
    my ($hash, $neg) = @{ get_condition_config($svc) };
    if ($hash->{$rc}) {
        return $neg ? 0 : 1;
    }
    return $neg ? 1: 0;
}

sub get_condition_config {
    my $svc = shift;
    my $cfg = $svc->{extra_config};
    unless ($cfg->{_fallback_if_rc}) {
        my $rc_cond = $cfg->{fallback_if_rc};
        my $neg = ($rc_cond =~ s/^!//);
        my %hash = map { $_ => 1 } split /,/, $rc_cond;
        $cfg->{_fallback_if_rc} = [ \%hash, $neg ];
    }
    return $cfg->{_fallback_if_rc};
}


sub fallback {
    my $client = shift;
    my $be = shift;
    my $fallback_svc = shift;

    my $svc = $be->{service};

    ## reset client state
    $client->{backend_requested} = 0;
    $client->{backend} = undef;

    ## release current backend
    $be->next_request;

    ## trigger return_to_base hook. Without a selector_svc set,
    ## it doesn't trigger it.
    $client->{selector_svc} = $svc;
    $fallback_svc->adopt_base_client($client);
}

1;
