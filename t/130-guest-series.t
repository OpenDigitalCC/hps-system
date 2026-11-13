#!/usr/bin/env perl
# Per-guest series (docs/MONITORING.md "Per guest"): the `vms` check's
# <vm>_<label> perfdata recorded per bucket under the guest's name, the guest
# list, a guest that disappears, and the cap per host.
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

my $p = HPS::Metrics::parse_perf('vms=2 a_cpu_pct=5.5 a_rss=1048576 a_mem=2097152 a_vcpus=2 a_rd_Bps=1 a_wr_Bps=2 a_rx_Bps=3 a_tx_Bps=4 my_db_cpu_pct=9 my_db_vcpus=1 bogus_x=1');
my $g = HPS::Metrics::guest_perf($p);
is_deeply([ sort keys %$g ], [ 'a', 'my_db' ], 'guest_perf: guests by name, an underscore in the name is kept, vms and other labels left out');
is_deeply($g->{a}, { cpu_pct => 5.5, rss => 1048576, mem => 2097152, vcpus => 2, rd_Bps => 1, wr_Bps => 2, rx_Bps => 3, tx_Bps => 4 }, 'guest_perf: the eight labels');
is_deeply($g->{my_db}, { cpu_pct => 9, vcpus => 1 }, 'guest_perf: a guest with fewer labels');
is_deeply(HPS::Metrics::guest_perf({ a_cpu_pct => 7 }), { a => { cpu_pct => 7 } }, 'guest_perf: plain values (the `last` shape) too');
is_deeply(HPS::Metrics::guest_perf(undef), {}, 'guest_perf: nothing');

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'sch-001');
my $now = timegm(0, 30, 8, 12, 10, 2026);
sub iso { strftime('%Y-%m-%dT%H:%M:%S', gmtime $_[0]) . '.123456+00:00' }
sub ev  { my ($t, $msg) = @_; return iso($t) . " metric ips hps: hps-monitor: $msg" }
sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }
my $t1 = $now - 400;    # bucket 08:20 at step 300
my $t2 = $now - 100;    # bucket 08:25
my $h = 'host=sch-001.hps.test';
my @l = (
    ev($t1, "$h check=vms state=OK VMS OK | vms=2 web_cpu_pct=10 web_rss=100 web_mem=200 web_vcpus=2 web_rd_Bps=5 db_cpu_pct=50 db_vcpus=1"),
    ev($t1 + 10, "$h check=vms state=OK VMS OK | vms=2 web_cpu_pct=30 web_rss=150 web_mem=200 web_vcpus=2 web_rd_Bps=1"),
    ev($t2, "$h check=vms state=OK VMS OK | vms=1 web_cpu_pct=20 web_rss=120 web_mem=200 web_vcpus=2 web_wr_Bps=7 web_rx_Bps=8 web_tx_Bps=9"),
);
my $logd = "$base/log";
make_path($logd);
spew("$logd/metrics.log", @l);
my $mx = HPS::Metrics->new(log_dir => $logd, registry => $reg, now => $now);

my $s = $mx->series('sch-001', hours => 1);
is_deeply($s->{guests}, [ 'db', 'web' ], 'series: lists the guests with samples');
ok(!exists $s->{raw}{web_cpu_pct}, 'series: guest labels are not mixed into the host raw values');

my $w = $mx->series('sch-001', hours => 1, guest => 'web');
is($w->{guest}, 'web', 'guest series: names the guest');
is($w->{host}, 'sch-001.hps.test', 'guest series: and the host');
my @t = @{ $w->{t} };
my %at = map { $t[$_] => $_ } 0 .. $#t;
my $b1 = $at{ int($t1 / 300) * 300 };
my $b2 = $at{ int($t2 / 300) * 300 };
is($w->{raw}{cpu_pct}[$b1], 30, 'guest series: the max in a bucket');
is($w->{raw}{cpu_pct}[$b2], 20, 'guest series: the next bucket');
is($w->{raw}{rss}[$b1], 150, 'guest series: rss');
is($w->{raw}{wr_Bps}[$b2], 7, 'guest series: wr_Bps');
ok(!defined $w->{raw}{wr_Bps}[$b1], 'guest series: a bucket without the label is null');
is_deeply($w->{units}, { cpu_pct => '%', rss => 'B', mem => 'B', vcpus => '', rd_Bps => 'B/s', wr_Bps => 'B/s', rx_Bps => 'B/s', tx_Bps => 'B/s' }, 'guest series: units');
is(scalar @{ $w->{raw}{cpu_pct} }, scalar @t, 'guest series: padded to the grid');

my $d = $mx->series('sch-001', hours => 1, guest => 'db');
is($d->{raw}{cpu_pct}[$b1], 50, 'a guest that disappears: its earlier sample is there');
ok(!defined $d->{raw}{cpu_pct}[$b2], 'a guest that disappears: null after, it simply stops');

my $e = eval { $mx->series('sch-001', hours => 1, guest => 'nope'); 1 } ? undef : $@;
is($e && $e->kind, 'notfound', 'an unknown guest: notfound');
$e = eval { $mx->series('sch-001', guest => '../x'); 1 } ? undef : $@;
is($e && $e->kind, 'usage', 'a bad guest name: usage');

done_testing;
