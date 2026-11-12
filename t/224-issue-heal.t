#!/usr/bin/env perl
# The mirror-leg healer (HPS::IssueHeal; docs/ISSUES.md) on the fake runner of
# the workload tests: first attempt after FIRST_DELAY, mirror-status then
# mirror-rejoin of the missing leg, healing until mirror-status is clean, the
# backoff and its escalation, exit 3 to needs-human, and the cases it cannot
# heal (no workload record, unknown host, unknown mirror).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use StorageFixture;
use HPS::Issues;
use HPS::IssueHeal;

my $f   = StorageFixture::setup();
my $reg = $f->{reg};
my $now = 1_794_470_400;
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });

my $LOCAL  = 'local:lab/enc/vm/t0-t0-app-root';
my $REMOTE = 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-root';
$reg->cluster_set('lab', 'workload_t0', { state => 'running', vms => {
    't0-app' => { host => 'sch-001', state => 'running',
        disks => { root => { md => '/dev/md/t0-app-root', legs => [ $LOCAL, $REMOTE ] } } } } });
$reg->cluster_set('lab', 'workload_t0_destroyed', { at => 'x' });

sub status_out {
    my ($state, $remote_dev) = @_;
    $remote_dev //= '/dev/sdb';
    return "/dev/md/t0-app-root:\n             State : clean, degraded\n"
        . "       0     230        5        0      active sync   /dev/zd0\n"
        . "       -       0        0        1      removed\n"
        . "LEG $LOCAL kind=local dev=/dev/zd0 write_mostly=0\n"
        . "LEG $REMOTE kind=remote dev=$remote_dev write_mostly=1\n"
        . "MIRROR t0-app-root $state\n";
}

sub healer {
    my (%ce) = @_;
    my $ce = FakeCE->new(%ce);
    return (HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $now }), $ce);
}

sub open_leg {
    my (%x) = @_;
    my ($r) = $is->open_issue(kind => 'mirror-leg', key_fields => [ sort keys %{ $x{key} // { host => 1, mirror => 1 } } ],
        fields => { host => 'sch-001', mirror => 't0-app-root', %{ $x{fields} // {} } });
    return $r->{id};
}

#--- units ------------------------------------------------------------------------
is(HPS::IssueHeal::backoff(1), 60, 'backoff after 1 failed attempt: 60 s');
is(HPS::IssueHeal::backoff(2), 120, 'after 2: 2 min');
is(HPS::IssueHeal::backoff(3), 300, 'after 3: 5 min');
is(HPS::IssueHeal::backoff(4), 900, 'after 4: 15 min');
is(HPS::IssueHeal::backoff(9), 900, 'capped at 15 min');
is_deeply([ HPS::IssueHeal::missing_legs([ $LOCAL, $REMOTE ], status_out('degraded')) ], [$REMOTE],
    'missing legs: the leg whose device mdadm does not list as a member');
is_deeply([ HPS::IssueHeal::missing_legs([ $LOCAL, $REMOTE ], status_out('degraded', '')) ], [$REMOTE],
    'a leg with no device is missing');
is_deeply([ HPS::IssueHeal::missing_legs([ $LOCAL, $REMOTE ], status_out('degraded', '/dev/zd0')) ], [ $LOCAL, $REMOTE ],
    'none told apart: every leg (a member is a no-op for mirror-rejoin)');
is_deeply([ HPS::IssueHeal::missing_legs([ $LOCAL, $REMOTE ], '', 'iqn.2026-01.lab.nas:hpslab-t0-root@192.0.2.50') ], [$REMOTE],
    'the marker\'s leg hint names the leg');
is_deeply([ HPS::IssueHeal::missing_legs([ $LOCAL, $REMOTE ], '', 'iqn.2026-01.lab.nas:hpslab-t0-root@192.0.2.50:3260') ], [$REMOTE],
    'the hint matches by iqn when the portal is written differently');
is(HPS::IssueHeal::result_line({ stdout => "x\nDIVERGED t0 legA events=5\n", stderr => "[mirror-rejoin] y\n" }),
    'DIVERGED t0 legA events=5', 'result line: the DIVERGED line');
is(HPS::IssueHeal::result_line({ stdout => '', stderr => "+ mdadm x\n[mirror-rejoin] refused: no\n" }),
    '[mirror-rejoin] refused: no', 'else the last stderr line that is not a command trace');

#--- the happy path ------------------------------------------------------------------
my $id = open_leg(fields => { leg => 'iqn.2026-01.lab.nas:hpslab-t0-root@192.0.2.50', component => '/dev/sdb' });
my ($h, $ce) = healer(out => { 'mirror-status' => [ status_out('degraded'), status_out('resyncing'), status_out('clean') ] },
    rc => { 'mirror-rejoin' => 0 });
is($h->tick, 0, 'first sight: scheduled, not run');
is($is->get($id)->{heal}{next_at}, $now + 30, 'the first attempt is 30 s after');
is(scalar $ce->calls, 0, 'no node call yet');
$now += 29;
is($h->tick, 0, 'not before its time');
$now += 1;
is($h->tick, 1, 'at its time: one heal');
my @c = $ce->calls;
is_deeply([ map { $_->{script} } @c ], [qw(mirror-status mirror-rejoin)], 'mirror-status, then mirror-rejoin');
is($c[0]{mac}, $StorageFixture::MAC, 'on the issue\'s host (by MAC)');
is_deeply($c[0]{args}, ['t0-app-root'], 'mirror-status <mirror>');
is_deeply($c[1]{args}, [ 't0-app-root', '--leg', $REMOTE ], 'mirror-rejoin <mirror> --leg <the missing leg>');
my $r = $is->get($id);
is($r->{state}, 'healing', 'exit 0: healing');
is($r->{heal}{attempts}, 1, 'one attempt');
like((grep { $_->{event} eq 'heal' } @{ $r->{trail} })[0]{detail}, qr/\Aattempt 1: degraded; mirror-rejoin t0-app-root --leg \Q$REMOTE\E exit 0: out of mirror-rejoin/,
    'the attempt and the node\'s result line are in the trail');
$now += 30;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'healing', 'resyncing: still healing');
is($r->{trail}[-1]{event}, 'check', 'a check in the trail');
is($r->{heal}{attempts}, 1, 'a check is not an attempt');
$now += 30;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'resolved', 'mirror-status clean: resolved');
like($r->{trail}[-1]{detail}, qr/by mirror-status clean/, 'by mirror-status clean');
ok((grep { /hps-issue: resolved \Q$id\E by mirror-status clean/ } @log), 'logged');
$now += 3600;
is($h->tick, 0, 'a resolved issue is never touched again');
is(scalar $ce->calls, 4, 'no more node calls');

#--- failures: backoff and escalation ------------------------------------------------------
$id = open_leg();
($h, $ce) = healer(out => { 'mirror-status' => status_out('degraded') }, rc => { 'mirror-rejoin' => 1 });
$h->tick;
my @waits;
for my $n (1 .. 5) {
    $now = $is->get($id)->{heal}{next_at};
    $h->tick;
    $r = $is->get($id);
    push @waits, $r->{heal}{next_at} - $now;
}
is_deeply(\@waits, [ 60, 120, 300, 900, 900 ], 'failed attempts back off 60, 120, 300, 900, 900');
is($r->{heal}{attempts}, 5, 'five attempts');
is($r->{state}, 'open', 'still open');
is($r->{severity}, 'urgent', 'escalated to urgent at the cap');
is(scalar(grep { $_->{event} eq 'escalated' } @{ $r->{trail} }), 1, 'once');
like($r->{heal}{last_result}, qr/\Afailed: degraded; mirror-rejoin .* exit 1: boom from mirror-rejoin/, 'the last result is kept');
$is->resolve($id, 'test');

#--- exit 3: needs-human -------------------------------------------------------------------
$id = open_leg();
($h, $ce) = healer(out => { 'mirror-status' => status_out('degraded'), 'mirror-rejoin' => "DIVERGED t0-app-root legA events=10 time=1 legB events=12 time=2\n" },
    rc => { 'mirror-rejoin' => 3 });
$h->tick;
$now += 30;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'needs-human', 'mirror-rejoin exit 3: needs-human');
is($r->{severity}, 'urgent', 'urgent');
like($r->{heal}{last_result}, qr/DIVERGED t0-app-root/, 'the DIVERGED line recorded');
ok(!defined $r->{heal}{next_at}, 'no next attempt');
my $calls = scalar $ce->calls;
$now += 86400;
$h->tick;
is(scalar $ce->calls, $calls, 'needs-human: never retried');
ok((grep { /\Aerr hps-issue: heal \Q$id\E human/ } @log), 'logged as an error');
$is->resolve($id, 'test');

#--- cannot heal ----------------------------------------------------------------------------
$id = open_leg(fields => { mirror => 'nosuch-root' });
($h, $ce) = healer(out => { 'mirror-status' => "MIRROR nosuch-root degraded\n" });
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'needs-human', 'no workload record with that mirror on the host: needs-human');
like($r->{heal}{last_result}, qr/no workload record has a VM on sch-001 with the mirror nosuch-root/, 'saying so');
is_deeply([ $ce->scripts ], ['mirror-status'], 'no rejoin tried');

$id = open_leg(fields => { host => 'ghost-001' });
($h, $ce) = healer();
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'needs-human', 'an unknown host: needs-human');
is(scalar $ce->calls, 0, 'no node call');
$is->resolve($id, 'test');

$id = open_leg();
($h, $ce) = healer(rc => { 'mirror-status' => 3 });
$h->tick; $now += 30; $h->tick;
is($is->get($id)->{state}, 'needs-human', 'mirror-status exit 3 (not a mirror there): needs-human');
$is->resolve($id, 'test');

$id = open_leg();
($h, $ce) = healer(out => { 'mirror-status' => "MIRROR t0-app-root absent\n" });
$h->tick; $now += 30; $h->tick;
$r = $is->get($id);
is($r->{state}, 'open', 'absent (not assembled): a failed attempt, still open');
is($r->{heal}{attempts}, 1, 'counted');
is_deeply([ $ce->scripts ], ['mirror-status'], 'nothing to rejoin');
$is->resolve($id, 'test');

$id = open_leg();
($h, $ce) = healer(rc => { 'mirror-status' => 1 });
$h->tick; $now += 30; $h->tick;
is($is->get($id)->{state}, 'open', 'the node not answering: a failed attempt');
$is->resolve($id, 'test');

{
    package DyingRunner;
    sub new { return bless {}, shift }
    sub call { die "ctrl-exec-cli: no route\n" }
}
$id = open_leg();
$h = HPS::IssueHeal->new(issues => $is, runner => DyingRunner->new, now => sub { $now });
$h->tick; $now += 30; $h->tick;
like($is->get($id)->{heal}{last_result}, qr/runner: ctrl-exec-cli: no route/, 'a runner that dies is a failed attempt');
$is->resolve($id, 'test');

#--- an issue that names no mirror (the kernel rule): every mirror of the host -----------
my ($k) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host md)], fields => { host => 'sch-001', md => 'md127' });
($h, $ce) = healer(out => { 'mirror-status' => [ "MIRROR other clean\nMIRROR t0-app-root degraded\n", status_out('degraded'), "MIRROR other clean\nMIRROR t0-app-root clean\n" ] });
$h->tick; $now += 30; $h->tick;
is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } $ce->calls ],
    [ ['mirror-status'], [ 'mirror-status', 't0-app-root' ], [ 'mirror-rejoin', 't0-app-root', '--leg', $REMOTE ] ],
    'no mirror named: mirror-status of the host, then the degraded mirror healed');
is($is->get($k->{id})->{state}, 'healing', 'healing');
$now += 30;
$h->tick;
is($is->get($k->{id})->{state}, 'resolved', 'every mirror clean: resolved');

my ($k2) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host md)], fields => { host => 'sch-001', md => 'md9' });
($h, $ce) = healer(out => { 'mirror-status' => "MIRROR stopped-root absent\nMIRROR t0-app-root clean\n" });
$h->tick; $now += 30; $h->tick;
is($is->get($k2->{id})->{state}, 'resolved', 'no mirror named: an absent (stopped) mirror is not healed; the rest clean resolves');
is_deeply([ $ce->scripts ], ['mirror-status'], 'nothing rejoined');

#--- other kinds are not healed ------------------------------------------------------------
my ($sp) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], fields => { host => 'sch-001' });
($h, $ce) = healer();
$h->tick; $now += 3600; $h->tick;
is(scalar $ce->calls, 0, 'storage-path issues are recorded, not healed');
ok(!$is->get($sp->{id})->{heal}, 'and get no heal schedule');

done_testing;
