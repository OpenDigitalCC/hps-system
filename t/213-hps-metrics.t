#!/usr/bin/env perl
# hps-metrics (docs/MONITORING.md): hps-monitor's lines read back per host: the
# perfdata, the utilisation derivation, compound = max, the newest run, the
# bucketing, the two sources, own hosts only, and the CLI. A temp log tree and
# registry, a fixed clock.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::Local qw(timegm);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Metrics;

#--- perfdata and one line ---------------------------------------------------------
my $p = HPS::Metrics::parse_perf('busy=3.2%;80;90;0;100 /=22020096B load1=0.5 broken=1.2.3 cut=4');
is_deeply($p->{busy}, { value => 3.2, uom => '%' }, 'perf: value and unit, thresholds dropped');
is_deeply($p->{'/'}, { value => 22020096, uom => 'B' }, 'perf: a path label');
is($p->{load1}{uom}, '', 'perf: no unit');
ok(!exists $p->{broken}, 'perf: a malformed value is left out');
is(HPS::Metrics::parse_perf('a=1 b=2 s1-ips_rss=65')->{'s1-ips_rss'}{value}, 65, 'perf: a token cut short by syslog still reads as far as it goes');

my $m = HPS::Metrics::parse_message('hps-monitor: host=a.hps.test check=mem state=OK MEM OK - 62% available | available=10522MB available_pct=62%');
is($m->{kind}, 'check', 'message: a check line');
is($m->{text}, 'MEM OK - 62% available', 'message: the text without the perfdata');
is($m->{perf}{available_pct}{value}, 62, 'message: its perfdata');
is(HPS::Metrics::parse_message('hps-monitor: host=a.hps.test checks=6 worst=WARNING duration=1.4')->{worst}, 'WARNING', 'message: a summary line');
is(HPS::Metrics::parse_message('hps-monitor: host=a.hps.test state=UNREACHABLE timed out')->{kind}, 'unreachable', 'message: unreachable');
is(HPS::Metrics::parse_message('hps-monitor: host=a.hps.test state=PAIR_FAILED since=x reboots=3')->{kind}, 'pair_failed', 'message: pair failed');
is(HPS::Metrics::parse_message('hps-monitor: tick hosts=3 duration=1.9'), undef, 'message: a tick is not a host line');
is(HPS::Metrics::parse_message('hps-onboard: approved'), undef, 'message: another tool');

#--- utilisation -------------------------------------------------------------------
sub util {
    my ($line) = @_;
    my ($u, $r) = HPS::Metrics::utilisation(HPS::Metrics::parse_message("hps-monitor: host=a.hps.test $line"));
    return $u;
}
is_deeply(util('check=cpu state=OK CPU OK - 3.2% busy | busy=3.2% idle=96.8% cpus=4'), { cpu => 3.2 }, 'cpu = busy%');
is_deeply(util('check=mem state=OK MEM OK | available=1MB available_pct=62%'), { mem => 38 }, 'mem = 100 - available%');
is_deeply(util('check=load state=OK LOAD OK | load1=2.04 scaled_load1=0.128 load5=2'), { load => 12.8 }, 'load = scaled load1 x 100');
is_deeply(util('check=load state=OK LOAD OK | load1=20 scaled_load1=2.5'), { load => 100 }, 'load: capped at 100');
is_deeply(util('check=disk_srv state=OK DISK OK | srv_used_pct=41% srv_inode_pct=73% used=1B'), { disk => 73 }, 'disk: the worse of space and inodes');
is_deeply(util('check=disk_log state=WARNING DISK WARNING | used_pct=82% inode_pct=34%'), { disk => 82 }, 'disk: the IPS\'s own check');
is_deeply(util('check=disk_root state=OK DISK OK - free space: / 24063MiB (99.9% inode=97%); | /=22020096B'), { disk => 3 }, 'disk_root: 100 - the lower free% of its text');
is_deeply(util('check=zpool state=OK ZPOOL OK - 2 pools | lab_cap=9% big_cap=91%'), { pool => 91 }, 'pool = the fullest pool');
my ($du, $dr) = HPS::Metrics::utilisation(HPS::Metrics::parse_message("hps-monitor: host=a.hps.test " . 'check=diskio state=OK DISKIO OK | disks=2 sda_rd_Bps=100 sda_wr_Bps=5 sda_busy=12.5% sdb_rd_Bps=50 sdb_wr_Bps=0 sdb_busy=99%'));
is_deeply($du, { diskio => 99 }, 'diskio = the busiest device');
is_deeply($dr, { diskio_rd_Bps => 150, diskio_wr_Bps => 5 }, 'diskio: raw throughput summed over devices');
my ($nu, $nr) = HPS::Metrics::utilisation(HPS::Metrics::parse_message("hps-monitor: host=a.hps.test " . 'check=net state=OK NET OK | br_rx_Bps=10 br_tx_Bps=20 eno1_rx_Bps=12 eno1_tx_Bps=3 eno1_rx_errors=0c'));
is_deeply($nu, {}, 'net: no utilisation (no link capacity is known)');
is_deeply($nr, { net_rx_Bps => 12, net_tx_Bps => 20 }, 'net: the busiest interface each way');
is_deeply(util('check=procs state=OK PROCS OK | procs=25'), {}, 'procs: not a resource');
is_deeply(util('check=cpu state=UNKNOWN CPU UNKNOWN - no data'), {}, 'a check without perfdata: nothing');

is(HPS::Metrics::compound({ cpu => 10, mem => 38, load => 12.8, disk => 3, pool => 9 }), 38, 'compound = the max');
is(HPS::Metrics::compound({ cpu => 10, diskio => 100 }), 10, 'compound: diskio is not in it');
is(HPS::Metrics::compound({}), undef, 'compound: nothing known');
is(HPS::Metrics::level(69.9), 'ok', 'level: below 70 ok');
is(HPS::Metrics::level(70), 'warning', 'level: 70 warning');
is(HPS::Metrics::level(90), 'critical', 'level: 90 critical');
is(HPS::Metrics::level(undef), undef, 'level: none');

#--- options -----------------------------------------------------------------------
is_deeply(HPS::Metrics::options(), { hours => 24, step => 300 }, 'options: defaults');
for my $bad ([hours => 0], [hours => 169], [hours => 'x'], [step => 29], [step => 86401], [step => '60s']) {
    ok(!eval { HPS::Metrics::options(@$bad); 1 } && $@->kind eq 'usage', "options: --$bad->[0] $bad->[1] refused");
}
ok(!eval { HPS::Metrics::options(hours => 168, step => 30); 1 }, 'options: too many buckets refused');

#--- a registry and a log tree -----------------------------------------------------
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'sch-001');
$reg->host_set('aabbccddee02', 'HOSTNAME', 'tch-001');
$reg->host_set('aabbccddee03', 'HOSTNAME', 'bld-001');

my $now = timegm(0, 30, 8, 12, 10, 2026);    # 2026-11-12 08:30:00 UTC
sub iso { strftime('%Y-%m-%dT%H:%M:%S', gmtime $_[0]) . '.123456+00:00' }
sub ev  { my ($t, $msg, $from) = @_; return iso($t) . ' metric ' . ($from // 'ips') . " hps: hps-monitor: $msg" }
sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }

# sch-001: two runs; the older has a check (vms) the newer does not.
my $t1 = $now - 400;    # 08:23:20, bucket 08:20
my $t2 = $now - 100;    # 08:28:20, bucket 08:25
my @lines = (
    ev($t1, 'host=sch-001.hps.test check=cpu state=OK CPU OK | busy=95%'),
    ev($t1, 'host=sch-001.hps.test check=mem state=OK MEM OK | available_pct=50%'),
    ev($t1, 'host=sch-001.hps.test check=vms state=OK VMS OK | vms=1'),
    ev($t1, 'host=sch-001.hps.test checks=3 worst=OK duration=1.0'),
    ev($t1 + 10, 'host=sch-001.s1.hps check=cpu state=CRITICAL CPU CRITICAL | busy=100%', 's1.ips'),
    ev($t1 + 10, 'host=sch-001.s1.hps checks=1 worst=CRITICAL duration=1.0', 's1.ips'),
    ev($t1 + 20, 'host=tch-001.hps.test check=cpu state=OK CPU OK | busy=5%'),
    ev($t1 + 20, 'host=tch-001.hps.test checks=1 worst=OK duration=1.0'),
    ev($t1 + 30, 'tick hosts=2 duration=1.0'),
    ev($t2 - 30, 'host=sch-001.hps.test check=cpu state=WARNING CPU WARNING | busy=40%'),
    ev($t2 - 30, 'host=sch-001.hps.test check=mem state=OK MEM OK | available_pct=20%'),
    ev($t2 - 30, 'host=sch-001.hps.test checks=2 worst=WARNING duration=1.0'),
    ev($t2, 'host=sch-001.hps.test check=cpu state=OK CPU OK | busy=10%'),
    ev($t2, 'host=sch-001.hps.test check=mem state=OK MEM OK | available_pct=70%'),
    ev($t2, 'host=sch-001.hps.test check=disk_srv state=OK DISK OK | srv_used_pct=55% srv_inode_pct=2%'),
    ev($t2, 'host=sch-001.hps.test checks=3 worst=OK duration=1.0'),
    ev($t2 + 1, 'host=tch-001.hps.test state=UNREACHABLE hps-run exit 4: timed out'),
    ev($t2 + 2, 'host=ips.hps.test check=disk_log state=WARNING DISK WARNING | used_pct=86% inode_pct=34%'),
    ev($t2 + 2, 'host=ips.hps.test checks=1 worst=WARNING duration=0.0'),
    ev($t2 + 3, 'host=gone-001.hps.test check=cpu state=OK CPU OK | busy=1%'),
    ev($t2 + 3, 'host=gone-001.hps.test checks=1 worst=OK duration=0.0'),
    ev($t2 + 4, 'tick hosts=2 duration=1.0'),
);
my $logd = "$base/log";
make_path($logd);
spew("$logd/metrics.log", ev($now - 7200, 'host=bld-001.hps.test check=cpu state=OK CPU OK | busy=77%'),
    ev($now - 7200, 'host=bld-001.hps.test checks=1 worst=OK duration=1.0'), @lines);

my $mx = HPS::Metrics->new(log_dir => $logd, registry => $reg, now => $now, last_window => 900);

#--- latest ------------------------------------------------------------------------
my $l = $mx->latest('all');
is($l->{source}, 'metrics.log', 'latest: metrics.log is the source when it exists');
my %by = map { $_->{host} => $_ } @{ $l->{hosts} };
is_deeply([ sort keys %by ], [qw(gone-001.hps.test ips.hps.test sch-001.hps.test tch-001.hps.test)],
    'latest: own hosts only (the s1 lines forwarded from an inner IPS are left out; bld-001 is older than the window)');
my $s = $by{'sch-001.hps.test'};
is($s->{mac}, 'aabbccddee01', 'latest: the host\'s MAC from the registry');
is_deeply([ map { "$_->{check}=$_->{state}" } @{ $s->{checks} } ], [qw(cpu=OK mem=OK disk_srv=OK)],
    'latest: the checks of the newest run, in their order (vms of an older run is not carried over)');
is($s->{checks}[0]{perf}{busy}, 10, 'latest: perfdata values');
is($s->{worst}, 'OK', 'latest: the newest summary\'s worst');
is_deeply($s->{util}, { cpu => 10, mem => 30, disk => 55 }, 'latest: utilisation of the newest run');
is($s->{compound}, 55, 'latest: compound = the max');
is($s->{level}, 'ok', 'latest: its level');
is($s->{time}, strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $t2), 'latest: the time of the newest line');
my $tc = $by{'tch-001.hps.test'};
is($tc->{worst}, 'UNREACHABLE', 'latest: a newer UNREACHABLE line wins');
like($tc->{unreachable}, qr/timed out/, 'latest: with its reason');
is($tc->{checks}[0]{check}, 'cpu', 'latest: and the last run\'s checks are kept');
is($by{'ips.hps.test'}{name}, 'ips', 'latest: the IPS itself');
ok($by{'ips.hps.test'}{ips}, 'latest: marked ips');
is($by{'ips.hps.test'}{level}, 'warning', 'latest: 86% is a warning');
is($by{'gone-001.hps.test'}{mac}, undef, 'latest: a host no longer in the registry has no MAC');

my $one = $mx->latest('aa:bb:cc:dd:ee:01');
is(scalar @{ $one->{hosts} }, 1, 'latest <mac>: one host');
is($one->{target}, 'sch-001.hps.test', 'latest <mac>: its FQDN');
is($mx->latest('sch-001')->{hosts}[0]{compound}, 55, 'latest <hostname>');
is($mx->latest('ips')->{hosts}[0]{host}, 'ips.hps.test', 'latest ips');
ok(!eval { $mx->latest('bld-001'); 1 } && $@->kind eq 'notfound', 'latest: no result in the window is notfound');
ok(!eval { $mx->latest('nope-001'); 1 } && $@->kind eq 'notfound', 'latest: an unknown host is notfound');

#--- series ------------------------------------------------------------------------
my $sr = $mx->series('sch-001', hours => 1, step => 300);
is(scalar @{ $sr->{t} }, 12, 'series: hours x 3600 / step buckets');
is($sr->{t}[-1], $now - $now % 300, 'series: the last bucket holds now');
is($sr->{t}[1] - $sr->{t}[0], 300, 'series: step apart');
my ($b1) = grep { $sr->{t}[$_] <= $t1 && $t1 < $sr->{t}[$_] + 300 } 0 .. 11;
my ($b2) = grep { $sr->{t}[$_] <= $t2 && $t2 < $sr->{t}[$_] + 300 } 0 .. 11;
is($sr->{util}{cpu}[$b1], 95, 'series: older bucket');
is($sr->{util}{cpu}[$b2], 40, 'series: the max within a bucket (40 and 10)');
is($sr->{util}{mem}[$b2], 80, 'series: mem max within the bucket (80 and 30)');
is($sr->{compound}[$b2], 80, 'series: compound = the max per bucket');
is($sr->{compound}[$b1], 95, 'series: compound of the older bucket');
is($sr->{state}{cpu}[$b2], 'OK', 'series: the last state in a bucket');
is($sr->{state}{_host}[$b2], 'OK', 'series: the host\'s last worst');
is($sr->{util}{cpu}[0], undef, 'series: an empty bucket is null');
is(scalar @{ $sr->{util}{cpu} }, 12, 'series: every array has a slot per bucket');
is_deeply($sr->{in_compound}, [qw(cpu mem disk)], 'series: the resources it has');
is($sr->{current}, 80, 'series: current = the newest compound');
is($sr->{level}, 'warning', 'series: its level');
is($sr->{mac}, 'aabbccddee01', 'series: the MAC');

my $tcs = $mx->series('tch-001', hours => 1, step => 300);
is($tcs->{state}{_host}[$b2], 'UNREACHABLE', 'series: UNREACHABLE in the host state');

my $all = $mx->series('all', hours => 3, step => 600);
my %ab = map { $_->{host} => $_ } @{ $all->{hosts} };
ok(!$ab{'sch-001.s1.hps'}, 'series all: own hosts only');
is($ab{'bld-001.hps.test'}{current}, 77, 'series all: a host seen inside the window');
is(scalar @{ $ab{'sch-001.hps.test'}{compound} }, 18, 'series all: every host has every bucket');
ok(!exists $ab{'sch-001.hps.test'}{util}, 'series all: the compound only');
is($ab{'ips.hps.test'}{level}, 'warning', 'series all: the IPS too');

#--- the product source: ips/hps/<date>.log --------------------------------------
my $logp = "$base/plog";
make_path("$logp/ips/hps");
sub sl { my ($t, $msg) = @_; return strftime('%b %e %H:%M:%S', gmtime $t) . " 127.0.0.1 [ips] hps:  hps-monitor: $msg" }
spew("$logp/ips/hps/2026-11-11.log", sl($now - 86400, 'host=sch-001.hps.test check=cpu state=OK CPU OK | busy=60%'),
    sl($now - 86400, 'host=sch-001.hps.test checks=1 worst=OK duration=1.0'));
spew("$logp/ips/hps/2026-11-12.log",
    strftime('%b %e %H:%M:%S', gmtime $t2) . ' 127.0.0.1 [ips] hps-jobs: hps-monitor: host=sch-001.hps.test check=cpu state=OK x | busy=99%',
    sl($t2, 'host=sch-001.hps.test check=cpu state=OK CPU OK | busy=20%'),
    sl($t2, 'host=sch-001.hps.test checks=1 worst=OK duration=1.0'));
my $mp = HPS::Metrics->new(log_dir => $logp, registry => $reg, now => $now, last_window => 900);
my $pl = $mp->latest('sch-001');
is($pl->{source}, 'syslog ips/hps', 'latest: without metrics.log, the IPS\'s own ips/hps files');
is($pl->{hosts}[0]{compound}, 20, 'latest: read from the syslog line (another tag is ignored)');
my $ps = $mp->series('sch-001', hours => 25, step => 3600);
is((grep { defined } @{ $ps->{util}{cpu} })[0], 60, 'series: the day before, from its own file');
is($ps->{current}, 20, 'series: and today');

my $empty = HPS::Metrics->new(log_dir => "$base/none", registry => $reg, now => $now);
is($empty->latest('all')->{source}, 'none', 'no source: says so');
is_deeply($empty->latest('all')->{hosts}, [], 'no source: no hosts');

#--- CLI ----------------------------------------------------------------------------
{
    local $ENV{HPS_LOG} = $logd;
    local $ENV{HPS_CONFIG_BASE} = $base;
    local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
    my $bin = "$Bin/../bin/hps-metrics";
    my $run = sub { my $out = qx{$^X $bin @_ 2>&1}; return ($? >> 8, $out) };
    my ($rc, $out) = $run->('series', 'all', '--hours', '1', '--json');
    is($rc, 0, 'cli: series all exits 0');
    my $d = eval { decode_json($out) };
    is(ref $d->{hosts}, 'ARRAY', 'cli: --json');
    ($rc, $out) = $run->('series', 'sch-001', '--hours', '1');
    is($rc, 0, 'cli: text series');
    like($out, qr/^# source metrics\.log/, 'cli: text names the source');
    ($rc) = $run->('last', 'all');
    is($rc, 0, 'cli: last all');
    ($rc) = $run->('last');
    is($rc, 2, 'cli: no target is usage');
    ($rc) = $run->('last', 'all', '--hours', '2');
    is($rc, 2, 'cli: last takes no --hours');
    ($rc) = $run->('series', 'all', '--step', '5');
    is($rc, 2, 'cli: a bad step is usage');
    ($rc) = $run->('graph', 'all');
    is($rc, 2, 'cli: unknown command');
    ($rc) = $run->('last', 'nope-001');
    is($rc, 4, 'cli: unknown host exits 4');
}

done_testing;
