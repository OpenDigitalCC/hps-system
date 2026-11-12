#!/usr/bin/env perl
# hps-issue-watch (HPS::IssueWatch; docs/ISSUES.md): the rules file, matching
# marker and raw lines, and following the log tree: from the end at start (no
# replay), complete lines only, the state file across a restart (fresh: resume;
# stale: from the end), a new day file and a new sender. Fixture lines in
# t/data/issue-lines.log.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Issues;
use HPS::IssueWatch;

my $RULES = "$Bin/../lib/hps-issue-rules.conf";

#--- the rules file ------------------------------------------------------------------
my $rules = HPS::IssueWatch::load_rules($RULES);
is_deeply($rules->{marker}{'mirror-leg'}, { severity => 'warning', key_fields => [qw(host mirror)] },
    'shipped: mirror-leg markers keyed by host,mirror');
is(scalar @{ $rules->{rules} }, 8, 'shipped: eight raw-line rules');
is(scalar(grep { ($_->{from} // '') eq 'ips' } @{ $rules->{rules} }), 3, 'three of them for the IPS\'s own lines (from=ips)');

for my $bad (
    [ 'nonsense', qr/line 1: a rule is/ ],
    [ "# c\nopen Kind warning host x", qr/line 2: kind 'Kind'/ ],
    [ 'open k sometimes host x', qr/severity 'sometimes'/ ],
    [ 'resolve k warning host x', qr/a resolve rule has severity -/ ],
    [ 'open k warning Host x', qr/key fields 'Host'/ ],
    [ 'open k warning host', qr/no regex/ ],
    [ 'open k warning host (unclosed', qr/does not compile/ ],
    [ 'marker k warning host extra', qr/takes no regex/ ],
    [ 'open k warning host after=0/10 x', qr/after=N\/S needs/ ],
    [ 'resolve k - host after=2/10 x', qr/after= is for open rules/ ],
    [ 'open k warning host from=nodes x', qr/the only source is from=ips/ ],
    [ 'open k warning host settle=30 x', qr/settle= is for resolve rules/ ],
    [ 'resolve k - host urgent_after=60 x', qr/urgent_after= is for open rules/ ],
    [ 'open k warning host urgent_after=0 x', qr/needs S >= 1/ ],
) {
    my $e = eval { HPS::IssueWatch::parse_rules($bad->[0], 'r'); 1 } ? undef : $@;
    like(ref $e ? $e->message : "$e", $bad->[1], "bad rule refused: $bad->[0]");
}

#--- matching -------------------------------------------------------------------------
sub rec { my ($tag, $msg, $host) = @_; return { host => $host // 'tch-002.lab.hps', tag => $tag, message => $msg } }

my @m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=m1 component=/dev/sdb event=Fail'));
is(scalar @m, 1, 'a marker: one action');
is($m[0]{action}, 'open', 'open');
is_deeply($m[0]{key_fields}, [qw(host mirror)], 'keyed by the marker rule');
is($m[0]{fields}{component}, '/dev/sdb', 'every k=v is a field');
@m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=m1 component=- event=DegradedArray leg=iqn.2026-01.lab.nas:x@192.0.2.50:3260'));
is($m[0]{fields}{component}, '-', 'DegradedArray: component=- is a field');
is($m[0]{fields}{leg}, 'iqn.2026-01.lab.nas:x@192.0.2.50:3260', 'leg=<iqn>@<ip>:3260, last');
ok(eval { HPS::Issues::check_fields($m[0]{fields}); 1 }, 'both are valid field values');
@m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE resolve kind=mirror-leg host=tch-002 mirror=m1 event=SpareActive'));
is($m[0]{action}, 'resolve', 'a resolve marker');
@m = HPS::IssueWatch::match($rules, rec('x', 'HPS-ISSUE open kind=fan severity=urgent slot=3'));
is_deeply($m[0]{key_fields}, ['host'], 'a kind with no marker rule is keyed by host');
is($m[0]{fields}{host}, 'tch-002', 'host from the line when the marker has none (short name)');
is($m[0]{severity}, 'urgent', 'the marker\'s severity wins');
ok(!exists $m[0]{fields}{severity}, 'severity is not a field');
@m = HPS::IssueWatch::match($rules, rec('x', 'HPS-ISSUE open host=a'));
is($m[0]{action}, 'bad', 'a marker without kind is bad');
@m = HPS::IssueWatch::match($rules, rec('kernel', 'md/raid1:md127: Disk failure on sdb, disabling device.'));
is(scalar @m, 0, 'kernel md failure: no rule (the mdadm marker reports it by mirror name; no duplicate issue)');
@m = HPS::IssueWatch::match($rules, rec('iscsid', 'iscsid: connection2:0 is operational after recovery (9 attempts)'));
is_deeply([ map { "$_->{action} $_->{kind}" } @m ], ['resolve storage-path'], 'iscsid "iscsid: connectionN:M is operational after recovery" (the name repeated): resolve');
@m = HPS::IssueWatch::match($rules, rec('iscsid', 'iscsid: Connection2:0 to [target: iqn.2026-11.hps.s1:sch-002:probe-tch-001-b, portal: 10.113.1.11,3260] through [iface: default] is operational now'));
is_deeply([ map { "$_->{action} $_->{kind}" } @m ], ['resolve storage-path'], 'the login line "ConnectionN:M to [...] through [...] is operational now": resolve');
@m = HPS::IssueWatch::match($rules, rec('iscsid', 'iscsid: connect to 10.113.1.11:3260 failed (No route to host)'));
is($m[0]{fields}{portal}, '10.113.1.11:3260', 'the real failure line (name repeated) still opens storage-path');

# zfs: the kernel zio line (s1 drill, 2026-11-12)
@m = HPS::IssueWatch::match($rules, rec('kernel', 'zio pool=s1 vdev=/dev/disk/by-id/virtio-s1-sch-001-d3-part1 error=5 type=2 offset=62824448 size=8192 flags=3145856', 'sch-001'));
is(scalar @m, 1, 'zio error: one action');
is_deeply([ @{ $m[0] }{qw(action kind severity)} ], [qw(open zfs-vdev warning)], 'opens zfs-vdev (warning)');
is_deeply($m[0]{key_fields}, [qw(host pool vdev)], 'keyed by host, pool, vdev');
is_deeply([ @{ $m[0]{fields} }{qw(host pool vdev)} ], [qw(sch-001 s1 virtio-s1-sch-001-d3)], 'the vdev without -part1, as zpool status names it');
@m = HPS::IssueWatch::match($rules, rec('kernel', '[ 99.1] zio pool=lab vdev=/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S3Z9NB0K error=52 type=1', 'sch-001'));
is($m[0]{fields}{vdev}, 'ata-Samsung_SSD_860_EVO_1TB_S3Z9NB0K', 'a whole-disk vdev with no -partN, a time stamp in front');
@m = HPS::IssueWatch::match($rules, rec('kernel', 'zio pool=s1 vdev=/dev/sdc1 error=5 type=2'));
is(scalar @m, 0, 'a vdev outside /dev/disk/by-id: nothing');

# zfs: hps-monitor's zpool lines are rules for the IPS's own file only
my $mon = sub { rec('hps', "hps-monitor: host=sch-001.s1.hps check=zpool state=$_[0]", 'ips') };
@m = HPS::IssueWatch::match($rules, $mon->('WARNING ZPOOL WARNING - 1 pools: s1=DEGRADED | s1_cap=3%;80;90;0;100'), 1);
is_deeply([ @{ $m[0] }{qw(action kind severity)} ], [qw(open zfs-pool warning)], 'monitor WARNING: zfs-pool, warning');
is_deeply([ @{ HPS::Issues::check_fields($m[0]{fields}) }{qw(host pool health)} ], [qw(sch-001 s1 DEGRADED)], 'host (stored short) and pool from the line');
@m = HPS::IssueWatch::match($rules, $mon->('CRITICAL ZPOOL CRITICAL - 2 pools: fast=ONLINE s1=FAULTED | x'), 1);
is_deeply([ @{ $m[0] }{qw(action kind severity)} ], [qw(open zfs-pool urgent)], 'monitor CRITICAL: zfs-pool, urgent');
is($m[0]{fields}{pool}, 's1', 'the pool in that state, not the first');
@m = HPS::IssueWatch::match($rules, $mon->('OK ZPOOL OK - 1 pools: s1=ONLINE | s1_cap=3%;80;90;0;100'), 1);
is_deeply([ map { "$_->{action} $_->{kind} $_->{fields}{pool}" } @m ], ['resolve zfs-pool s1'], 'monitor OK: resolves zfs-pool of that pool');
@m = HPS::IssueWatch::match($rules, $mon->('WARNING ZPOOL WARNING - 1 pools: s1=DEGRADED'));
is(scalar @m, 0, 'the same line from a node\'s file: nothing (a node cannot speak for the monitor)');
@m = HPS::IssueWatch::match($rules, rec('hps', 'HPS-ISSUE open kind=x host=sch-001', 'ips'), 1);
is(scalar @m, 0, 'no marker is read from the IPS\'s own file');
@m = HPS::IssueWatch::match($rules, rec('iscsid', 'connect to 192.0.2.50:3260 failed (No route to host)'));
is($m[0]{kind}, 'storage-path', 'iscsid connect failure: storage-path');
is($m[0]{rule}{after_n}, 3, 'after 3');
@m = HPS::IssueWatch::match($rules, rec('sshd', 'Accepted publickey for root'));
is(scalar @m, 0, 'an ordinary line: nothing');

#--- following ------------------------------------------------------------------------------
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
# the hosts of this cluster, and the addresses they send syslog from
for my $h ([ '525400000012', 'tch-002', '10.9.0.12' ], [ '525400000013', 'tch-003', '10.9.0.13' ], [ '525400000010', 'sch-001', '10.9.0.10' ]) {
    $reg->host_set($h->[0], 'HOSTNAME', $h->[1]);
    $reg->host_set($h->[0], 'IP', $h->[2]);
}
my $logd = "$base/log";
make_path("$logd/10.9.0.12", "$logd/ips");

my $now = 1_794_470_400;    # 2026-11-12T08:00:00Z
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });
sub watcher { return HPS::IssueWatch->new(issues => $is, rules => $rules, log_dir => $logd, now => sub { $now }, @_) }
sub append { my ($f, $text) = @_; open(my $fh, '>>', $f) or die "$f: $!"; print {$fh} $text; close $fh }
my $f12 = "$logd/10.9.0.12/2026-11-12.log";

# history before the start: never replayed
append($f12, "Nov 12 07:00:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=old\n");
append("$logd/ips/2026-11-12.log", "Nov 12 07:00:00 127.0.0.1 [ips] hps: HPS-ISSUE open kind=x host=ips\n");
my $w = watcher();
$w->start;
is($w->poll, 0, 'start: nothing read from before the start');
is(scalar $is->all, 0, 'no issue from old lines');
ok(-f "$base/clusters/lab/issues/.watch-state.json", 'the state file is written');
like($log[-1], qr/watch started at the end of 1 file/, 'the start is logged');

# the fixture lines
open(my $fx, '<', "$Bin/data/issue-lines.log") or die $!;
my $fixture = do { local $/; <$fx> };
close $fx;
append($f12, $fixture);
@log = ();
is($w->poll, 11, 'the new lines are read');
my %by_key = map { $_->{key} => $_ } $is->list(all => 1);
my $leg = $by_key{'mirror-leg:tch-002:probe-tch-002-root'};
ok($leg, 'the marker opened mirror-leg:tch-002:probe-tch-002-root');
is($leg->{seen}, 2, 'its second open marker counted');
is($leg->{state}, 'resolved', 'the resolve marker resolved it');
like($leg->{trail}[-1]{detail}, qr/\Aby log tch-002 hps-issue: HPS-ISSUE resolve/, 'resolved by the line');
is($leg->{fields}{leg}, 'iqn.2026-01.lab.nas:hpslab-root@192.0.2.50:3260', 'the leg hint is a field');
is($leg->{fields}{component}, '/dev/sdb', 'the component is a field');
ok(!$by_key{'mirror-leg:tch-002:md127'}, 'the kernel md line opened no second mirror-leg issue');
my $sp = $by_key{'storage-path:tch-002'};
ok($sp, 'three iscsid failures opened storage-path:tch-002');
is($sp->{seen}, 1, 'at the third (the first two only counted)');
is($sp->{state}, 'resolved', 'the operational line resolved it');
ok(!$by_key{'leak:tch-002'}, 'a marker with a secret-looking field opens nothing');
is(scalar(grep { /ignored a line from tch-002/ } @log), 2, 'the two bad markers are logged as ignored');
ok(!(grep { /abc|0123/ } @log), 'the ignored lines\' text is not logged');
ok((grep { /\Awarning hps-issue: opened \S+ mirror-leg:tch-002:probe-tch-002-root\z/ } @log), 'opened logged');
ok((grep { /\Anotice hps-issue: resolved \S+ by log tch-002/ } @log), 'resolved logged');
is(scalar $is->list, 0, 'no unresolved issue left');

# a partial line waits for its newline
append($f12, 'Nov 12 08:01:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=part');
is($w->poll, 0, 'a line without its newline is not read');
append($f12, "ial\n");
is($w->poll, 1, 'it is read once complete');
ok($is->find_open('mirror-leg:tch-002:partial'), 'whole');

# a restart with a fresh state file resumes
append($f12, "Nov 12 08:02:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=down1\n");
$now += 60;
my $w2 = watcher();
$w2->start;
like($log[-1], qr/resuming 1 file\(s\) from the state of 60s ago/, 'fresh state: resumed');
is($w2->poll, 1, 'the line written while it was down is read');
ok($is->find_open('mirror-leg:tch-002:down1'), 'and acted on');

# a restart with a stale state file starts at the end
append($f12, "Nov 12 08:20:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=down2\n");
$now += 1000;
my $w3 = watcher();
$w3->start;
like($log[-1], qr/older than 300s: lines in between are not read/, 'stale state: says so');
is($w3->poll, 0, 'nothing old is read');
ok(!$is->find_open('mirror-leg:tch-002:down2'), 'and nothing opened');

# a new day file: the rest of the old one, then the new one from its start
append($f12, "Nov 12 23:59:59 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=late\n");
append("$logd/10.9.0.12/2026-11-13.log", "Nov 13 00:00:01 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=early\n");
is($w3->poll, 2, 'day roll: both lines read');
ok($is->find_open('mirror-leg:tch-002:late') && $is->find_open('mirror-leg:tch-002:early'), 'both acted on');

# a new sender after the start: its file from the start
make_path("$logd/10.9.0.13");
append("$logd/10.9.0.13/2026-11-13.log", "Nov 13 00:00:02 10.9.0.13 [tch-003] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-003 mirror=r\n");
is($w3->poll, 1, 'a new sender is read from its start');
ok($is->find_open('mirror-leg:tch-003:r'), 'and acted on');

# a truncated file is read again from its start
open(my $tr, '>', "$logd/10.9.0.13/2026-11-13.log") or die $!;
print {$tr} "Nov 13 00:01:00 10.9.0.13 [tch-003] x: y\n";
close $tr;
is($w3->poll, 1, 'a file that shrank is read from its start');

# the IPS's own directory is never read
append("$logd/ips/2026-11-12.log", "Nov 12 09:00:00 127.0.0.1 [ips] hps: HPS-ISSUE open kind=x host=ips\n");
is($w3->poll, 0, 'ips/ is not a sender');

# forwarded syslog of another cluster (the lab IPS receives s1's): its IPS is
# the sender; neither a host name this registry lacks nor one it has counts
make_path("$logd/10.9.0.99");
append("$logd/10.9.0.99/2026-11-13.log", join '',
    "Nov 13 00:02:00 10.9.0.99 [s1] hps-issue: HPS-ISSUE open kind=mirror-leg host=s1 mirror=x\n",
    "Nov 13 00:02:01 10.9.0.99 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=foreign-root\n",
    "Nov 13 00:02:02 10.9.0.99 [tch-009] kernel: zio pool=s1 vdev=/dev/disk/by-id/virtio-x-d3-part1 error=5 type=2\n",
    "Nov 13 00:02:03 10.9.0.99 [tch-009] kernel: zio pool=s1 vdev=/dev/disk/by-id/virtio-x-d3-part1 error=5 type=2\n");
@log = ();
is($w3->poll, 4, 'a foreign sender\'s lines are read');
ok(!$is->find_open('mirror-leg:s1:x'), 'a host this registry does not know opens nothing');
ok(!$is->find_open('mirror-leg:tch-002:foreign-root'), 'a host name of this cluster sent from another address opens nothing');
ok(!$is->find_open('zfs-vdev:tch-009:s1:virtio-x-d3'), 'nor does a raw-line rule');
is(scalar(grep { /ignoring lines of host tch-009 from 10\.9\.0\.99/ } @log), 1, 'logged once per host, not per line');
ok((grep { /ignoring lines of host s1 from 10\.9\.0\.99/ } @log), 'each foreign host said');

# a zio flood on a storage host: one zfs-vdev issue
make_path("$logd/10.9.0.10");
append("$logd/10.9.0.10/2026-11-13.log", join '', map {
    "Nov 13 00:03:0$_ 10.9.0.10 [sch-001] kernel: zio pool=s1 vdev=/dev/disk/by-id/virtio-s1-sch-001-d3-part1 error=5 type=2 offset=$_ size=8192 flags=3145856\n" } 1 .. 5);
is($w3->poll, 5, 'the zio lines are read');
my @zv = grep { $_->{kind} eq 'zfs-vdev' } $is->list;
is(scalar @zv, 1, 'five zio lines: one zfs-vdev issue');
is($zv[0]{key}, 'zfs-vdev:sch-001:s1:virtio-s1-sch-001-d3', 'keyed by host, pool and the vdev zpool status names');
is($zv[0]{seen}, 5, 'every line counted');

# storage-path, the real lines of the s1 drill (tch-001, 2026-11-12 15:17 to
# 15:22 UTC; iscsid repeats its name in the message)
append("$logd/10.9.0.12/2026-11-13.log", join '', map { "Nov 13 00:04:$_\n" } (
    '01 10.9.0.12 [tch-002] iscsid: iscsid: connect to 10.113.1.11:3260 failed (No route to host)',
    '02 10.9.0.12 [tch-002] iscsid: iscsid: connect to 10.113.1.11:3260 failed (No route to host)',
    '03 10.9.0.12 [tch-002] iscsid: iscsid: connect to 10.113.1.11:3260 failed (Connection refused)',
    '04 10.9.0.12 [tch-002] iscsid: iscsid: connection2:0 login rejected: initiator failed authorization with target'));
is($w3->poll, 4, 'the drill\'s failure lines are read');
my $spd = $is->find_open('storage-path:tch-002');
ok($spd, 'three failures (doubled iscsid: prefix): storage-path:tch-002 open');
is($spd->{fields}{portal}, '10.113.1.11:3260', 'naming the portal');
append("$logd/10.9.0.12/2026-11-13.log", "Nov 13 00:04:11 10.9.0.12 [tch-002] iscsid: iscsid: connection2:0 is operational after recovery (9 attempts)\n");
is($w3->poll, 1, 'the recovery line is read');
is($is->get($spd->{id})->{state}, 'resolved', '"iscsid: iscsid: connection2:0 is operational after recovery (9 attempts)" resolves it');
like($is->get($spd->{id})->{trail}[-1]{detail}, qr/by log tch-002 iscsid: iscsid: connection2:0 is operational after recovery/, 'by that line');

# the IPS's own hps lines (ips/hps): hps-monitor's zpool results
make_path("$logd/ips/hps");
append("$logd/ips/hps/2026-11-13.log", "Nov 13 00:00:00 127.0.0.1 [ips] hps: hps-monitor: host=sch-001.lab.hps check=zpool state=WARNING ZPOOL WARNING - 1 pools: s1=DEGRADED\n");
is($w3->poll, 1, 'ips/hps is followed (a new directory: from its start)');
my $zp = $is->find_open('zfs-pool:sch-001:s1');
ok($zp, 'the monitor WARNING opened zfs-pool:sch-001:s1');
like($zp->{summary}, qr/health=DEGRADED/, 'its summary says how the pool is');
append("$logd/ips/hps/2026-11-13.log", join '',
    "Nov 13 00:00:30 127.0.0.1 [ips] hps: hps-monitor: host=ghost-009.lab.hps check=zpool state=WARNING ZPOOL WARNING - 1 pools: s1=DEGRADED\n",
    "Nov 13 00:00:31 127.0.0.1 [ips] hps: HPS-ISSUE open kind=mirror-leg host=sch-001 mirror=from-ips\n",
    "Nov 13 00:01:00 127.0.0.1 [ips] hps: hps-monitor: host=sch-001.lab.hps check=zpool state=OK ZPOOL OK - 1 pools: s1=ONLINE\n");
is($w3->poll, 3, 'more IPS lines read');
ok(!$is->find_open('zfs-pool:ghost-009:s1'), 'a monitor line of a host not in the registry opens nothing');
ok(!$is->find_open('mirror-leg:sch-001:from-ips'), 'a marker in the IPS\'s own file is not read');
is($is->get($zp->{id})->{state}, 'resolved', 'the monitor OK resolved zfs-pool');
like($is->get($zp->{id})->{trail}[-1]{detail}, qr/by log ips hps: hps-monitor: .*state=OK/, 'by the monitor line');
my $w5 = watcher();
$w5->start;
ok(defined $w5->{pos}{'ips/hps'}, 'ips/hps is kept in the state file across a restart');

# om3 heartbeat send errors: one issue per host and peer, the end/begin pair of
# a changed error does not resolve it, a real end does after settle, urgent
# after 10 minutes
for my $l ('15:21:35.040 WRN daemon: hb: ucast: tx: hb#1: begin a send error period for node sch-002.s1.hps: dial tcp 10.11.0.10:0->10.11.0.11:10000: connect: connection refused',
           'daemon: hb: ucast: tx: hb#1: begin a send error period for node sch-002.s1.hps: dial tcp 10.11.0.10:0->10.11.0.11:10000: connect: no route to host') {
    @m = HPS::IssueWatch::match($rules, rec('om', $l, 'sch-001'));
    is_deeply([ map { "$_->{action} $_->{kind} $_->{fields}{host} $_->{fields}{peer}" } @m ], ['open om3-hb sch-001 sch-002'],
        'om3 begin a send error period (with or without its time and level): open om3-hb, peer short');
}
@m = HPS::IssueWatch::match($rules, rec('om', '15:21:30.622 INF daemon: hb: ucast: tx: hb#1: end a send error period for node sch-002.s1.hps: dial tcp x: i/o timeout', 'sch-001'));
is_deeply([ map { "$_->{action} $_->{kind} $_->{fields}{peer}" } @m ], ['resolve om3-hb sch-002'], 'end a send error period: resolve');
is($m[0]{rule}{settle}, 30, 'held back 30 s');
my ($omo) = grep { $_->{kind} eq 'om3-hb' && $_->{action} eq 'open' } @{ $rules->{rules} };
is($omo->{urgent_after}, 600, 'urgent after 10 minutes');

my $om = "$logd/10.9.0.10/2026-11-13.log";
my $omline = sub { my ($s, $what, $err) = @_;
    "Nov 13 00:10:$s 10.9.0.10 [sch-001] om: daemon: hb: ucast: tx: hb#1: $what a send error period for node tch-003.lab.hps: dial tcp 10.9.0.10:0->10.9.0.13:10000: $err\n" };
append($om, join '', map { $omline->(sprintf('%02d', $_), 'begin', 'connect: no route to host') } 1 .. 6);
$w3->poll;
my @hb = grep { $_->{kind} eq 'om3-hb' } $is->list;
is(scalar @hb, 1, 'six begin lines: one om3-hb issue');
is($hb[0]{key}, 'om3-hb:sch-001:tch-003', 'keyed by host and peer');
is($hb[0]{seen}, 6, 'all counted');
ok($hb[0]{urgent_at}, 'it carries its urgent_at');
append($om, $omline->('10', 'end', 'connect: no route to host') . $omline->('10', 'begin', 'connect: connection refused'));
$w3->poll;
$now += 31;
$w3->poll;
is($is->get($hb[0]{id})->{state}, 'open', 'end then begin at once (the error changed): still open, no churn');
is(scalar(grep { $_->{kind} eq 'om3-hb' } $is->list(all => 1)), 1, 'and no second issue');
$now += 600;
$w3->poll;
is($is->get($hb[0]{id})->{severity}, 'urgent', 'still open after 10 minutes: urgent');
is(scalar(grep { $_->{event} eq 'escalated' } @{ $is->get($hb[0]{id})->{trail} }), 1, 'escalated once');
$now += 60;
$w3->poll;
is(scalar(grep { $_->{event} eq 'escalated' } @{ $is->get($hb[0]{id})->{trail} }), 1, 'and only once');
append($om, $omline->('20', 'end', 'connect: connection refused'));
$w3->poll;
is($is->get($hb[0]{id})->{state}, 'open', 'a real end: not resolved at once');
$now += 29;
$w3->poll;
is($is->get($hb[0]{id})->{state}, 'open', 'nor before 30 s');
$now += 1;
$w3->poll;
is($is->get($hb[0]{id})->{state}, 'resolved', 'resolved once settled');
like($is->get($hb[0]{id})->{trail}[-1]{detail}, qr/by log sch-001 om: .*end a send error period/, 'by the end line');

# max_read: a big backlog is read in pieces, in order
my $w4 = watcher(max_read => 200);
$w4->start;
append("$logd/10.9.0.12/2026-11-13.log", join "", map { "Nov 13 01:00:00 10.9.0.12 [tch-002] x: filler line $_\n" } 1 .. 10);
my $total = 0;
for (1 .. 10) { $total += $w4->poll }
is($total, 10, 'a backlog larger than max_read is read over several polls');

# the watcher binary checks its rules
my $o = qx($^X $Bin/../bin/hps-issue-watch check-rules $RULES 2>&1);
is($? >> 8, 0, 'hps-issue-watch check-rules: exit 0');
like($o, qr/1 marker rule\(s\), 8 line rule\(s\)/, 'and counts them');
my $badf = "$base/bad.conf";
append($badf, "open x\n");
$o = qx($^X $Bin/../bin/hps-issue-watch check-rules $badf 2>&1);
is($? >> 8, 1, 'a bad rules file: exit 1');
like($o, qr/line 1/, 'naming the line');

done_testing;
