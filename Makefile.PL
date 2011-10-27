#!/usr/bin/env perl
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'Perlbal::Plugin::ConditionalFallback',
    VERSION_FROM  => 'lib/Perlbal/Plugin/ConditionalFallback.pm',
    AUTHOR        => 'Yann Kerherve <yannk@cpan.org>',
    ABSTRACT_FROM => 'lib/Perlbal/Plugin/ConditionalFallback.pm',

    PREREQ_PM     => {
        'Perlbal' => 0,
    },
);
