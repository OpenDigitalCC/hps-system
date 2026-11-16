#!/usr/bin/env perl
# The healer for guest-paused issues (HPS::GuestHeal through HPS::IssueHeal;
# docs/ISSUES.md "A paused guest"): the parsers, and every branch of one
# attempt on the fake runner of the workload tests: resumed (then verified),
# resolved when the guest runs, is shut off or is gone, a failed attempt for a
# disk that is not healthy yet with the backoff and the bound that escalates to
# needs-human with the last refusal, the wait for the host's other issues and for
# a draining host, and the cases that are never a resume: an operator's pause, a
# workload recorded stopped or suspended, a pause reason that cannot be read, a
# host that is not known, and state that cannot be read.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use StorageFixture;
use HPS::Issues;
use HPS::IssueHeal;
use HPS::GuestHeal;

my $f   = StorageFixture::setup();
my $reg = $f->{reg};
my $now = 1_794_470_400;
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });
my $HOST = 'sch-001';

sub set_workload {
    my (%o) = @_;
    $reg->cluster_set('lab', 'workload_t0', { state => $o{wl_state} // 'running', vms => {
        't0-app' => { host => $HOST, state => $o{vm_state} // 'running' } } });
}
set_workload();

sub paused_out { my $reason = shift; return "dominfo\n" . (defined $reason ? "PAUSED t0-app reason=$reason\n" : '') . "VM t0-app paused\n" }
sub healer {
    my (%ce) = @_;
    my $ce = FakeCE->new(%ce);
    return (HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $now }), $ce);
}
sub open_gp {
    my (%x) = @_;
    my ($r) = $is->open_issue(kind => 'guest-paused', key_fields => [qw(host guest)],
        fields => { host => $HOST, guest => 't0-app', reason => 'ioerror', %{ $x{fields} // {} } });
    return $r->{id};
}
sub due { my ($h, $id) = @_; $now += 30; return $h->tick }     # first sight, then due

#--- parsers ---------------------------------------------------------------------------
is_deeply(HPS::GuestHeal::parse_status("junk\nPAUSED vm1 reason=ioerror\nVM vm1 paused\n", 'vm1'), { state => 'paused', reason => 'ioerror' }, 'parse_status: paused with a reason');
is_deeply(HPS::GuestHeal::parse_status("VM vm1 running\n", 'vm1'), { state => 'running', reason => undef }, 'parse_status: running, no reason');
is_deeply(HPS::GuestHeal::parse_status("VM vm1 shut off\n", 'vm1'), { state => 'shut off', reason => undef }, 'parse_status: a state of two words');
is(HPS::GuestHeal::parse_status("VM vm2 running\n", 'vm1'), undef, 'parse_status: another guest\'s line is not ours');
is(HPS::GuestHeal::parse_status('', 'vm1'), undef, 'parse_status: no output');
is_deeply([ HPS::GuestHeal::parse_refusal("REFUSED disk mirror m is clean, failed\n") ], [ 'disk', 'mirror m is clean, failed' ], 'parse_refusal: code and reason');
is_deeply([ HPS::GuestHeal::parse_refusal("nothing\n") ], [], 'parse_refusal: no REFUSED line');

#--- find_guest -------------------------------------------------------------------------
{
    my ($h) = healer();
    my $mac = $h->find_host($HOST);
    my ($g, $err) = HPS::GuestHeal::find_guest($h, $mac, 't0-app');
    is_deeply([ @$g{qw(workload state)}, $err ], [ 't0', 'running', undef ], 'find_guest: the workload that has the VM on that host');
    ($g, $err) = HPS::GuestHeal::find_guest($h, $mac, 'stranger');
    is_deeply([ $g, $err ], [ undef, undef ], 'find_guest: a guest no workload has: no record, no error');
    $reg->cluster_set('lab', 'workload_broken', '{not json');
    ($g, $err) = HPS::GuestHeal::find_guest($h, $mac, 'stranger');
    like($err, qr/workload_broken cannot be read/, 'find_guest: an unreadable record and no record naming the guest: an error');
    ($g, $err) = HPS::GuestHeal::find_guest($h, $mac, 't0-app');
    ok($g && !defined $err, 'find_guest: an unreadable record elsewhere does not hide a guest found');
    $reg->cluster_unset('lab', 'workload_broken');
}

#--- resumed, verified, resolved ---------------------------------------------------------
{
    my $id = open_gp();
    my ($h, $ce) = healer(out => {
        'vm-status' => [ paused_out('ioerror'), "VM t0-app running\n" ],
        'vm-resume' => "VM t0-app running\n" }, rc => {});
    $h->tick;
    is($is->get($id)->{heal}{next_at}, $now + 30, 'first sight: scheduled, the first attempt is 30 s on');
    is(scalar $ce->calls, 0, 'no node call yet');
    $now += 30;
    is($h->tick >= 1, 1, 'at its time: one heal');
    my @c = $ce->calls;
    is_deeply([ map { $_->{script} } @c ], [qw(vm-status vm-resume)], 'vm-status, then vm-resume');
    is_deeply([ $c[0]{args}, $c[1]{args} ], [ ['t0-app'], ['t0-app'] ], 'both name the guest');
    is($c[1]{mac}, $StorageFixture::MAC, 'on the issue\'s host');
    my $r = $is->get($id);
    is($r->{state}, 'healing', 'resumed: healing, to be checked');
    is($r->{heal}{attempts}, 1, 'one attempt');
    is($r->{heal}{resumed}, 1, 'remembered that vm-resume ran');
    is($r->{fields}{workload}, 't0', 'the issue now carries the workload');
    like((grep { $_->{event} eq 'heal' } @{ $r->{trail} })[0]{detail}, qr/\Aattempt 1: vm-resume t0-app exit 0: VM t0-app running \(resumed; checked again later\)/, 'the trail has the attempt and the node\'s line');
    $now += 30;
    $h->tick;
    $r = $is->get($id);
    is($r->{state}, 'resolved', 'running at the check: resolved');
    is_deeply({ map { $_ => $r->{resolution}{$_} } qw(by action) }, { by => 'healer', action => 'vm-resume t0-app' }, 'by the healer, the action vm-resume');
    like($r->{resolution}{result}, qr/\Avm-status: t0-app running after vm-resume\z/, 'the result says it stayed up');
    ok(!exists $r->{heal}{resumed}, 'the memory of the resume is cleared');
    is(scalar(grep { $_ eq 'vm-resume' } map { $_->{script} } $ce->calls), 1, 'vm-resume ran once');
}

#--- paused again after the resume: a failed attempt --------------------------------------
{
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => [ (paused_out('ioerror')) x 3 ], 'vm-resume' => "VM t0-app running\n" });
    $h->tick;
    due($h);
    is($is->get($id)->{state}, 'healing', 'resumed');
    $now += 30;
    $h->tick;
    my $r = $is->get($id);
    is($r->{state}, 'open', 'paused again at the check: back to open');
    is($r->{heal}{attempts}, 2, 'a second attempt counted');
    like($r->{heal}{last_result}, qr/\Afailed: t0-app paused again \(ioerror\) after vm-resume/, 'said so');
    is($r->{heal}{next_at}, $now + 120, 'the backoff after the second failed attempt');
    is(scalar(grep { $_ eq 'vm-resume' } map { $_->{script} } $ce->calls), 1, 'no second vm-resume in the same step');
    $is->resolve($id, 'test');
}

#--- already running / shut off / gone ---------------------------------------------------------
for my $c (
    [ 'running', "VM t0-app running\n", 0, qr/\Avm-status: t0-app running \(resumed by someone else/, 'resumed' ],
    [ 'shut off', "VM t0-app shut off\n", 0, qr/\Avm-status: t0-app shut off\z/, 'stopped' ],
    [ 'not defined', "", 4, qr/not defined on sch-001/, 'stopped' ],
) {
    my ($name, $out, $rc, $result, $ev) = @$c;
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => $out }, rc => { 'vm-status' => $rc });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'resolved', "$name: resolved");
    is($r->{resolution}{by}, 'healer', "$name: by the healer");
    like($r->{resolution}{result}, $result, "$name: the evidence");
    is(join(',', $ce->scripts), 'vm-status', "$name: no vm-resume");
}

#--- never a resume ---------------------------------------------------------------------------
sub human_case {
    my ($label, $ce, $match, %o) = @_;
    my $id = open_gp(%o);
    my ($h, $c) = healer(%$ce);
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'needs-human', "$label: needs-human");
    is($r->{severity}, 'urgent', "$label: urgent");
    like($r->{heal}{last_result}, $match, "$label: says why");
    ok(!grep({ $_ eq 'vm-resume' } $c->scripts), "$label: vm-resume never called") unless $o{node_refuses};
    $is->resolve($id, 'test');
    return $c;
}
human_case('an operator\'s pause', { out => { 'vm-status' => paused_out('user') } }, qr/paused \(user\), not by an I\/O error.*never resumed automatically/);
human_case('any other reason', { out => { 'vm-status' => paused_out('migrating') } }, qr/paused \(migrating\)/);
human_case('a pause with no readable reason (an older node image)', { out => { 'vm-status' => "VM t0-app paused\n" } }, qr/pause reason of t0-app cannot be read/);
human_case('a guest in another state', { out => { 'vm-status' => "VM t0-app crashed\n" } }, qr/is crashed, not paused/);
set_workload(vm_state => 'stopped');
human_case('a VM recorded stopped', { out => { 'vm-status' => paused_out('ioerror') } }, qr/workload t0 records VM t0-app stopped: not resumed automatically/);
set_workload(vm_state => 'suspended');
human_case('a VM recorded suspended', { out => { 'vm-status' => paused_out('ioerror') } }, qr/records VM t0-app suspended/);
set_workload(wl_state => 'stopped');
human_case('a workload recorded stopped', { out => { 'vm-status' => paused_out('ioerror') } }, qr/workload t0 records VM t0-app running|records VM t0-app/);
set_workload();
{
    my $c = human_case('an unknown host', { out => {} }, qr/host 'ghost-9' is not in the registry/, fields => { host => 'ghost-9' });
    is(scalar $c->calls, 0, 'an unknown host: no node call at all');
}
{
    # the node's own refusal: an operator's pause seen only by vm-resume
    my $c = human_case('vm-resume refuses an operator\'s pause', { out => { 'vm-status' => paused_out('ioerror'), 'vm-resume' => "REFUSED operator-paused t0-app is paused (user)\n" }, rc => { 'vm-resume' => 3 } },
        qr/exit 3.*paused by an operator/, node_refuses => 1);
}

#--- the disks are not healthy: failed attempts, backoff, the bound --------------------------------
{
    my $id = open_gp();
    my @ref = ("REFUSED disk mirror t0-app-root is clean, failed\n") x 8;
    my ($h, $ce) = healer(out => { 'vm-status' => [ (paused_out('ioerror')) x 8 ], 'vm-resume' => \@ref }, rc => { 'vm-resume' => [ (3) x 8 ] });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'open', 'a disk refusal: back to open');
    is($r->{heal}{attempts}, 1, 'one failed attempt');
    like($r->{heal}{last_result}, qr/\Afailed: vm-resume t0-app exit 3.*\(disk: mirror t0-app-root is clean, failed\)/, 'the refusal reason is in the result');
    is($r->{heal}{next_at}, $now + 60, 'backoff 60 s');
    my @wait = (60, 120, 300, 900, 900);
    for my $i (1 .. 5) {
        $now = $is->get($id)->{heal}{next_at};
        $h->tick;
        $r = $is->get($id);
        if ($i < 5) { is($r->{heal}{attempts}, $i + 1, 'attempt ' . ($i + 1)) }
    }
    is($r->{heal}{attempts}, 6, 'six attempts');
    is($r->{state}, 'needs-human', 'after the sixth failed attempt: needs-human');
    is($r->{severity}, 'urgent', 'urgent');
    ok(!exists $r->{heal}{next_at}, 'no more attempts scheduled');
    like((grep { $_->{event} eq 'needs-human' } @{ $r->{trail} })[0]{detail}, qr/gave up after 6 attempts; the last: .*disk: mirror t0-app-root is clean, failed/, 'the last refusal reason is in the trail');
    ok((grep { /HPS-ALERT pri=urgent kind=issue .*state=needs-human/ } @log), 'an urgent needs-human line');
    $is->resolve($id, 'test');
    @log = ();
}
{
    # a node that does not answer is a failed attempt too
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => '' }, rc => { 'vm-status' => 1 });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'open', 'vm-status exit 1: back to open');
    like($r->{heal}{last_result}, qr/\Afailed: vm-status t0-app exit 1/, 'a failed attempt');
    $is->resolve($id, 'test');
}

#--- waiting: other issues of the host, a draining host ---------------------------------------------
{
    my ($leg) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host mirror)], fields => { host => 'sch-001.lab.hps', mirror => 't0-app-root' });
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => [ (paused_out('ioerror')) x 6 ], 'vm-resume' => "VM t0-app running\n",
        'mirror-status' => [ ("MIRROR t0-app-root resyncing\n") x 9 ] });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($is->get($leg->{id})->{state}, 'healing', '(the mirror-leg issue is being healed: its resync is running)');
    is($r->{state}, 'open', 'a mirror-leg issue of the host is being healed: the guest waits, still open');
    is($r->{heal}{attempts} // 0, 0, 'no try is spent while waiting');
    like($r->{heal}{last_result}, qr/\Await: waiting for mirror-leg issue \Q$leg->{id}\E \(healing\) of sch-001 to heal first/, 'it says what it waits for');
    is($r->{heal}{next_at}, $now + 60, 'looked at again in a minute');
    ok(!grep({ $_ eq 'vm-resume' } $ce->scripts), 'vm-resume not called');
    $now += 60;
    $h->tick;
    ok(!grep({ $_ eq 'vm-resume' } $ce->scripts), 'still waiting a minute later');
    $is->resolve($leg->{id}, 'healed');
    $now += 60;
    $h->tick;
    is($is->get($id)->{state}, 'healing', 'the mirror-leg issue resolved: the guest is resumed');
    $is->resolve($id, 'test');
}
{
    my ($sp) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], fields => { host => 'sch-001' });
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => paused_out('ioerror'), 'vm-resume' => "VM t0-app running\n" });
    $h->tick;
    due($h);
    is($is->get($id)->{state}, 'open', 'a storage-path issue of the host also holds it back');
    $now += HPS::GuestHeal::WAIT_CAP;
    $h->tick;
    is($is->get($id)->{state}, 'healing', 'after the cap it tries anyway: the node\'s own disk check decides');
    $is->resolve($id, 'test');
    $is->resolve($sp->{id}, 'test');
}
{
    my ($other) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host mirror)], fields => { host => 'tch-009', mirror => 'x' });
    my $id = open_gp();
    my ($h, $ce) = healer(out => { 'vm-status' => paused_out('ioerror'), 'vm-resume' => "VM t0-app running\n" });
    $h->tick;
    due($h);
    is($is->get($id)->{state}, 'healing', 'an issue of another host does not hold it back');
    $is->resolve($id, 'test');
    $is->resolve($other->{id}, 'test');
}
{
    my $id = open_gp();
    $reg->host_set($StorageFixture::MAC, 'drain', '1');
    my ($h, $ce) = healer(out => { 'vm-status' => paused_out('ioerror'), 'vm-resume' => "VM t0-app running\n" });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'open', 'a draining host: waits, not resumed');
    like($r->{heal}{last_result}, qr/\Await: host sch-001 is draining/, 'says so');
    is(scalar $ce->calls, 0, 'no node call on a draining host');
    is($r->{heal}{attempts} // 0, 0, 'no try spent');
    $reg->host_unset($StorageFixture::MAC, 'drain');
    $now += 60;
    $h->tick;
    is($is->get($id)->{state}, 'healing', 'the drain mark gone: resumed');
    $is->resolve($id, 'test');
}

#--- state that cannot be read: reported, never a resume ---------------------------------------------------
{
    $reg->cluster_set('lab', 'workload_zzbad', '{not json');
    my $id = open_gp(fields => { guest => 'stranger' });
    my ($h, $ce) = healer(out => { 'vm-status' => "PAUSED stranger reason=ioerror\nVM stranger paused\n", 'vm-resume' => "VM stranger running\n" });
    $h->tick;
    due($h);
    my $r = $is->get($id);
    is($r->{state}, 'open', 'an unreadable workload record: the issue stays open');
    like($r->{heal}{last_result}, qr/\Aunreadable: cannot tell whether to resume stranger: the workload record workload_zzbad cannot be read/, 'reported as unreadable');
    is(scalar $ce->calls, 0, 'nothing sent to the node');
    is($r->{heal}{attempts} // 0, 0, 'no try spent');
    ok((grep { /kind=workload subject=sch-001\/stranger state=unreadable / } @log), 'an unreadable event line');
    $reg->cluster_unset('lab', 'workload_zzbad');
    $is->resolve($id, 'test');
}

#--- bits of the plumbing ------------------------------------------------------------------------------------
{
    my $id = open_gp();
    my ($h) = healer();
    $is->update($id, sub { $_[0]{heal} = { attempts => 0, next_at => $now + 5 } });
    $h->tick;
    is(scalar $h->{runner}->calls, 0, 'not before its time: no node call');
    $is->resolve($id, 'test');
    my ($h2) = healer();
    my $id2 = open_gp();
    $is->update($id2, sub { $_[0]{state} = 'needs-human' });
    $now += 3600;
    $h2->tick;
    is(scalar $h2->{runner}->calls, 0, 'a needs-human guest-paused issue is never touched by the healer');
    $is->resolve($id2, 'test');
}

done_testing;
