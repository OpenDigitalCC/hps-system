#!/usr/bin/env perl
# Layer 2 (docs/BOOT-RELIABILITY.md): HPS::BootWatch on a network-boot VM of a workload,
# against the real HPS::Workload on the fake runner and the real issue register.
# Detection, the bounded reset (stop --force, start), the give-up issue, the
# resolution, and every case that must never reset.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::BootWatch;
use HPS::Issues;

my $T = 1_800_000_000;
my $clock = sub { $T };
my $MAC = '52:54:00:12:34:56';
my $HOST = '525400123456';

my $layout = { %{ StorageFixture::layout() }, prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' } };
sub net_def {
    return { name => 'n0', project => 'lab', vms => [
        { name => 'n0-node', memory_mib => 4096, vcpus => 2, boot => 'network', nets => ['prov'], compute_host => 'sch-001' },
        { name => 'n0-disk', memory_mib => 1024, vcpus => 1, image => 'debian-13-generic-amd64', nets => ['prov'],
          disks => [ { name => 'root', size => '10G', legs => [ { host => 'sch-001', pool => 'lab' } ] } ] },
    ] };
}

# fixture(%o): a created workload n0 with one network-boot VM (and, with disk => 1, a disk-boot one); started at $T.
sub fixture {
    my (%o) = @_;
    my $def = net_def();
    pop @{ $def->{vms} } unless $o{disk};
    my $f = StorageFixture::setup_workload(no_def => 1, ce => { %{ $o{ce} // {} }, out => { 'vm-define' => "VM n0-node defined mac=$MAC\n" } });
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    StorageFixture::write_def($f, $def) unless $o{no_def};
    $f->{wl_obj} = $f->{wl}->(now => $clock);
    $f->{wl_obj}->run('create', 'n0') unless $o{no_create};
    $f->{wl_obj}->run('start', 'n0', vm => 'n0-node') unless $o{no_start};
    $f->{ce}{calls} = [];
    $f->{issues} = HPS::Issues->new(registry => $f->{reg}, now => $clock, logger => sub { });
    $f->{log} = [];
    $f->{ready} = $o{ready} // 'ready';
    $f->{bw} = HPS::BootWatch->new(registry => $f->{reg}, issues => $f->{issues}, workload => $f->{wl_obj}, now => $clock,
        ready => sub { $f->{ready} }, logger => sub { push @{ $f->{log} }, "$_[0] $_[1]" },
        settings => { window => 180, max => 3, metal => 0, warnings => [], %{ $o{settings} // {} } });
    return $f;
}
sub rec { return $_[0]{reg}->cluster_get_json('lab', 'workload_n0') }
sub scripts { return join ' ', map { $_->{script} . (@{ $_->{args} } && grep({ $_ eq '--force' } @{ $_->{args} }) ? '(force)' : '') } $_[0]{ce}->calls }
sub issues_of { my ($f, $kind) = @_; return grep { $_->{kind} eq $kind } $f->{issues}->list }
sub tick_at { my ($f, $dt) = @_; $T += $dt; return $f->{bw}->tick }
sub init_at { my ($f, $when) = @_; $f->{reg}->host_set($HOST, 'last_boot_at', $when // $T) }

#=== the whole story: booting, three resets, give up, issue, then it boots and resolves
{
    my $f = fixture();
    my $t0 = $T;
    is(rec($f)->{vms}{'n0-node'}{state}, 'running', 'set up: the VM is running');
    like(rec($f)->{vms}{'n0-node'}{started_at}, qr/UTC\z/, 'with a started_at stamp');

    is(tick_at($f, 10), 0, 'T+10: within the window, nothing acted on');
    is(scalar($f->{ce}->calls), 0, 'no node call');
    is(tick_at($f, 5), 0, 'a tick inside the scan interval does nothing');

    is(tick_at($f, 180), 1, 'T+195: past the window, one reset');
    is(scripts($f), 'vm-stop(force) vm-status vm-start', 'the reset is stop --force then start (the hps-workload path)');
    my $w = rec($f)->{vms}{'n0-node'}{boot_watch};
    is($w->{tries}, 1, 'one try recorded in the workload record');
    is($w->{expect}, rec($f)->{vms}{'n0-node'}{started_at}, 'tied to the new start stamp');
    is(rec($f)->{vms}{'n0-node'}{state}, 'running', 'and the VM is running again');
    ok((grep { /state=boot-stalled .*reset 1 of 3/ } @{ $f->{log} }), 'the event line names the try');
    ok((grep { /kind=boot subject=n0\/n0-node state=reset / } @{ $f->{log} }), 'and the result');

    $f->{ce}{calls} = [];
    is(tick_at($f, 100), 0, 'during the next window: nothing');
    is(scalar($f->{ce}->calls), 0, 'no call');
    is(tick_at($f, 90), 1, 'a window after the reset: reset 2');
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 2, 'two tries');
    is(tick_at($f, 200), 1, 'reset 3');
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 3, 'three tries');
    is(scalar(issues_of($f, 'boot-stalled')), 0, 'no issue yet');
    $f->{ce}{calls} = [];
    is(tick_at($f, 200), 1, 'the next window: no reset 4, it gives up');
    is(scalar($f->{ce}->calls), 0, 'no node call at the limit');
    my ($i) = issues_of($f, 'boot-stalled');
    ok($i, 'a boot-stalled issue is open');
    is($i->{state}, 'open', 'open');
    is_deeply($i->{fields}, { workload => 'n0', vm => 'n0-node' }, 'it names the workload and the VM');
    like($i->{summary}, qr/workload n0 VM n0-node did not reach iPXE: 3 reset\(s\) tried/, 'the tries');
    like($i->{summary}, qr/hps-workload console n0 --vm n0-node/, 'and the console hint');
    ok(rec($f)->{vms}{'n0-node'}{boot_watch}{gave_up}, 'gave_up recorded');
    ok((grep { /state=gave-up .*issue \Q$i->{id}\E/ } @{ $f->{log} }), 'the event names the issue');
    tick_at($f, 100);
    tick_at($f, 100);
    my @all = issues_of($f, 'boot-stalled');
    is(scalar(@all), 1, 'later ticks open nothing new');
    is($all[0]{seen}, 1, 'and do not even touch it');
    is(scalar($f->{ce}->calls), 0, 'and never reset again');

    init_at($f, $T);
    is(tick_at($f, 20), 1, 'the node reaches iPXE: resolved');
    is($f->{issues}->get($i->{id})->{state}, 'resolved', 'the issue is resolved');
    like($f->{issues}->get($i->{id})->{resolution}{result}, qr/iPXE init/, 'with the evidence');
    ok(!exists rec($f)->{vms}{'n0-node'}{boot_watch}, 'the watch state is cleared');
    is(tick_at($f, 20), 0, 'and it stays quiet');
}

#=== it boots in time: nothing happens, no state written
{
    my $f = fixture();
    init_at($f, $T + 20);
    is(tick_at($f, 400), 0, 'a netboot after the start: nothing to do');
    is(scalar($f->{ce}->calls), 0, 'no call');
    ok(!exists rec($f)->{vms}{'n0-node'}{boot_watch}, 'no state');
}

#=== a netboot from before the start does not count
{
    my $f = fixture();
    init_at($f, $T - 3600);
    is(tick_at($f, 400), 1, 'an old init does not count as booted: a reset');
}

#=== never reset: stopped on purpose, workload stopped, suspended
for my $state (qw(stopped suspended creating failed)) {
    my $f = fixture();
    $f->{wl_obj}->run('stop', 'n0', vm => 'n0-node') if $state eq 'stopped';
    if ($state ne 'stopped') {
        my $r = rec($f);
        $r->{vms}{'n0-node'}{state} = $state;
        $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    }
    $f->{ce}{calls} = [];
    is(tick_at($f, 1000), 0, "VM recorded $state: nothing acted on");
    is(scalar($f->{ce}->calls), 0, "VM recorded $state: never reset");
    is(scalar(issues_of($f, 'boot-stalled')), 0, "VM recorded $state: no issue");
}

#=== a disk-boot VM is not watched
{
    my $f = fixture(disk => 1, no_start => 1);
    $f->{wl_obj}->run('start', 'n0', vm => 'n0-disk');
    $f->{ce}{calls} = [];
    is(tick_at($f, 1000), 0, 'a disk-boot VM that never netboots: not watched');
    is(scalar($f->{ce}->calls), 0, 'no call');
}

#=== the IPS is deaf: defer, no try spent, no reset
{
    my $f = fixture(ready => 'not_ready');
    is(tick_at($f, 400), 0, 'boot services down: not acted on');
    is(scalar($f->{ce}->calls), 0, 'no reset into a deaf IPS');
    ok(!exists rec($f)->{vms}{'n0-node'}{boot_watch}, 'no try recorded');
    ok((grep { /boot services do not answer/ } @{ $f->{log} }), 'but said');
    $f->{ready} = 'ready';
    is(tick_at($f, 20), 1, 'the IPS answers again: the reset follows');
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 1, 'one try');
    $f->{ready} = 'unknown';
    $f->{ce}{calls} = [];
    is(tick_at($f, 400), 1, 'readiness unknown: reset anyway');
}

#=== limits and switches
{
    my $f = fixture(settings => { max => 0 });
    is(tick_at($f, 400), 1, 'max 0: acted on');
    is(scalar($f->{ce}->calls), 0, 'but no reset');
    ok(scalar(issues_of($f, 'boot-stalled')), 'the issue is opened at once');
}
{
    my $f = fixture(settings => { window => 0 });
    is(tick_at($f, 5000), 0, 'window 0: the watch is off');
    is(scalar($f->{ce}->calls), 0, 'no call');
    is(scalar(issues_of($f, 'boot-stalled')) + scalar(issues_of($f, 'boot-watch-blind')), 0, 'no issue');
}
{
    my $f = fixture(settings => { max => 1 });
    tick_at($f, 400);
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 1, 'max 1: one reset');
    tick_at($f, 400);
    is(scalar(issues_of($f, 'boot-stalled')), 1, 'then the issue');
    like((issues_of($f, 'boot-stalled'))[0]{summary}, qr/1 reset\(s\) tried/, 'naming the one try');
}

#=== the reset itself fails
{
    my $f = fixture();
    $f->{ce}{rc}{"vm-start"} = 1;
    tick_at($f, 400);
    my ($i) = issues_of($f, 'boot-stalled');
    ok($i, 'a reset that fails opens the issue at once');
    like($i->{trail}[0]{detail}, qr/reset 1 failed: start failed/, 'naming what failed');
    ok(rec($f)->{vms}{'n0-node'}{boot_watch}{gave_up}, 'and the watch stops trying');
    $f->{ce}{calls} = [];
    tick_at($f, 400);
    is(scalar($f->{ce}->calls), 0, 'no second attempt');
}

#=== an operator's own restart begins a new episode
{
    my $f = fixture();
    tick_at($f, 400);
    tick_at($f, 200);
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 2, 'two tries so far');
    $T += 50;
    $f->{wl_obj}->run('stop', 'n0', vm => 'n0-node');
    $T += 10;
    $f->{wl_obj}->run('start', 'n0', vm => 'n0-node');
    $f->{ce}{calls} = [];
    tick_at($f, 400);
    is(rec($f)->{vms}{'n0-node'}{boot_watch}{tries}, 1, 'a start that is not ours: the count begins again');
}

#=== unreadable and missing: reported, never fine, never a reset
{
    my $f = fixture();
    $f->{reg}->host_set($HOST, 'last_boot_at', 'garbage');
    is(tick_at($f, 400), 1, 'an unreadable last_boot_at: acted on (reported)');
    is(scalar($f->{ce}->calls), 0, 'never a reset');
    my ($b) = issues_of($f, 'boot-watch-blind');
    ok($b, 'a boot-watch-blind issue is open');
    like($b->{summary}, qr/n0\/n0-node.*last_boot_at 'garbage'/, 'naming the VM and the value');
    is(scalar(issues_of($f, 'boot-stalled')), 0, 'and no boot-stalled issue');
    $f->{reg}->host_set($HOST, 'last_boot_at', $T + 1);
    tick_at($f, 20);
    is($f->{issues}->get($b->{id})->{state}, 'resolved', 'readable again: the blind issue resolves');
}
{
    my $f = fixture();
    my $r = rec($f);
    delete $r->{vms}{'n0-node'}{started_at};
    $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    tick_at($f, 400);
    is(scalar($f->{ce}->calls), 0, 'no started_at: never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/no usable start time/, 'reported');
}
{
    my $f = fixture();
    my $r = rec($f);
    delete $r->{vms}{'n0-node'}{macs};
    $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    tick_at($f, 400);
    is(scalar($f->{ce}->calls), 0, 'no MAC on record: never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/no MAC/, 'reported');
}
{
    my $f = fixture();
    my $dir = $f->{reg}->workload_dir('lab');
    unlink "$dir/n0.json";
    tick_at($f, 400);
    is(scalar($f->{ce}->calls), 0, 'a record with no definition: never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/definition workloads\/n0\.json is unreadable/, 'reported');
}
{
    my $f = fixture();
    open(my $h, '>', $f->{reg}->cluster_dir('lab') . '/cluster.db/workload_n0.json') or die;
    print {$h} '{ not json';
    close $h;
    tick_at($f, 400);
    is(scalar($f->{ce}->calls), 0, 'an unreadable record: never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/workload record workload_n0 is unreadable/, 'reported');
}
{
    my $f = fixture();
    my $r = rec($f);
    delete $r->{vms}{'n0-node'};
    $r->{vms}{other} = { state => 'running' };
    $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    tick_at($f, 400);
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/no entry for VM n0-node/, 'a record without the VM: reported');
}

#=== settings come from the cluster keys when none are injected
{
    my $f = fixture();
    delete $f->{bw}{settings};
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '60');
    $f->{reg}->cluster_set('lab', 'boot_stall_max_resets', '9');
    my $s = $f->{bw}->settings;
    is($s->{window}, 60, 'window from boot_stall_window_seconds');
    is($s->{max}, 9, 'max from boot_stall_max_resets');
    is($s->{metal}, 0, 'metal off by default');
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '5');
    $s = $f->{bw}->settings;
    is($s->{window}, 180, 'a bad window: the default');
    like($s->{warnings}[0], qr/boot_stall_window_seconds='5'/, 'with a warning');
    is(tick_at($f, 20), 0, 'a tick with a warning still runs');
    ok((grep { /state=bad-setting/ } @{ $f->{log} }), 'and says so once');
}

#=== hps-workload status: "no netboot seen since start (N s)"
{
    my $f = fixture();
    $T += 95;
    my $out = { vms => [ { vm => 'n0-node', recorded_state => 'running' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    is($out->{vms}[0]{netboot_note}, 'no netboot seen since start (95 s)', 'status: no netboot seen, with the seconds');
    init_at($f, $T);
    $out = { vms => [ { vm => 'n0-node', recorded_state => 'running' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    ok(!exists $out->{vms}[0]{netboot_note}, 'status: netbooted, no note');
    $f->{reg}->host_set($HOST, 'last_boot_at', 'junk');
    $out = { vms => [ { vm => 'n0-node', recorded_state => 'running' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    like($out->{vms}[0]{netboot_note}, qr/netboot state unreadable/, 'status: unreadable is said, not hidden');
    $out = { vms => [ { vm => 'n0-node', recorded_state => 'stopped' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    ok(!exists $out->{vms}[0]{netboot_note}, 'status: a stopped VM has no note');
}

done_testing;
