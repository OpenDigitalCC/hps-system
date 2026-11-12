#!/usr/bin/env perl
# ZFS pool disks (s1 drill 2026-11-12: a pool disk hot-unplugged and returned
# stayed REMOVED; nodes run no ZED): HPS::Storage vdev-online (one
# storage-vdev-online call), hps-storage vdev-online, and the zfs-vdev healer
# (HPS::IssueHeal) on the fake runner: not present is retried with the backoff,
# onlined with a resilver is healing, ONLINE without one resolves, and the
# zfs-pool issue of that host and pool resolves with the last of its vdevs.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Issues;
use HPS::IssueHeal;

my $MAC = $StorageFixture::MAC;
my $V   = 'virtio-s1-sch-001-d3';

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

#--- HPS::Storage vdev-online ------------------------------------------------------------
ok(scalar(grep { $_ eq 'vdev-online' } HPS::Storage::ops()), 'vdev-online is an op');
{
    my $f = StorageFixture::setup(ce => { out => { 'storage-vdev-online' => "POOL s1 ONLINE\nVDEV s1 $V ONLINE resilver=yes\n" } });
    my $st = $f->{mk}->(pool => 's1');
    my $r = $st->run('vdev-online', vdev => $V);
    ok($r->{ok}, 'vdev-online runs');
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ], [ [ 'storage-vdev-online', 's1', $V ] ],
        'one storage-vdev-online <pool> <vdev> call');
    is(($f->{ce}->calls)[0]{input}, undef, 'no input');
    $f->{mk}->(pool => 's1')->run('vdev-online', vdev => "/dev/disk/by-id/$V");
    is_deeply(($f->{ce}->calls)[1]{args}, [ 's1', $V ], 'a /dev/disk/by-id/ prefix is taken off');
    for my $bad (undef, '', "../$V", 'a..b', "$V;x", "$V x", '/dev/sdc', '-x', 'x' x 129) {
        my $e = err_of(sub { $st->run('vdev-online', vdev => $bad) });
        is(ref $e && $e->kind, 'usage', 'bad vdev ' . ($bad // 'undef') . ': usage');
    }
    is(scalar($f->{ce}->calls), 2, 'refusals called nothing');
}
{
    my $f = StorageFixture::setup(ce => { rc => { 'storage-vdev-online' => 3 },
        err => { 'storage-vdev-online' => "[storage-vdev-online] not present: /dev/disk/by-id/$V does not exist\n" } });
    my $e = err_of(sub { $f->{mk}->(pool => 's1')->run('vdev-online', vdev => $V) });
    is($e->kind, 'refused', 'the node refusing (not present, exit 3) is a refusal');
    like($e->message, qr/not present/, 'with the node\'s words');
}

#--- hps-storage vdev-online ------------------------------------------------------------------
{
    my $f   = StorageFixture::setup();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}       = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}   = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}           = "$tmp/hps-run";
    local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
    local $ENV{SHIM_DIR}              = $tmp;
    local $ENV{SUDO_USER}             = 'tester';
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-storage", @_);
        my $out = qx(@cmd 2>&1);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $cli->($MAC, 'vdev-online', 's1');
    is($rc, 2, 'vdev-online without a vdev: usage');
    ($rc, $out) = $cli->($MAC, 'vdev-online', 's1', $V, 'x');
    is($rc, 2, 'an extra argument: usage');
    ok(!-e "$tmp/args", 'usage errors call nothing');
    ($rc, $out) = $cli->($MAC, 'vdev-online', 's1', $V, '--dry-run');
    is($rc, 0, '--dry-run: 0');
    like($out, qr{1\. storage-vdev-online s1 \Q$V\E}, 'the call is shown');
    ok(!-e "$tmp/args", 'a dry run calls nothing');
    ($rc, $out) = $cli->($MAC, 'vdev-online', 's1', $V);
    is($rc, 0, 'vdev-online runs');
    like($out, qr{== 1\. storage-vdev-online s1 \Q$V\E \(exit 0\)}, 'result shown');
    open(my $h, '<', "$tmp/args") or die;
    like(do { local $/; <$h> }, qr{^--json $MAC storage-vdev-online s1 \Q$V\E$}m, 'sent to the host');
}

#--- the zfs-vdev healer ------------------------------------------------------------------------
my $f   = StorageFixture::setup();
my $now = 1_794_496_380;
my @log;
my $is = HPS::Issues->new(registry => $f->{reg}, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });

sub healer {
    my (%ce) = @_;
    my $ce = FakeCE->new(%ce);
    return (HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $now }), $ce);
}

sub vdev_out { my ($state, $resilver, $health) = @_; return "POOL s1 " . ($health // 'DEGRADED') . "\nVDEV s1 $V $state resilver=$resilver\n" }

my $ONLINED = "+ zpool status s1\n+ readlink -e /dev/disk/by-id/$V\n+ zpool online s1 $V\n+ zpool clear s1 $V\n+ zpool status s1\n";
my $ABSENT  = "+ zpool status s1\n+ readlink -e /dev/disk/by-id/$V\n[storage-vdev-online] not present: /dev/disk/by-id/$V does not exist ($V is REMOVED); ask again when the disk is back\n";

sub open_vdev {
    my (%fields) = @_;
    my ($r) = $is->open_issue(kind => 'zfs-vdev', key_fields => [qw(host pool vdev)],
        fields => { host => 'sch-001', pool => 's1', vdev => $V, %fields });
    return $r->{id};
}

# the drill: the disk away for 2 minutes, then back
my ($pool) = $is->open_issue(kind => 'zfs-pool', key_fields => [qw(host pool)], fields => { host => 'sch-001', pool => 's1', health => 'DEGRADED' });
my $id = open_vdev();
my ($h, $ce) = healer(
    rc  => { 'storage-vdev-online' => [ 3, 3, 0, 0, 0 ] },
    out => { 'storage-vdev-online' => [ vdev_out('REMOVED', 'no'), vdev_out('REMOVED', 'no'), vdev_out('ONLINE', 'yes'),
        vdev_out('ONLINE', 'yes'), vdev_out('ONLINE', 'no', 'ONLINE') ] },
    err => { 'storage-vdev-online' => [ $ABSENT, $ABSENT, $ONLINED, "+ zpool status s1\n", "+ zpool status s1\n" ] });
is($h->tick, 0, 'first sight: scheduled');
$now += 30;
is($h->tick, 1, 'at its time: one heal');
my @c = $ce->calls;
is_deeply([ $c[0]{script}, @{ $c[0]{args} } ], [ 'storage-vdev-online', 's1', $V ], 'storage-vdev-online <pool> <vdev>');
is($c[0]{mac}, $MAC, 'on the issue\'s host');
my $r = $is->get($id);
is($r->{state}, 'open', 'not present: a failed attempt, still open');
is($r->{heal}{next_at}, $now + 60, 'retried after 60 s');
like($r->{heal}{last_result}, qr/\Afailed: storage-vdev-online s1 \Q$V\E exit 3: \Q$V\E REMOVED resilver=no \(not present/, 'saying not present');
$now += 60;
$h->tick;
$r = $is->get($id);
is($r->{heal}{attempts}, 2, 'second attempt, still not present');
is($r->{heal}{next_at}, $now + 120, 'then 2 min');
$now += 120;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'healing', 'the disk back: onlined, resilvering: healing');
is($r->{heal}{attempts}, 3, 'the online counted as an attempt');
is($r->{heal}{next_at}, $now + 30, 'checked again in 30 s');
$now += 30;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'healing', 'resilver still running: healing');
is($r->{trail}[-1]{event}, 'check', 'a check, not an attempt');
is($r->{heal}{attempts}, 3, 'attempts unchanged');
is($is->get($pool->{id})->{state}, 'open', 'the zfs-pool issue stays open meanwhile');
$now += 30;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'resolved', 'ONLINE, no resilver: resolved');
like($r->{trail}[-1]{detail}, qr/by zpool status: \Q$V\E ONLINE, no resilver/, 'by zpool status');
is_deeply({ map { $_ => $r->{resolution}{$_} } qw(by action result) },
    { by => 'healer', action => "zpool online s1 $V; zpool clear", result => "$V ONLINE, resilver finished" },
    'resolution: the online and clear of two checks earlier, ONLINE with the resilver finished');
my $p = $is->get($pool->{id});
is($p->{state}, 'resolved', 'the pool ONLINE and its last zfs-vdev resolved: zfs-pool resolved');
like($p->{trail}[-1]{detail}, qr/by zpool status: pool s1 ONLINE \(issue \Q$id\E healed\)/, 'saying why');
is_deeply({ map { $_ => $p->{resolution}{$_} } qw(by action result) },
    { by => 'healer', action => "zpool online s1 $V; zpool clear", result => "pool s1 ONLINE (zfs-vdev $id healed)" },
    'the pool\'s resolution names the vdev\'s action');
is(scalar(grep { $_->{event} eq 'escalated' } @{ $r->{trail} }), 0, 'never escalated');
$now += 3600;
is($h->tick, 0, 'a resolved issue is never touched again');

# a zio error on a vdev ZFS kept ONLINE: resolved at the first look
$id = open_vdev(vdev => 'virtio-s1-sch-001-d1');
($h, $ce) = healer(out => { 'storage-vdev-online' => "POOL s1 ONLINE\nVDEV s1 virtio-s1-sch-001-d1 ONLINE resilver=no\n" },
    err => { 'storage-vdev-online' => "+ zpool status s1\n[storage-vdev-online] virtio-s1-sch-001-d1 is ONLINE in s1; nothing to do\n" });
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'resolved', 'already ONLINE, no resilver: resolved');
is($r->{trail}[-2]{event}, 'check', 'a check (nothing was onlined), not an attempt');
ok(!$r->{heal}{attempts}, 'no attempt counted');
is_deeply({ map { $_ => $r->{resolution}{$_} } qw(by action result) },
    { by => 'healer', action => '-', result => 'virtio-s1-sch-001-d1 ONLINE, no resilver running' },
    'nothing done: action -, the evidence as the result');

# the pool stays open while another zfs-vdev of it is unresolved, or the pool is not ONLINE
($pool) = $is->open_issue(kind => 'zfs-pool', key_fields => [qw(host pool)], fields => { host => 'sch-001', pool => 's1' });
my $other = open_vdev(vdev => 'virtio-s1-sch-001-d2');
$is->update($other, sub { $_[0]{heal} = { attempts => 0, next_at => $now + 99_999 } });
$id = open_vdev();
($h, $ce) = healer(out => { 'storage-vdev-online' => vdev_out('ONLINE', 'no', 'ONLINE') });
$h->tick; $now += 30; $h->tick;
is($is->get($id)->{state}, 'resolved', 'the vdev resolved');
is($is->get($pool->{id})->{state}, 'open', 'another zfs-vdev of the pool unresolved: zfs-pool stays open');
$is->resolve($other, 'test');
$id = open_vdev();
($h, $ce) = healer(out => { 'storage-vdev-online' => vdev_out('ONLINE', 'no', 'DEGRADED') });
$h->tick; $now += 30; $h->tick;
is($is->get($id)->{state}, 'resolved', 'the vdev resolved');
is($is->get($pool->{id})->{state}, 'open', 'the pool still DEGRADED (another disk): zfs-pool stays open');
$is->resolve($pool->{id}, 'test');

# refusals other than not present: a human decision
$id = open_vdev();
($h, $ce) = healer(rc => { 'storage-vdev-online' => 3 }, out => { 'storage-vdev-online' => "POOL s1 DEGRADED\nVDEV s1 $V DEGRADED resilver=no\n" },
    err => { 'storage-vdev-online' => "[storage-vdev-online] refused: $V is DEGRADED in s1: online does not apply (a human decision)\n" });
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'needs-human', 'exit 3 other than not present: needs-human');
is($r->{severity}, 'urgent', 'urgent');
my $n = scalar $ce->calls;
$now += 86400;
$h->tick;
is(scalar $ce->calls, $n, 'needs-human: never retried');
$is->resolve($id, 'test');

# a failure, and still not ONLINE after the online: failed attempts with the backoff
$id = open_vdev();
($h, $ce) = healer(rc => { 'storage-vdev-online' => [ 1, 1 ] }, out => { 'storage-vdev-online' => [ vdev_out('UNAVAIL', 'no'), '' ] });
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'open', 'exit 1 (still UNAVAIL): a failed attempt');
$now = $r->{heal}{next_at};
$h->tick;
is($is->get($id)->{heal}{attempts}, 2, 'retried');
$is->resolve($id, 'test');

# an issue that does not say which vdev, or of an unknown host
my ($bare) = $is->open_issue(kind => 'zfs-vdev', key_fields => ['host'], fields => { host => 'sch-001' });
($h, $ce) = healer();
$h->tick; $now += 30; $h->tick;
is($is->get($bare->{id})->{state}, 'needs-human', 'no pool and vdev named: needs-human');
is(scalar $ce->calls, 0, 'no node call');
$id = open_vdev(host => 'ghost-001');
$h->tick; $now += 30; $h->tick;
is($is->get($id)->{state}, 'needs-human', 'an unknown host: needs-human');

# zfs-pool issues are not healed themselves
($pool) = $is->open_issue(kind => 'zfs-pool', key_fields => [qw(host pool)], fields => { host => 'sch-001', pool => 'other' });
($h, $ce) = healer();
$h->tick; $now += 3600; $h->tick;
is(scalar $ce->calls, 0, 'zfs-pool: no node call');
ok(!$is->get($pool->{id})->{heal}, 'and no heal schedule');

done_testing;
