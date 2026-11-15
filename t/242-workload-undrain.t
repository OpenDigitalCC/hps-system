#!/usr/bin/env perl
# hps-workload undrain: reverses exactly what drain did (resume what it
# suspended, start what it stopped, class 1 first), leaves what was already
# stopped or suspended, clears the mark, and can be run again after a partial
# failure.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use DrainFixture;

sub drain   { my ($wl, @a) = @_; return HPS::Workload::Drain::drain($wl, 'sch-001', @a) }
sub undrain { my ($wl, @a) = @_; return HPS::Workload::Drain::undrain($wl, 'sch-001', @a) }
sub drained {
    my %o = @_;
    my ($f, $wl) = DrainFixture::setup(%o);
    DrainFixture::make($f, $wl, 'core', 1);
    DrainFixture::make($f, $wl, 'plain', undef);
    DrainFixture::make($f, $wl, 'batch', 4);
    DrainFixture::make($f, $wl, 'off', 3, 'stopped');        # stopped before the drain
    DrainFixture::make($f, $wl, 'held', 2, 'suspended');     # suspended before the drain
    my $r = drain($wl);
    die "fixture: drain gave $r->{outcome}" unless $r->{outcome} eq 'drained';
    DrainFixture::reset_calls($f);
    return ($f, $wl);
}

#--- not drained: says so, exit 0, nothing happens
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'plain', 3);
    DrainFixture::reset_calls($f);
    my $r = undrain($wl);
    is($r->{outcome}, 'not-drained', 'undrain of a host that is not drained: not-drained');
    is($r->{exit}, 0, 'exit 0');
    is(scalar(() = $f->{ce}->calls), 0, 'no node call');
    is(HPS::Workload::Drain::render($r), "undrain: sch-001 is not drained (no host key drain); nothing to do\n", 'text says so');
    is_deeply([ DrainFixture::events($f) ], ['info undrain sch-001: the host is not drained (no host key drain); nothing to do'], 'event');
    is(DrainFixture::state($f, 'plain'), 'running', 'the running guest is untouched');
}

#--- the plan, then the real thing
{
    my ($f, $wl) = drained();
    my $p = undrain($wl, dry_run => 1);
    is($p->{outcome}, 'plan', 'dry run: plan');
    is_deeply([ map { [ @$_{qw(workload class was action)} ] } @{ $p->{guests} } ],
        [ [ 'core', 1, 'suspend', 'resume' ], [ 'plain', 3, 'suspend', 'resume' ], [ 'batch', 4, 'stop', 'start' ] ],
        'order: class 1 first; resume what was suspended, start what was stopped; nothing else');
    is(scalar(() = $f->{ce}->calls), 0, 'dry run sends nothing');
    ok(DrainFixture::mark($f), 'dry run keeps the mark');

    my $r = undrain($wl);
    is($r->{outcome}, 'undrained', 'outcome undrained');
    is($r->{exit}, 0, 'exit 0');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-restore', 'core-vm' ], [ 'vm-restore', 'plain-vm' ], [ 'vm-start', 'batch-vm' ] ],
        'node calls: restore class 1, restore class 3, start class 4') or diag explain DrainFixture::actions($f);
    is_deeply([ map { DrainFixture::state($f, $_) } qw(core plain batch) ], [qw(running running running)], 'what drain handled runs again');
    is(DrainFixture::state($f, 'off'), 'stopped', 'a guest stopped before the drain is left stopped');
    is(DrainFixture::state($f, 'held'), 'suspended', 'a guest suspended before the drain is left suspended');
    ok(!DrainFixture::mark($f), 'the mark is cleared');
    my @ev = DrainFixture::events($f);
    is($ev[0], 'notice undrain sch-001: by tester; 3 guest(s) to bring back', 'event: the start');
    ok(scalar(grep { $_ eq 'info undrain sch-001: resume of core/core-vm (class 1) ok' } @ev), 'event: a resume');
    ok(scalar(grep { $_ eq 'info undrain sch-001: start of batch/batch-vm (class 4) ok' } @ev), 'event: the start of a guest');
    is($ev[-1], 'notice undrain sch-001: mark cleared (host key drain removed); the host is placeable again', 'event: the end');
    like(HPS::Workload::Drain::render($r), qr/^undrain ok: sch-001 is placeable again \(host key drain removed\)$/m, 'text');

    # placeable again
    DrainFixture::reset_calls($f);
    ok($wl->run('resume', 'held')->{ok}, 'after undrain a resume on the host is accepted again');
    ok($wl->run('start', 'off')->{ok}, 'and a start');
    is(undrain($wl)->{outcome}, 'not-drained', 'a second undrain: not drained');
}

#--- a partial failure keeps the record for the failures; run again finishes it
{
    my ($f, $wl) = drained();
    $f->{ce}{rc}{'vm-restore'} = [3];
    $f->{ce}{err}{'vm-restore'} = ["[vm-restore] refused: the state file is missing\n"];
    my $r = undrain($wl);
    is($r->{outcome}, 'incomplete', 'outcome incomplete');
    is($r->{exit}, 5, 'exit 5');
    is_deeply([ map {"$_->{workload}/$_->{vm}"} @{ $r->{failed} } ], ['core/core-vm'], 'the guest not brought back');
    like($r->{failed}[0]{error}, qr/vm-restore exited 3: .*state file is missing/, 'with the node refusal');
    is_deeply([ map { DrainFixture::state($f, $_) } qw(core plain batch) ], [qw(suspended running running)], 'the others are brought back all the same');
    my $m = DrainFixture::mark($f);
    ok($m, 'the mark stays');
    is($m->{state}, 'undrain-incomplete', 'state undrain-incomplete');
    is_deeply([ map {"$_->{workload}:$_->{action}:$_->{result}"} @{ $m->{guests} } ], ['core:suspend:done'], 'the record keeps only the failure');
    like($m->{guests}[0]{undo_error}, qr/vm-restore exited 3/, 'and why');
    my $e = eval { $wl->run('start', 'off'); 1 } ? undef : $@;
    is($e && $e->kind, 'refused', 'the host is still not placeable');
    like((DrainFixture::events($f))[-1], qr/^err undrain sch-001: incomplete, 1 guest\(s\) not brought back: core\/core-vm; the host stays marked \(host key drain\), run undrain again$/, 'event');
    like(HPS::Workload::Drain::render($r), qr/^undrain INCOMPLETE: not brought back: core\/core-vm\. sch-001 stays marked/m, 'text');

    DrainFixture::reset_calls($f);
    $r = undrain($wl);
    is($r->{outcome}, 'undrained', 'run again: undrained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-restore', 'core-vm' ] ], 'only the guest that failed is tried again');
    is(DrainFixture::state($f, 'core'), 'running', 'it runs');
    ok(!DrainFixture::mark($f), 'the mark is cleared');
}

#--- a guest drain could not handle was never drain's: undrain does not touch it
{
    my ($f, $wl) = DrainFixture::setup(ce => { rc => { 'vm-save' => [3] } });
    DrainFixture::make($f, $wl, 'plain', 3);
    DrainFixture::make($f, $wl, 'batch', 4);
    is(drain($wl)->{outcome}, 'guests-left', 'drain leaves plain running');
    DrainFixture::reset_calls($f);
    my $r = undrain($wl);
    is($r->{outcome}, 'undrained', 'undrain: undrained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-start', 'batch-vm' ] ], 'only the guest drain stopped is started; the one left running gets no call');
    is_deeply([ map { $_->{workload} } @{ $r->{guests} } ], ['batch'], 'and is not among the guests undrain considers');
    ok(!DrainFixture::mark($f), 'the mark is cleared');
}

#--- what changed since the drain is left as it is
{
    my ($f, $wl) = drained();
    DrainFixture::set_rec($f, 'plain', sub { $_[0]{vms}{'plain-vm'}{state} = 'stopped' });    # no longer as drain left it
    $f->{reg}->cluster_unset('lab', 'workload_batch');                                          # destroyed meanwhile
    my $r = undrain($wl);
    is($r->{outcome}, 'undrained', 'undrained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-restore', 'core-vm' ] ], 'only the guest still as drain left it');
    my %res = map { $_->{workload} => $_ } @{ $r->{guests} };
    is($res{plain}{result}, 'skipped', 'a guest in another state is skipped');
    like($res{plain}{note}, qr/now stopped, not suspended as drain left it; left as it is/, 'and the result says why');
    is($res{batch}{result}, 'skipped', 'a workload that no longer exists is skipped');
    is(DrainFixture::state($f, 'plain'), 'stopped', 'and it stays as it was found');
}

#--- a record that cannot be read at undrain time is a failure, never a skip
{
    my ($f, $wl) = drained();
    my $file = "$f->{base}/clusters/lab/cluster.db/workload_plain.json";
    open(my $in, '<', $file) or die;
    my $good = do { local $/; <$in> };
    close $in;
    open(my $h, '>', $file) or die;
    print {$h} '{"vms": ';
    close $h;
    my $r = undrain($wl);
    is($r->{outcome}, 'incomplete', 'an unreadable workload record: incomplete');
    is_deeply([ map { $_->{workload} } @{ $r->{failed} } ], ['plain'], 'that guest is kept in the record');
    like($r->{failed}[0]{error}, qr/its workload record cannot be read/, 'with the reason');
    open($h, '>', $file) or die;
    print {$h} $good;
    close $h;
    is(undrain($wl)->{outcome}, 'undrained', 'record put right, run again: undrained');
    is(DrainFixture::state($f, 'plain'), 'running', 'and the guest is back');
}

#--- a drain that died between the node call and its record (result attempting)
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'saved', 3, 'suspended');    # the node call happened
    DrainFixture::make($f, $wl, 'never', 3);                 # it did not: still running
    $f->{reg}->host_set($StorageFixture::MAC, 'drain', { state => 'draining', started_at => 'x', by => 'tester', guests => [
        { workload => 'saved', vm => 'saved-vm', class => 3, action => 'suspend', node => 0, seq => 1, result => 'attempting' },
        { workload => 'never', vm => 'never-vm', class => 3, action => 'suspend', node => 0, seq => 2, result => 'attempting' } ] });
    DrainFixture::reset_calls($f);
    my $r = undrain($wl);
    is($r->{outcome}, 'undrained', 'undrained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-restore', 'saved-vm' ] ], 'the guest the dead drain did suspend is resumed; the one it never reached is not touched');
}

#--- include_nodes: the nodes drain stopped last are started first
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'core', 1);
    DrainFixture::make($f, $wl, 'nested', 4);
    $f->{reg}->host_set('525400000009', 'HOSTNAME', 'tch-009');
    DrainFixture::set_rec($f, 'nested', sub { $_[0]{vms}{'nested-vm'}{macs} = ['52:54:00:00:00:09'] });
    is(drain($wl, include_nodes => 1)->{outcome}, 'drained', 'drained with the node stopped');
    DrainFixture::reset_calls($f);
    is(undrain($wl)->{outcome}, 'undrained', 'undrained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-start', 'nested-vm' ], [ 'vm-restore', 'core-vm' ] ], 'the node is started before the class 1 guest is resumed');
}

#--- an unreadable drain record is refused, never "not drained"
{
    my ($f, $wl) = DrainFixture::setup();
    $f->{reg}->host_set($StorageFixture::MAC, 'drain', [ 'not', 'a', 'record' ]);
    my $r = undrain($wl);
    is_deeply([ @$r{qw(outcome exit)} ], [ 'refused', 3 ], 'refused, exit 3');
    like($r->{reason}, qr/host key drain of 525400000001 cannot be read as a drain record/, 'names the key');
    ok($f->{reg}->host_exists($StorageFixture::MAC, 'drain'), 'the key is left for the operator');
}

done_testing;
