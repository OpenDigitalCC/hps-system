#!/usr/bin/env perl
# hps-metrics series <host> --guest <vm> (--json and text), and its refusals.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use POSIX qw(strftime);
use FindBin qw($Bin);

my $base = tempdir(CLEANUP => 1);
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/log");
use lib "$Bin/../lib/perl";
use HPS::Registry;
my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'sch-001');
my $t = time - 120;
my $line = strftime('%Y-%m-%dT%H:%M:%S', gmtime $t) . '.1+00:00 metric ips hps: hps-monitor: host=sch-001.hps.test check=vms state=OK VMS OK | vms=1 web_cpu_pct=12.5 web_rss=1048576 web_mem=2097152 web_vcpus=2';
open(my $fh, '>', "$base/log/metrics.log") or die; print {$fh} "$line\n"; close $fh;

local $ENV{HPS_LOG} = "$base/log";
local $ENV{HPS_CONFIG_BASE} = $base;
local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
my $bin = "$Bin/../bin/hps-metrics";
my $run = sub { my $out = qx{$^X $bin @_ 2>&1}; return ($? >> 8, $out) };

my ($rc, $out) = $run->('series', 'sch-001', '--guest', 'web', '--hours', '1', '--json');
is($rc, 0, '--guest --json exits 0');
my $d = decode_json($out);
is($d->{guest}, 'web', 'json: guest');
is_deeply([ sort keys %{ $d->{raw} } ], [qw(cpu_pct mem rss vcpus)], 'json: the labels the guest has');
is((grep { defined } @{ $d->{raw}{cpu_pct} })[0], 12.5, 'json: the value');
is($d->{units}{rss}, 'B', 'json: units');
($rc, $out) = $run->('series', 'sch-001', '--guest', 'web', '--hours', '1');
is($rc, 0, 'text exits 0');
like($out, qr/^# guest web on sch-001\.hps\.test$/m, 'text: heading');
like($out, qr/cpu_pct.*rss/, 'text: columns');
like($out, qr/\b12\.5\b/, 'text: value');
($rc, $out) = $run->('series', 'sch-001', '--hours', '1');
like($out, qr/^# guests with samples: web /m, 'plain series names the guests');
($rc) = $run->('series', 'sch-001', '--guest', 'nope', '--hours', '1');
is($rc, 4, 'unknown guest exits 4');
($rc) = $run->('series', 'all', '--guest', 'web');
is($rc, 2, '--guest with all is usage');
($rc) = $run->('last', 'sch-001', '--guest', 'web');
is($rc, 2, 'last takes no --guest');
done_testing;
