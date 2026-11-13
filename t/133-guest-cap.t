#!/usr/bin/env perl
# The cap on guests per host (HPS::Metrics::MAX_GUESTS): the first by name are kept.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::Local qw(timegm);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Metrics;

is(HPS::Metrics::MAX_GUESTS, 64, 'the cap is 64 guests per host');
my %p = map { sprintf('g%03d_cpu_pct', $_) => $_ } 1 .. 100;
my $g = HPS::Metrics::guest_perf(\%p);
is(scalar keys %$g, 64, 'guest_perf: 100 guests give 64');
ok($g->{g001} && $g->{g064} && !$g->{g065}, 'guest_perf: the first 64 by name');

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'sch-001');
my $now = timegm(0, 30, 8, 12, 10, 2026);
my $perf = join ' ', 'vms=100', map { sprintf('g%03d_cpu_pct=%d', $_, $_) } 1 .. 100;
my $line = strftime('%Y-%m-%dT%H:%M:%S', gmtime($now - 60)) . ".1+00:00 metric ips hps: hps-monitor: host=sch-001.hps.test check=vms state=OK VMS OK | $perf";
mkdir "$base/log";
open(my $fh, '>', "$base/log/metrics.log") or die; print {$fh} "$line\n"; close $fh;
my $mx = HPS::Metrics->new(log_dir => "$base/log", registry => $reg, now => $now);
my $s = $mx->series('sch-001', hours => 1);
is(scalar @{ $s->{guests} }, 64, 'series: at most 64 guests listed');
my $e = eval { $mx->series('sch-001', hours => 1, guest => 'g100'); 1 } ? undef : $@;
is($e && $e->kind, 'notfound', 'series: a guest past the cap has no series');
ok($mx->series('sch-001', hours => 1, guest => 'g064')->{raw}{cpu_pct}, 'series: the 64th has one');
done_testing;
