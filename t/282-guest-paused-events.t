#!/usr/bin/env perl
# The event lines of a paused guest (docs/LOGGING.md, kind workload): the new
# state words, the standing "paused" line repeated every REMIND seconds while the
# guest-paused issue is unresolved, "resumed" (or "stopped") when it resolves,
# the "unreadable" line, subject <workload>/<vm> (or <host>/<vm> when no
# workload has it), and `hps-log attention` (HPS::Log::attention) showing a paused
# guest and dropping it when it is resumed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/lib";
use StorageFixture;
use HPS::Event;
use HPS::Issues;
use HPS::IssueHeal;
use HPS::GuestHeal;
use HPS::Log;

#--- the vocabulary ---------------------------------------------------------------------
is(HPS::Event::state_class('paused'), 'standing', 'paused is a standing state');
is(HPS::Event::state_class('resumed'), 'clearing', 'resumed clears');
is(HPS::Event::state_class('stopped'), 'clearing', 'stopped (shut off on purpose) clears');
ok(HPS::Event::parse(HPS::Event::line(pri => 'warning', kind => 'workload', subject => 'w/vm1', state => 'paused', text => 'x')), 'a paused workload line parses');
is(HPS::Event::subject_token('t0/t0-app'), 't0/t0-app', 'the subject <workload>/<vm> is a valid subject');
ok(!eval { HPS::Event::line(pri => 'warning', kind => 'workload', subject => 's', state => 'paused-ish'); 1 }, 'a state outside the list is still refused');

#--- the lines ----------------------------------------------------------------------------
my $f   = StorageFixture::setup();
my $reg = $f->{reg};
my $T   = 1_794_470_400;
my @lines;    # {at, msg}
my $is = HPS::Issues->new(registry => $reg, now => sub { $T }, logger => sub { push @lines, { at => $T, msg => $_[1] } if $_[1] =~ /\AHPS-/ });
$reg->cluster_set('lab', 'workload_t0', { state => 'running', vms => { 't0-app' => { host => 'sch-001', state => 'running' } } });

sub healer { my $ce = FakeCE->new(@_); return (HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $T }), $ce) }
sub open_gp {
    my (%f) = @_;
    my ($r) = $is->open_issue(kind => 'guest-paused', key_fields => [qw(host guest)], fields => { host => 'sch-001', guest => 't0-app', reason => 'ioerror', %f });
    return $r->{id};
}
sub wl_events { return grep { $_->{kind} eq 'workload' } map { HPS::Event::parse($_->{msg}) // () } @lines }

# attention($now): HPS::Log's answer over an events.log made from the lines so far.
sub attention {
    my $dir = tempdir(CLEANUP => 1);
    open(my $h, '>', "$dir/events.log") or die;
    print {$h} strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_->{at})), " ips.lab $_->{msg}\n" for @lines;
    print {$h} strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($T)), " ips.lab HPS-EVENT pri=info kind=service subject=hps-monitor state=ok alive\n";
    close $h;
    return HPS::Log->new(log_dir => $dir, now => $T)->attention(since => '1h');
}
sub problems { return grep { $_->{kind} eq 'workload' } @{ $_[0]{problems} } }

my $id = open_gp();
my ($h, $ce) = healer(out => { 'vm-status' => [ "PAUSED t0-app reason=ioerror\nVM t0-app paused\n", "VM t0-app running\n" ], 'vm-resume' => "VM t0-app running\n" });
@lines = ();
$h->tick;    # first sight
my @e = wl_events();
is(scalar @e, 1, 'first sight: one workload line');
is_deeply([ @{ $e[0] }{qw(pri kind subject state class)} ], [ 'warning', 'workload', 't0/t0-app', 'paused', 'standing' ], 'a warning, paused, subject workload/vm');
like($e[0]{text}, qr/\Ahps-guest-paused: guest t0-app on sch-001 is paused \(ioerror\); issue \Q$id\E is open\z/, 'the text says which guest, where, why');
my $a = attention();
is($a->{status}, 'attention', 'hps-log attention: a paused guest needs attention');
my ($p) = problems($a);
is_deeply([ @$p{qw(pri subject state)} ], [ 'warning', 't0/t0-app', 'paused' ], 'the problem is the guest');
is($a->{counts}{warning}, 1, 'one warning problem');
$is->resolve($id, 'test');
$h->tick;    # its clearing line (resumed), not looked at here

# a fresh case for the repeat: an issue that stays open
{
    my $id2 = open_gp(guest => 't0-db');
    $reg->cluster_set('lab', 'workload_t1', { state => 'running', vms => { 't0-db' => { host => 'sch-001', state => 'running' } } });
    my ($h2) = healer(out => { 'vm-status' => "PAUSED t0-db reason=user\nVM t0-db paused\n" });
    @lines = ();
    $h2->tick;
    is(scalar(wl_events()), 1, 'a new issue: its line at first sight');
    my ($first) = wl_events();
    is($first->{subject}, 't1/t0-db', 'the subject follows the workload that has the guest (t1)');
    $T += 30;
    $h2->tick;    # attempt: operator pause, needs-human
    is($is->get($id2)->{state}, 'needs-human', 'an operator\'s pause needs a human');
    @lines = ();
    $T += HPS::Event::REMIND - 31;
    $h2->tick;
    is(scalar(wl_events()), 0, 'needs-human: nothing before the period');
    $T += 31;
    $h2->tick;
    @e = wl_events();
    is(scalar @e, 1, 'a needs-human guest is still reported as paused, every period');
    is($e[0]{pri}, 'urgent', 'urgent once the issue is');
    $is->resolve($id2, 'operator: resumed by hand');
    @lines = ();
    $h2->tick;
    @e = wl_events();
    is_deeply([ map { "$_->{pri} $_->{state} $_->{subject}" } @e ], ['notice resumed t1/t0-db'], 'resolved by hand: resumed, a notice, the same subject');
    @lines = ();
    $T += 2 * HPS::Event::REMIND;
    $h2->tick;
    is(scalar(wl_events()), 0, 'resolved: not repeated, not announced again');
}

# the whole run on the first issue: paused, healed, resumed; attention clears
{
    my $id3 = open_gp(guest => 't0-app');
    $reg->cluster_set('lab', 'workload_t0', { state => 'running', vms => { 't0-app' => { host => 'sch-001', state => 'running' } } });
    my ($h3, $c3) = healer(out => { 'vm-status' => [ "PAUSED t0-app reason=ioerror\nVM t0-app paused\n", "VM t0-app running\n" ], 'vm-resume' => "VM t0-app running\n" });
    @lines = ();
    $h3->tick;
    is((problems(attention()))[0]{state}, 'paused', 'attention: paused');
    $T += 30;
    $h3->tick;    # vm-resume
    $T += 30;
    $h3->tick;    # checked: running, resolved
    $h3->tick;    # the clearing line
    is($is->get($id3)->{state}, 'resolved', 'the issue resolved');
    my @w = wl_events();
    is($w[-1]{state}, 'resumed', 'the last workload line is resumed');
    is($w[-1]{subject}, 't0/t0-app', 'on the same subject as the paused line');
    my $a3 = attention();
    is(scalar(problems($a3)), 0, 'hps-log attention: the guest is gone from it once resumed');
    my @left = map { "$_->{kind} $_->{subject}" } @{ $a3->{problems} };
    diag "left: @left" if @left;
}

# a guest shut off or gone clears with stopped
{
    my $id4 = open_gp(guest => 't0-app');
    my ($h4) = healer(out => { 'vm-status' => "VM t0-app shut off\n" });
    @lines = ();
    $h4->tick;
    $T += 30;
    $h4->tick;
    $h4->tick;
    my @w = wl_events();
    is_deeply([ map { $_->{state} } @w ], [ 'paused', 'stopped' ], 'a guest found shut off: paused, then stopped');
    is(scalar(problems(attention())), 0, 'attention: stopped clears it too');
}

# a guest no workload has: <host>/<vm>
{
    my $id5 = open_gp(guest => 'loose');
    my ($h5) = healer(out => {});
    @lines = ();
    $h5->tick;
    my ($l) = wl_events();
    is($l->{subject}, 'sch-001/loose', 'no workload has the guest: the subject is host/vm');
    like($l->{text}, qr/guest loose on sch-001 is paused/, 'and the text has no workload');
    $is->resolve($id5, 'test');
}

# unreadable
{
    $reg->cluster_set('lab', 'workload_zzbad', '{nope');
    my $id6 = open_gp(guest => 'strange');
    my ($h6, $c6) = healer(out => {});
    $h6->tick;
    $T += 30;
    @lines = ();
    $h6->tick;
    my @u = grep { $_->{state} eq 'unreadable' } wl_events();
    is(scalar @u, 1, 'state that cannot be read: an unreadable line');
    is($u[0]{pri}, 'warning', 'a warning');
    like($u[0]{text}, qr/\Ahps-guest-paused: cannot tell whether to resume strange/, 'it says what it cannot tell');
    is(scalar $c6->calls, 0, 'and nothing was sent to the node');
    $reg->cluster_unset('lab', 'workload_zzbad');
    $is->resolve($id6, 'test');
}

done_testing;
