#!/usr/bin/env perl
# HPS_CONFIG_BASE defaults to /srv/hps-config (as the Bash side does), so
# bin/hps-onboard runs without the variable.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;

{
    local $ENV{HPS_CONFIG_BASE};
    delete $ENV{HPS_CONFIG_BASE};
    my $reg = HPS::Registry->new;
    is($reg->config_base, '/srv/hps-config', 'default config base when HPS_CONFIG_BASE is unset');
}
{
    local $ENV{HPS_CONFIG_BASE} = '/tmp/elsewhere';
    is(HPS::Registry->new->config_base, '/tmp/elsewhere', 'the environment wins over the default');
    is(HPS::Registry->new(config_base => '/x')->config_base, '/x', 'the argument wins over the environment');
}

# The CLI no longer dies with "HPS_CONFIG_BASE is not set".
{
    my $dir = tempdir(CLEANUP => 1);
    delete local $ENV{HPS_CONFIG_BASE};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$dir/system.db";
    local $ENV{HPS_ONBOARD_NETCONF_CMD} = '';
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", 'show', '52:54:00:00:00:99');
    my $out = qx(@cmd 2>&1);
    unlike($out, qr/HPS_CONFIG_BASE is not set/, 'hps-onboard does not demand HPS_CONFIG_BASE');
}

done_testing;
