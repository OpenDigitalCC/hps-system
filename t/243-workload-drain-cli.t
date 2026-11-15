#!/usr/bin/env perl
# bin/hps-workload drain and undrain: the exit code and --json of each outcome,
# the text, and usage, against a shim hps-run.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use DrainFixture;

my $tmp = tempdir(CLEANUP => 1);
StorageFixture::write_hps_run_shim("$tmp/hps-run");
local $ENV{HPS_RUN_CMD}            = "$tmp/hps-run";
local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
local $ENV{SHIM_DIR}               = $tmp;
local $ENV{SUDO_USER}              = 'tester';

# cli($f, @args): (exit, stdout, stderr) of hps-workload on the fixture's registry.
sub cli {
    my ($f, @args) = @_;
    local $ENV{HPS_CONFIG_BASE}     = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES}       = $f->{base};
    my $q = join ' ', map {"'$_'"} ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @args);
    my $out = qx($q 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    my $err = <$e> // '';
    return ($rc, $out, $err);
}
sub node_calls {
    return () unless -e "$tmp/args";
    open(my $h, '<', "$tmp/args") or die;
    my @l = grep { / vm-(?:stop|save|start|restore) / } <$h>;
    return map { / (vm-\S+) (\S+)/ ? "$1 $2" : () } @l;
}
sub reset_shim { unlink "$tmp/args"; return }
sub fleet {
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'plain', undef);
    DrainFixture::make($f, $wl, 'batch', 4);
    reset_shim();
    return ($f, $wl);
}

#--- usage
{
    my ($f) = fleet();
    my ($rc, $out, $err) = cli($f, 'drain');
    is($rc, 2, 'drain without a host: usage (2)');
    like($err, qr/host required/, 'says a host is required');
    like($err, qr/^  hps-workload drain   <host> \[--include-nodes\] \[--dry-run\] \[--json\]$/m, 'usage: the drain line');
    like($err, qr/^  hps-workload undrain <host> \[--dry-run\] \[--json\]$/m, 'usage: the undrain line');
    like($err, qr/^  hps-workload set-class <name> <1-4> \[--dry-run\] \[--json\]$/m, 'usage: the set-class line');
    is((cli($f, 'drain', 'sch-001', 'extra'))[0], 2, 'drain with an extra argument: usage');
    is((cli($f, 'drain', 'sch-001', '--vm', 'x'))[0], 2, 'drain --vm: usage');
    is((cli($f, 'drain', 'sch-001', '--force'))[0], 2, 'drain --force: usage (the stop is clean)');
    is((cli($f, 'undrain', 'sch-001', '--include-nodes'))[0], 2, 'undrain --include-nodes: usage');
    is((cli($f, 'start', 'plain', '--include-nodes'))[0], 2, '--include-nodes on another verb: usage');
    is((cli($f, 'drain', 'bad host!'))[0], 2, 'a host that is no MAC or hostname: usage');
    ($rc, $out, $err) = cli($f, 'drain', 'nohost');
    is($rc, 4, 'a host the registry does not know: not found (4)');
    is(scalar(() = node_calls()), 0, 'none of these calls a node');
    ok(!DrainFixture::mark($f), 'or marks the host');
}

#--- dry run, then drained clean (0), then undrain (0)
{
    my ($f) = fleet();
    my ($rc, $out, $err) = cli($f, 'drain', 'sch-001', '--dry-run');
    is($rc, 0, 'drain --dry-run: exit 0');
    like($out, qr/^Drain sch-001 \(dry run: the plan, nothing is sent or changed\):\n  batch\/batch-vm\s+class 4  stop\s.*\n  plain\/plain-vm\s+class 3  suspend\s+memory 1024 MiB\s+state file about 1024 MiB\n/, 'the plan: guest, class, action, memory, state file estimate');
    is(scalar(() = node_calls()), 0, 'dry run calls no node');
    ok(!DrainFixture::mark($f), 'dry run does not mark');
    ($rc, $out) = cli($f, 'drain', 'sch-001', '--dry-run', '--json');
    my $j = decode_json($out);
    is_deeply([ $rc, @$j{qw(outcome dry_run key)} ], [ 0, 'plan', 1, 'drain' ], 'dry run --json: outcome plan, the key named');

    ($rc, $out, $err) = cli($f, 'drain', 'sch-001');
    is($rc, 0, 'drain: exit 0 when drained clean');
    like($out, qr/^drain ok: sch-001 is drained and ready for reboot/m, 'says ready for reboot');
    is_deeply([ node_calls() ], [ 'vm-stop batch-vm', 'vm-save plain-vm' ], 'the node calls, class 4 first');
    like($err, qr/^hps-workload: drain sch-001: stop of batch\/batch-vm \(class 4\) ok$/m, 'each guest action is an event line');
    like($err, qr/^hps-workload: drain sch-001: host marked not placeable \(host key drain\) by tester; 2 guest\(s\) to handle$/m, 'and the drain itself');
    is(DrainFixture::mark($f)->{state}, 'drained', 'the host is marked');

    ($rc, $out, $err) = cli($f, 'start', 'batch');
    is($rc, 3, 'start on the drained host: refused (3)');
    like($err, qr/compute host sch-001 is draining \(host key drain\).*hps-workload undrain sch-001/, 'naming the key and the undrain verb');

    ($rc, $out) = cli($f, 'drain', 'sch-001', '--json');
    $j = decode_json($out);
    is_deeply([ $rc, $j->{outcome}, $j->{ready_for_reboot} ], [ 0, 'nothing-to-do', 1 ], 'drain again: exit 0, nothing-to-do');

    reset_shim();
    ($rc, $out) = cli($f, 'undrain', 'sch-001', '--dry-run');
    is($rc, 0, 'undrain --dry-run: exit 0');
    like($out, qr/^  plain\/plain-vm\s+class 3  resume\s+\(drain did: suspend\)\n  batch\/batch-vm\s+class 4  start\s+\(drain did: stop\)$/m, 'the undrain plan, class 3 before class 4');
    ($rc, $out, $err) = cli($f, 'undrain', 'sch-001');
    is($rc, 0, 'undrain: exit 0');
    like($out, qr/^undrain ok: sch-001 is placeable again \(host key drain removed\)$/m, 'says placeable again');
    is_deeply([ node_calls() ], [ 'vm-restore plain-vm', 'vm-start batch-vm' ], 'resume, then start');
    ok(!DrainFixture::mark($f), 'the mark is gone');
    ($rc, $out) = cli($f, 'undrain', 'sch-001');
    is($rc, 0, 'undrain of a host that is not drained: exit 0');
    is($out, "undrain: sch-001 is not drained (no host key drain); nothing to do\n", 'and says so');
    ($rc, $out) = cli($f, 'undrain', 'sch-001', '--json');
    is(decode_json($out)->{outcome}, 'not-drained', '--json: not-drained');
}

#--- nothing to do (6)
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'off', 3, 'stopped');
    reset_shim();
    my ($rc, $out) = cli($f, 'drain', 'sch-001');
    is($rc, 0, 'drain with no guest running: exit 0');
    like($out, qr/^drain: nothing to do, no guest is running on sch-001/m, 'says nothing to do');
    ok(DrainFixture::mark($f), 'the host is marked all the same');
    is(scalar(() = node_calls()), 0, 'no node call');
}

#--- guests left (5): every node call refused
{
    my ($f) = fleet();
    local $ENV{FAKE_NODE_EXIT}   = 3;
    local $ENV{FAKE_NODE_STDERR} = 'refused: not enough free space';
    my ($rc, $out, $err) = cli($f, 'drain', 'sch-001');
    is($rc, 5, 'drain with guests left running: exit 5');
    like($out, qr/^drain INCOMPLETE: sch-001 is NOT ready for reboot; still running: batch\/batch-vm, plain\/plain-vm\./m, 'says NOT ready and lists what still runs');
    like($out, qr/not enough free space/, 'with the node refusal');
    ($rc, $out) = cli($f, 'drain', 'sch-001', '--json');
    my $j = decode_json($out);
    is_deeply([ $rc, $j->{outcome}, $j->{ready_for_reboot}, scalar @{ $j->{still_running} } ], [ 5, 'guests-left', 0, 2 ], '--json: guests-left, not ready, two still running');
    is(DrainFixture::state($f, 'plain'), 'running', 'the record still says running');

    # undrain with a failing node: incomplete (5)
    delete local $ENV{FAKE_NODE_EXIT};
    is((cli($f, 'drain', 'sch-001'))[0], 0, 'the node answers again: drained');
    local $ENV{FAKE_NODE_EXIT} = 1;
    ($rc, $out) = cli($f, 'undrain', 'sch-001');
    is($rc, 5, 'undrain with guests not brought back: exit 5');
    like($out, qr/^undrain INCOMPLETE: not brought back: plain\/plain-vm, batch\/batch-vm\. sch-001 stays marked/m, 'lists them');
    ($rc, $out) = cli($f, 'undrain', 'sch-001', '--json');
    is_deeply([ $rc, decode_json($out)->{outcome} ], [ 5, 'incomplete' ], '--json: incomplete');
    delete local $ENV{FAKE_NODE_EXIT};
    is((cli($f, 'undrain', 'sch-001'))[0], 0, 'run again with the node back: exit 0');
    ok(!DrainFixture::mark($f), 'the mark is gone');
}

#--- refused (3): a node VM, and a record that cannot be read
{
    my ($f) = fleet();
    $f->{reg}->host_set('525400000009', 'HOSTNAME', 'tch-009');
    DrainFixture::set_rec($f, 'batch', sub { $_[0]{vms}{'batch-vm'}{macs} = ['52:54:00:00:00:09'] });
    my ($rc, $out, $err) = cli($f, 'drain', 'sch-001');
    is($rc, 3, 'drain with a node VM on the host: refused (3)');
    is($out, '', 'nothing on stdout');
    like($err, qr/^hps-workload: drain sch-001 refused: 1 guest\(s\) running on sch-001 are cluster nodes or infrastructure: batch\/batch-vm \(registered host tch-009\).*--include-nodes/m, 'the message lists the node and the option');
    ($rc, $out) = cli($f, 'drain', 'sch-001', '--json');
    my $j = decode_json($out);
    is_deeply([ $rc, $j->{outcome}, $j->{nodes}[0]{vm} ], [ 3, 'refused', 'batch-vm' ], '--json: refused, with the nodes');
    is(scalar(() = node_calls()), 0, 'no node call');
    ok(!DrainFixture::mark($f), 'no mark');
    ($rc, $out) = cli($f, 'drain', 'sch-001', '--include-nodes');
    is($rc, 0, '--include-nodes: drained');
    is_deeply([ node_calls() ], [ 'vm-save plain-vm', 'vm-stop batch-vm' ], 'the node is stopped, after the other guest');

    my ($g) = fleet();
    open(my $h, '>', "$g->{base}/clusters/lab/cluster.db/workload_broken.json") or die;
    print {$h} 'not json';
    close $h;
    ($rc, $out, $err) = cli($g, 'drain', 'sch-001');
    is($rc, 3, 'drain with an unreadable workload record: refused (3), not "nothing to do"');
    like($err, qr/workload broken: its record \(cluster key workload_broken\) cannot be read/, 'names the record');
    ok(!DrainFixture::mark($g), 'no mark');
}

done_testing;
