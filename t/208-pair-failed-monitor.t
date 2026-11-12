#!/usr/bin/env perl
# hps-monitor shows the hosts the IPS gave up pairing (registry pair_failed_at,
# set by the pairing approver after the last allowed reboot; incident
# 2026-11-12). Such a node is not paired, so it is never a check target.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Monitor;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'tch-001');
$reg->host_set('aabbccddee02', 'HOSTNAME', 'tch-002');
$reg->host_set('aabbccddee02', 'pair_failed_at', '1794321826');
$reg->host_set('aabbccddee02', 'pair_reboots', '3');

my @l = HPS::Monitor::pair_failed_lines($reg, 1794322000);
is(scalar @l, 1, 'one line: only the host with pair_failed_at');
is($l[0][0], 'err', 'logged at err');
like($l[0][1], qr/\Ahps-monitor: host=tch-002\.hps\.test state=PAIR_FAILED since=2026-\d\d-\d\dT\d\d:\d\d:\d\dZ reboots=3 /,
    'names the host by FQDN, the state, when and the reboots');

my %memo;
is(scalar HPS::Monitor::pair_failed_lines($reg, 1000, \%memo), 1, 'the loop logs it when first seen');
is(scalar HPS::Monitor::pair_failed_lines($reg, 1060, \%memo), 0, 'not again on the next tick');
is(scalar HPS::Monitor::pair_failed_lines($reg, 1600, \%memo), 1, 'again after 600 s');

$reg->host_set('aabbccddee02', 'pair_failed_at', 'soon');
is(scalar HPS::Monitor::pair_failed_lines($reg, 2000), 0, 'a value that is not an epoch is ignored');

open(my $fh, '<', "$Bin/../bin/hps-monitor") or die $!;
my $src = do { local $/; <$fh> };
like($src, qr/HPS::Monitor::pair_failed_lines\(\$reg, time, \$memo\)/, 'hps-monitor run emits the lines on every run');

done_testing;
