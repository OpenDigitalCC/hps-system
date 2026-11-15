#!/usr/bin/env perl
# hps-workload drain (plans/upgradability.md U2): the plan and its order, the
# four outcomes, the mark and what create, start and resume do with it, node
# VMs, and records that cannot be read.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use DrainFixture;

my $D = 'HPS::Workload::Drain';
sub drain { my ($wl, @a) = @_; return HPS::Workload::Drain::drain($wl, 'sch-001', @a) }
sub fleet {
    my %o = @_;
    my ($f, $wl) = DrainFixture::setup(%o);
    DrainFixture::make($f, $wl, 'core', 1, 'running', mem => 4096);
    DrainFixture::make($f, $wl, 'shop', 2, 'running', mem => 2048);
    DrainFixture::make($f, $wl, 'plain', undef);
    DrainFixture::make($f, $wl, 'batch', 4, 'running', mem => 512);
    DrainFixture::reset_calls($f);
    return ($f, $wl);
}
sub err_of { my ($cb) = @_; return eval { $cb->(); 1 } ? undef : $@ }

#--- the plan: class 4 first, then 3, 2, 1; --dry-run changes nothing
{
    my ($f, $wl) = fleet();
    my $r = drain($wl, dry_run => 1);
    is($r->{outcome}, 'plan', 'dry run: outcome plan');
    is($r->{exit}, 0, 'dry run: exit 0');
    is_deeply([ map { [ @$_{qw(workload vm class action)} ] } @{ $r->{guests} } ],
        [ [ 'batch', 'batch-vm', 4, 'stop' ], [ 'plain', 'plain-vm', 3, 'suspend' ],
          [ 'shop', 'shop-vm', 2, 'suspend' ], [ 'core', 'core-vm', 1, 'suspend' ] ],
        'order: class 4 stopped first, then class 3, 2 and 1 suspended') or diag explain $r->{guests};
    is_deeply([ map { $_->{memory_mib} } @{ $r->{guests} } ], [ 512, 1024, 2048, 4096 ], 'the memory of each guest');
    is_deeply([ map { $_->{state_file_bytes_estimate} } @{ $r->{guests} } ], [ undef, 1024 * 1048576, 2048 * 1048576, 4096 * 1048576 ],
        'the state file estimate is the memory of a suspended guest, none for a stopped one');
    is($r->{guests}[2]{note}, 'class 2: would be live-migrated when migration exists; suspending', 'class 2: the migration gap is named');
    is($r->{guests}[3]{note}, 'class 1: would be live-migrated when migration exists; suspending', 'class 1: the migration gap is named');
    ok(!defined $r->{guests}[1]{note}, 'class 3: no note');
    is(scalar(() = $f->{ce}->calls), 0, 'dry run sends nothing');
    ok(!DrainFixture::mark($f), 'dry run does not mark the host');
    is(DrainFixture::state($f, 'batch'), 'running', 'dry run leaves the records');
    is(scalar(() = DrainFixture::events($f)), 0, 'dry run logs no drain event');
    my $text = HPS::Workload::Drain::render($r);
    like($text, qr/^Drain sch-001 \(dry run: the plan, nothing is sent or changed\):$/m, 'text: the heading');
    like($text, qr/^  batch\/batch-vm\s+class 4  stop\s+memory 512 MiB\s+state file -$/m, 'text: a stopped guest');
    like($text, qr/^  core\/core-vm\s+class 1  suspend\s+memory 4096 MiB\s+state file about 4096 MiB$/m, 'text: a suspended guest with the estimate');
    like($text, qr/^    class 1: would be live-migrated when migration exists; suspending$/m, 'text: the gap line');
}

#--- drained clean
{
    my ($f, $wl) = fleet();
    my $r = drain($wl);
    is($r->{outcome}, 'drained', 'outcome drained');
    is($r->{exit}, 0, 'exit 0');
    ok($r->{ready_for_reboot}, 'ready for reboot');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-stop', 'batch-vm' ], [ 'vm-save', 'plain-vm' ], [ 'vm-save', 'shop-vm' ], [ 'vm-save', 'core-vm' ] ],
        'node calls: vm-stop of class 4, then vm-save of class 3, 2, 1') or diag explain DrainFixture::actions($f);
    ok(!grep({ $_->{script} eq 'vm-stop' && grep { $_ eq '--force' } @{ $_->{args} } } $f->{ce}->calls), 'the stop is clean: never --force');
    is_deeply([ map { DrainFixture::state($f, $_) } qw(batch plain shop core) ], [qw(stopped suspended suspended suspended)], 'the records follow');
    my $m = DrainFixture::mark($f);
    is($m->{state}, 'drained', 'host key drain: state drained');
    is($m->{by}, 'tester', 'by whom');
    like($m->{started_at}, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC$/, 'when');
    is_deeply([ map { [ @$_{qw(workload vm class action result seq)} ] } @{ $m->{guests} } ],
        [ [ 'batch', 'batch-vm', 4, 'stop', 'done', 1 ], [ 'plain', 'plain-vm', 3, 'suspend', 'done', 2 ],
          [ 'shop', 'shop-vm', 2, 'suspend', 'done', 3 ], [ 'core', 'core-vm', 1, 'suspend', 'done', 4 ] ], 'the record of what drain did, per guest');
    my @ev = DrainFixture::events($f);
    is($ev[0], DrainFixture::ev('notice', 'node', 'sch-001', 'started', 'drain sch-001: host marked not placeable (host key drain) by tester; 4 guest(s) to handle'), 'event: the mark (node, started)');
    ok(scalar(grep { $_ eq DrainFixture::ev('info', 'workload', 'batch', 'done', 'drain sch-001: stop of batch/batch-vm (class 4) ok') } @ev), 'event: the stop');
    ok(scalar(grep { $_ eq DrainFixture::ev('info', 'workload', 'core', 'done', 'drain sch-001: suspend of core/core-vm (class 1) ok') } @ev), 'event: a suspend');
    ok(scalar(grep { $_ eq DrainFixture::ev('notice', 'workload', 'core', 'requested', 'drain sch-001: class 1: would be live-migrated when migration exists; suspending') } @ev), 'event: the migration gap');
    is($ev[-1], DrainFixture::ev('notice', 'node', 'sch-001', 'done', 'drain sch-001: 4 guest(s) handled; ready for reboot'), 'event: the end (node, done)');
    like(HPS::Workload::Drain::render($r), qr/^drain ok: sch-001 is drained and ready for reboot; it is marked not placeable \(host key drain\) until hps-workload undrain sch-001$/m, 'text: the result');

    # placement: nothing is created, started or resumed on the host
    my $e = err_of(sub { $wl->run('start', 'batch') });
    is($e && $e->kind, 'refused', 'start on a draining host: refused');
    like($e->message, qr/^start: compute host sch-001 is draining \(host key drain\)/, 'the message names the key');
    like($e->message, qr/hps-workload undrain sch-001/, 'and the undrain verb');
    $e = err_of(sub { $wl->plan('start', 'batch') });
    is($e && $e->kind, 'refused', 'start --dry-run: refused too');
    $e = err_of(sub { $wl->run('resume', 'plain') });
    is($e && $e->kind, 'refused', 'resume on a draining host: refused');
    like($e->message, qr/host key drain.*hps-workload undrain sch-001/, 'with the key and the verb');
    StorageFixture::write_def($f, DrainFixture::wdef('fresh', 3));
    $e = err_of(sub { $wl->run('create', 'fresh') });
    is($e && $e->kind, 'refused', 'create on a draining host: refused');
    like($e->message, qr/^create: compute host sch-001 is draining \(host key drain\).*hps-workload undrain sch-001/, 'with the key and the verb');
    ok(!defined DrainFixture::rec($f, 'fresh'), 'and no record is made');
    is(scalar @{ $wl->plan('stop', 'batch') }, 1, 'stop is not placement: not refused for the mark');
    ok($wl->run('status', 'core')->{state}, 'status still answers');

    # a second drain: nothing left to do, the record is kept
    DrainFixture::reset_calls($f);
    $r = drain($wl);
    is($r->{outcome}, 'nothing-to-do', 'drain again: nothing to do');
    is(scalar @{ DrainFixture::actions($f) }, 0, 'no node call');
    is(scalar @{ DrainFixture::mark($f)->{guests} }, 4, 'the record of the first drain is kept for undrain');
}

#--- nothing to do: the host is marked all the same
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'off', 3, 'stopped');
    DrainFixture::make($f, $wl, 'held', 3, 'suspended');
    DrainFixture::make($f, $wl, 'new', 3, 'created');
    DrainFixture::reset_calls($f);
    my $dry = drain($wl, dry_run => 1);
    is_deeply([ @$dry{qw(outcome exit)} ], [ 'nothing-to-do', 0 ], 'dry run with nothing running: nothing-to-do, exit 0');
    ok(!DrainFixture::mark($f), 'and no mark');
    my $r = drain($wl);
    is($r->{outcome}, 'nothing-to-do', 'outcome nothing-to-do');
    is($r->{exit}, 0, 'exit 0: the host is marked and ready');
    ok($r->{ready_for_reboot}, 'ready for reboot');
    is_deeply($r->{guests}, [], 'no guest handled');
    is_deeply([ map {"$_->{workload}:$_->{state}"} @{ $r->{idle} } ], [ 'held:suspended', 'new:defined', 'off:stopped' ], 'the guests that are not running are listed as left');
    is(scalar @{ DrainFixture::actions($f) }, 0, 'no node call');
    is_deeply([ DrainFixture::mark($f)->{state}, scalar @{ DrainFixture::mark($f)->{guests} } ], [ 'drained', 0 ], 'the host is marked, with an empty record');
    like(HPS::Workload::Drain::render($r), qr/^drain: nothing to do, no guest is running on sch-001; it is marked not placeable \(host key drain\) and ready for reboot/m, 'text');
    like(HPS::Workload::Drain::render($r), qr/^  left as it is: off\/off-vm \(stopped\)$/m, 'text: what is left');
    is((DrainFixture::events($f))[-1], DrainFixture::ev('notice', 'node', 'sch-001', 'done', 'drain sch-001: nothing to do, no guest is running on it; ready for reboot'), 'event');
}

#--- guests left: a suspend the node refuses; the guest runs on, drain says NOT ready
{
    my ($f, $wl) = fleet(ce => { rc => { 'vm-save' => [ 0, 3 ] }, err => { 'vm-save' => [ '', "[vm-save] refused: not enough free space for shop-vm's memory on lab/enc/state: needs 2147483648 bytes, has 1000 bytes\n" ] } });
    my $r = drain($wl);
    is($r->{outcome}, 'guests-left', 'outcome guests-left');
    is($r->{exit}, 5, 'exit 5');
    ok(!$r->{ready_for_reboot}, 'not ready for reboot');
    is_deeply([ map {"$_->{workload}/$_->{vm}"} @{ $r->{still_running} } ], ['shop/shop-vm'], 'what still runs');
    like($r->{still_running}[0]{error}, qr/vm-save exited 3: .*not enough free space/, 'with the node refusal');
    is_deeply([ map { DrainFixture::state($f, $_) } qw(batch plain shop core) ], [qw(stopped suspended running suspended)],
        'the refused guest is left running; the others, the higher class included, are handled');
    my $m = DrainFixture::mark($f);
    is($m->{state}, 'guests-left', 'host key drain: state guests-left');
    is_deeply([ map {"$_->{workload}:$_->{result}"} @{ $m->{guests} } ], [qw(batch:done plain:done shop:left core:done)], 'the record says which');
    my @ev = DrainFixture::events($f);
    like((grep { /shop\/shop-vm/ && /^warning / } @ev)[0], qr/^warning HPS-ALERT pri=warning kind=workload subject=shop state=failed drain sch-001: suspend of shop\/shop-vm \(class 2\) failed; the guest is left running: /, 'event: the failure is a warning on the workload');
    is($ev[-1], DrainFixture::ev('warning', 'node', 'sch-001', 'failed', 'drain sch-001: NOT ready for reboot, 1 guest(s) still running: shop/shop-vm'), 'event: guests left running is a warning on the node');
    my $text = HPS::Workload::Drain::render($r);
    like($text, qr/^drain INCOMPLETE: sch-001 is NOT ready for reboot; still running: shop\/shop-vm\./m, 'text: NOT ready, with the list');
    like($text, qr/^  shop\/shop-vm\s.*FAILED, left running$/m, 'text: the guest line');

    # run again once the cause is gone: only what still runs is handled
    DrainFixture::reset_calls($f);
    $r = drain($wl);
    is($r->{outcome}, 'drained', 'drain again: drained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-save', 'shop-vm' ] ], 'only the guest that was left');
    is_deeply([ map {"$_->{workload}:$_->{result}"} @{ DrainFixture::mark($f)->{guests} } ], [qw(batch:done plain:done core:done shop:done)], 'the record now has all four as done');
    is(DrainFixture::mark($f)->{state}, 'drained', 'state drained');
}

#--- a guest whose definition is gone cannot be acted on: left running, the rest handled
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'plain', 3);
    DrainFixture::make($f, $wl, 'lost', 3);
    unlink $wl->definition_path('lost');
    DrainFixture::reset_calls($f);
    my $dry = drain($wl, dry_run => 1);
    like($dry->{guests}[0]{def_error}, qr/no workload definition/, 'dry run: says the definition of lost cannot be loaded');
    my $r = drain($wl);
    is($r->{outcome}, 'guests-left', 'a guest whose definition is gone cannot be suspended: guests-left');
    is_deeply([ map { $_->{workload} } @{ $r->{still_running} } ], ['lost'], 'it is the one left');
    is(DrainFixture::state($f, 'plain'), 'suspended', 'the other is suspended');
}

#--- node VMs: refused by default, stopped last with include_nodes, never suspended
{
    my ($f, $wl) = fleet();
    my $node_mac = '52:54:00:00:00:09';
    $f->{reg}->host_set('525400000009', 'HOSTNAME', 'tch-009');
    DrainFixture::make($f, $wl, 'nested', 4);
    DrainFixture::set_rec($f, 'nested', sub { $_[0]{vms}{'nested-vm'}{macs} = [$node_mac] });
    DrainFixture::make($f, $wl, 'pxe', 1);
    DrainFixture::set_rec($f, 'pxe', sub { push @{ $_[0]{vms}{'pxe-vm'}{define} }, '--boot', 'network' });
    DrainFixture::reset_calls($f);
    for my $dry (1, 0) {
        my $r = drain($wl, dry_run => $dry);
        is($r->{outcome}, 'refused', ($dry ? 'dry run' : 'drain') . ': refused while a node VM runs on the host');
        is($r->{exit}, 3, 'exit 3');
        like($r->{reason}, qr/^2 guest\(s\) running on sch-001 are cluster nodes or infrastructure: nested\/nested-vm \(registered host tch-009\), pxe\/pxe-vm \(network-boot VM/, 'the message lists them and why');
        like($r->{reason}, qr/--include-nodes/, 'and names the option');
        is_deeply([ map {"$_->{workload}/$_->{vm}"} @{ $r->{nodes} } ], [ 'nested/nested-vm', 'pxe/pxe-vm' ], 'nodes in the result');
    }
    is(scalar(() = $f->{ce}->calls), 0, 'a refusal sends nothing');
    ok(!DrainFixture::mark($f), 'and does not mark the host');
    is(DrainFixture::state($f, 'batch'), 'running', 'and stops no guest');
    like((DrainFixture::events($f))[-1], qr/^notice HPS-EVENT pri=notice kind=node subject=sch-001 state=refused drain sch-001 refused: 2 guest\(s\)/, 'event: the refusal is a notice');

    my $plan = drain($wl, dry_run => 1, include_nodes => 1);
    is_deeply([ map {"$_->{workload}:$_->{action}"} @{ $plan->{guests} } ],
        [qw(batch:stop plain:suspend shop:suspend core:suspend nested:stop pxe:stop)], 'include_nodes: the nodes come after every other guest, and are stopped');
    like($plan->{guests}[5]{note}, qr/never suspended; stopped cleanly after the other guests/, 'a class 1 node is stopped, never suspended');
    my $r = drain($wl, include_nodes => 1);
    is($r->{outcome}, 'drained', 'include_nodes: drained');
    is_deeply(DrainFixture::actions($f), [ [ 'vm-stop', 'batch-vm' ], [ 'vm-save', 'plain-vm' ], [ 'vm-save', 'shop-vm' ], [ 'vm-save', 'core-vm' ],
        [ 'vm-stop', 'nested-vm' ], [ 'vm-stop', 'pxe-vm' ] ], 'node calls: the nodes are stopped last') or diag explain DrainFixture::actions($f);
    ok(!grep({ $_->[0] eq 'vm-save' && $_->[1] =~ /nested|pxe/ } @{ DrainFixture::actions($f) }), 'no node VM is ever saved');
    is_deeply([ map { $_->{node} } @{ DrainFixture::mark($f)->{guests} } ], [ 0, 0, 0, 0, 1, 1 ], 'the record marks the nodes');
}

#--- a record that cannot be read is its own case: refused, never "nothing running"
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'plain', 3);
    DrainFixture::reset_calls($f);
    my $db = "$f->{base}/clusters/lab/cluster.db";
    my %case = (
        'corrupt JSON' => [ sub { open(my $h, '>', "$db/workload_broken.json") or die; print {$h} '{"state": "runn'; close $h }, qr/workload broken: its record \(cluster key workload_broken\) cannot be read/ ],
        'an empty file' => [ sub { open(my $h, '>', "$db/workload_broken.json") or die; close $h }, qr/workload broken: its record .* cannot be read/ ],
        'no vms object' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { state => 'running' }) }, qr/workload broken: its record .* has no vms object/ ],
        'a VM with no host' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { state => 'running', vms => { v => { state => 'running' } } }) }, qr/workload broken VM v: its record names no compute host/ ],
        'a VM with no state' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { vms => { v => { host => 'sch-001' } } }) }, qr/workload broken VM v: its recorded state \(none\) is not one drain knows/ ],
        'an unknown state' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { vms => { v => { host => 'sch-001', state => 'paused' } } }) }, qr/recorded state 'paused' is not one drain knows/ ],
        'a running VM on an unknown host' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { vms => { v => { host => 'gone-001', state => 'running' } } }) }, qr/recorded as running on 'gone-001', which is not a host of the registry/ ],
        'a class out of range' => [ sub { $f->{reg}->cluster_set('lab', 'workload_broken', { class => 7, vms => { v => { host => 'sch-001', state => 'running' } } }) }, qr/workload broken: its recorded class is not 1 to 4 \(hps-workload set-class broken <1-4>\)/ ],
    );
    for my $what (sort keys %case) {
        my ($make, $re) = @{ $case{$what} };
        unlink "$db/workload_broken.json";
        $make->();
        for my $dry (1, 0) {
            my $r = drain($wl, dry_run => $dry);
            is($r->{outcome}, 'refused', "$what: refused" . ($dry ? ' (dry run)' : ''));
            like($r->{reason}, $re, "$what: the reason");
        }
        like(drain($wl)->{reason}, qr/do not say for certain what runs on sch-001, so nothing is changed/, "$what: says nothing is changed");
    }
    is(scalar(() = $f->{ce}->calls), 0, 'no node call in any of them');
    ok(!DrainFixture::mark($f), 'the host is never marked');
    is(DrainFixture::state($f, 'plain'), 'running', 'the readable guest is not touched either');
    # a stopped VM on an unknown host is nobody's guest: not a problem
    $f->{reg}->cluster_set('lab', 'workload_broken', { vms => { v => { host => 'gone-001', state => 'stopped' } } });
    is(drain($wl, dry_run => 1)->{outcome}, 'plan', 'a stopped VM on a host the registry does not know does not block the drain');
    unlink "$db/workload_broken.json";

    # the drain record itself unreadable
    $f->{reg}->host_set($StorageFixture::MAC, 'drain', 'yes');
    my $r = drain($wl);
    is($r->{outcome}, 'refused', 'a host key drain that is not a drain record: refused');
    like($r->{reason}, qr/host key drain of 525400000001 cannot be read as a drain record/, 'names the key');
    is(DrainFixture::state($f, 'plain'), 'running', 'nothing is done');
}

#--- a guest on another host is not this host's; an unknown host is not found
{
    my ($f, $wl) = DrainFixture::setup();
    $f->{reg}->host_set($StorageFixture::MAC2, 'HOSTNAME', 'sch-002');
    DrainFixture::make($f, $wl, 'here', 3);
    DrainFixture::make($f, $wl, 'there', 3);
    DrainFixture::set_rec($f, 'there', sub { $_[0]{vms}{'there-vm'}{host} = 'sch-002' });
    DrainFixture::reset_calls($f);
    my $r = drain($wl, dry_run => 1);
    is_deeply([ map { $_->{workload} } @{ $r->{guests} } ], ['here'], 'only the guests recorded on the host');
    $r = HPS::Workload::Drain::drain($wl, '52:54:00:00:00:02', dry_run => 1);
    is_deeply([ $r->{host}, map { $_->{workload} } @{ $r->{guests} } ], [ 'sch-002', 'there' ], 'the host by MAC: named by its hostname');
    my $e = err_of(sub { HPS::Workload::Drain::drain($wl, 'nohost') });
    is($e && $e->kind, 'notfound', 'a host the registry does not know: not found');
}

is_deeply({ map { $_ => $HPS::Workload::Drain::EXIT{$_} } qw(drained guests-left nothing-to-do refused) },
    { drained => 0, 'guests-left' => 5, 'nothing-to-do' => 0, refused => 3 }, 'nothing-to-do exits 0 like drained; guests-left 5; refused 3');

done_testing;
