#!/usr/bin/env perl
# docs/BOOT-RELIABILITY.md, "Scope", "Baseline", "One reset per scan", "The breaker", "Clean-up":
# HPS::BootWatch only ever acts on a node THIS IPS can expect to see boot (a NIC on the
# provisioning net, its MAC on record), never on one that was already running when the watch
# was enabled, resets at most one node per scan, trips a circuit breaker when many look
# stalled at once, reads its settings again before every action, and removes the state and
# issues that outlived their cause. Against the real HPS::Workload on the fake runner and the
# real issue register.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::BootWatch;
use HPS::Issues;
use HPS::Event;

my $T = 1_800_000_000;
my $clock = sub { $T };
my @MAC = ('52:54:00:12:34:56', '52:54:00:12:34:57', '52:54:00:12:34:58');
sub hk { (my $m = $_[0]) =~ s/://g; return $m }

my $LAYOUT = { %{ StorageFixture::layout() },
    prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' },
    fab  => { kind => 'fabric', purpose => 'emulated-switch', bridge => 'br-fab' } };

# fixture(vms => [name...], nets => {name => [nets]}, late => seconds, settings => {}|sub):
# workload n0 with network-boot VMs started at $T; the watch object is made `late` seconds
# after the start (so the VMs were already running when it was enabled), default 0.
sub fixture {
    my (%o) = @_;
    my @names = @{ $o{vms} // ['a'] };
    my $def = { name => 'n0', project => 'lab', vms => [ map { { name => $_, memory_mib => 4096, vcpus => 2, boot => 'network',
        nets => ($o{nets}{$_} // ['prov']), compute_host => 'sch-001' } } @names ] };
    my $f = StorageFixture::setup_workload(no_def => 1,
        ce => { out => { 'vm-define' => [ map { "VM $names[$_] defined mac=$MAC[$_]\n" } 0 .. $#names ] } });
    $f->{reg}->cluster_set('lab', 'network_layout', $o{layout} // $LAYOUT);
    StorageFixture::write_def($f, $def);
    $f->{wl_obj} = $f->{wl}->(now => $clock);
    $f->{wl_obj}->run('create', 'n0');
    $f->{wl_obj}->run('start', 'n0', vm => $_) for @names;
    $f->{names} = \@names;
    $f->{ce}{calls} = [];
    $T += $o{late} // 0;
    $f->{issues} = HPS::Issues->new(registry => $f->{reg}, now => $clock, logger => sub { });
    $f->{log} = [];
    $f->{ready} = 'ready';
    $f->{settings} = $o{settings} // { window => 180, max => 3, nodes => 1, metal => 0, warnings => [] };
    $f->{bw} = HPS::BootWatch->new(registry => $f->{reg}, issues => $f->{issues}, workload => $f->{wl_obj}, now => $clock,
        ready => sub { $f->{ready} }, logger => sub { push @{ $f->{log} }, "$_[0] $_[1]" },
        settings => ($o{keys} ? undef : $f->{settings}));
    return $f;
}
sub rec { return $_[0]{reg}->cluster_get_json('lab', 'workload_n0') }
sub calls { return join ' ', map { $_->{script} . (grep({ $_ eq '--force' } @{ $_->{args} }) ? '(force)' : '') . ':' . ($_->{args}[0] // '') } $_[0]{ce}->calls }
sub resets { my ($f) = @_; return scalar grep { /state=reset / } @{ $f->{log} } }
sub issues_of { my ($f, $kind) = @_; return grep { $_->{kind} eq $kind && $_->{state} ne 'resolved' } $f->{issues}->list }
sub tick_at { my ($f, $dt) = @_; $T += $dt; return $f->{bw}->tick }
sub booted { my ($f, $i) = @_; $f->{reg}->host_set(hk($MAC[$i // 0]), 'last_boot_at', $T) }
sub said { my ($f, $re) = @_; return scalar grep { /$re/ } @{ $f->{log} } }

#=== a nested cluster's VM (its only NIC on the fabric net) is out of scope: never judged, reset, noted
{
    my $f = fixture(vms => ['n'], nets => { n => [ { net => 'fab', pvid => 110 } ] });
    is(tick_at($f, 100_000), 0, 'fabric-only VM, no netboot ever seen: nothing to do');
    is(calls($f), '', 'no node call');
    is(rec($f)->{vms}{n}{state}, 'running', 'it is left running');
    is(scalar(grep { $_->{state} ne 'resolved' } $f->{issues}->list), 0, 'no issue of any kind');
    is(said($f, '.'), 0, 'no event line at all (no "no netboot seen", no boot-stalled)');
    my $out = { vms => [ { vm => 'n', recorded_state => 'running' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    ok(!exists $out->{vms}[0]{netboot_note}, 'hps-workload status: no "no netboot seen" note for it');
    is(tick_at($f, 100_000), 0, 'and again much later');
    is(calls($f), '', 'still no node call');
}

#=== a provisioning VM that this IPS never saw boot and that was started long ago: baselined
{
    my $f = fixture(late => 50_000);
    is(tick_at($f, 100), 0, 'started 50 000 s before the watch existed, never booted: not judged');
    is(tick_at($f, 100_000), 0, 'and not later either');
    is(calls($f), '', 'never reset');
    is(scalar(grep { $_->{state} ne 'resolved' } $f->{issues}->list), 0, 'no issue');
    is(said($f, 'boot-stalled|reset'), 0, 'no stalled or reset line');
    my $out = { vms => [ { vm => 'a', recorded_state => 'running' } ] };
    HPS::BootWatch->annotate_status($f->{wl_obj}, 'n0', $out, now => $clock);
    like($out->{vms}[0]{netboot_note} // '', qr/no netboot seen since start/, 'the status line still says what is known (it is in scope)');
}

#=== a VM that booted once, then ran on, is baselined too (already running when first seen)
{
    my $f = fixture(late => 50_000);
    $f->{reg}->host_set(hk($MAC[0]), 'last_boot_at', $T - 90_000);
    is(tick_at($f, 100_000), 0, 'an old boot on record, running before the watch: not judged');
    is(calls($f), '', 'never reset');
}

#=== a provisioning VM started AFTER the watch began and not booting: stalled, reset
{
    my $f = fixture();
    is(tick_at($f, 100), 0, 'within the window: nothing');
    is(tick_at($f, 100), 1, 'past it, started after the watch began: acted on');
    is(calls($f), 'vm-stop(force):a vm-status:a vm-start:a', 'stop --force then start');
    is(resets($f), 1, 'one reset');
    is(rec($f)->{vms}{a}{boot_watch}{rules}, 2, 'the state carries the rule-set marker');
}

#=== the key going from 0 to 180 with VMs already running: baselined; only a later start is judged
{
    my $f = fixture(keys => 1, vms => [ 'a', 'b' ]);
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '0');
    is(tick_at($f, 10_000), 0, 'window 0: nothing, however long the VMs have been running');
    is(calls($f), '', 'no node call');
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '180');
    is(tick_at($f, 20), 0, 'the key becomes 180: both VMs were running, they are baselined');
    is(tick_at($f, 5_000), 0, 'and stay so hours later');
    is(calls($f), '', 'never reset');
    is(scalar(grep { $_->{state} ne 'resolved' } $f->{issues}->list), 0, 'no issue');
    # a VM started now (after the enable) is judged
    $f->{wl_obj}->run('stop', 'n0', vm => 'a');
    $T += 5;
    $f->{wl_obj}->run('start', 'n0', vm => 'a');
    $f->{ce}{calls} = [];
    is(tick_at($f, 100), 0, 'a VM started after the key changed, within its window: waiting');
    is(tick_at($f, 100), 1, 'past it, not booting: stalled and reset');
    is(resets($f), 1, 'one reset');
    like(calls($f), qr/\Avm-stop\(force\):a /, 'the VM started after the enable (a), not the baselined one (b)');
    # off and on again: whatever runs at that moment is baselined once more
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '0');
    tick_at($f, 20);
    $T += 20_000;
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '180');
    $f->{ce}{calls} = [];
    is(tick_at($f, 20), 0, 'off, then on again: the VMs running then are baselined again');
    is(calls($f), '', 'not reset');
}

#=== the key set to 0 stops the next action: re-read before every action, and every scan
{
    # window 180 at the start of the scan, 0 by the time of the first action
    my $calls = 0;
    my $f = fixture(settings => sub { ++$calls == 1 ? { window => 180, max => 3, nodes => 3, metal => 0, warnings => [] } : { window => 0, max => 3, nodes => 3, metal => 0, warnings => [] } });
    $T += 400;
    $calls = 0;
    is(tick_at($f, 1), 0, 'the window became 0 between the start of the scan and the action: nothing acted on');
    is(calls($f), '', 'no node call');
    is(said($f, 'boot-stalled'), 0, 'not even a "boot-stalled" line');
    cmp_ok($calls, '>=', 2, 'the settings were read again before the action');
}
{
    # a real key: set to 0 as soon as the first reset is logged; the second VM is stalled too
    my $f = fixture(keys => 1, vms => [ 'a', 'b' ]);
    $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '180');
    $f->{reg}->cluster_set('lab', 'boot_stall_max_nodes', '5');
    my $inner = $f->{bw}{logger};
    $f->{bw}{logger} = sub { push @{ $f->{log} }, "$_[0] $_[1]"; $f->{reg}->cluster_set('lab', 'boot_stall_window_seconds', '0') if $_[1] =~ /state=reset /; };
    is(tick_at($f, 400), 1, 'two stalled VMs: one reset in this scan');
    is(resets($f), 1, 'one reset line');
    is(tick_at($f, 20), 1, 'the key is 0 now: the second VM is not reset on the next scan (the scan only clears the first one\'s state)');
    ok(!exists rec($f)->{vms}{a}{boot_watch}, 'the watch state of the reset VM is gone');
    is(tick_at($f, 20), 0, 'nor on the one after');
    is(resets($f), 1, 'still only the one reset');
    my @stops = grep { /\Avm-stop/ } map { $_->{script} } $f->{ce}->calls;
    is(scalar(@stops), 1, 'one vm-stop in all');
}

#=== at most one reset per scan; the breaker (default 1) with two stalled nodes
{
    my $f = fixture(vms => [ 'a', 'b' ], settings => { window => 180, max => 3, nodes => 3, metal => 0, warnings => [] });
    is(tick_at($f, 400), 1, 'breaker 3, two stalled: one reset this scan');
    is(resets($f), 1, 'one reset line');
    like(calls($f), qr/\Avm-stop\(force\):a vm-status:a vm-start:a\z/, 'the first (by name) is reset');
    is(scalar(issues_of($f, 'boot-watch-many')), 0, 'the breaker is not tripped (2 is within 3)');
    is(tick_at($f, 5), 0, 'a scan inside the scan interval does nothing');
    is(tick_at($f, 20), 1, 'the next scan: the other one');
    is(resets($f), 2, 'two resets in all');
    like(calls($f), qr/vm-stop\(force\):b vm-status:b vm-start:b\z/, 'it is the second VM');
}
{
    my $f = fixture(vms => [ 'a', 'b' ], settings => { window => 180, max => 3, nodes => 1, metal => 0, warnings => [] });
    is(tick_at($f, 400), 0, 'default breaker (1), two stalled in one scan: no reset');
    is(calls($f), '', 'no node call');
    my @i = issues_of($f, 'boot-watch-many');
    is(scalar(@i), 1, 'one issue');
    like($i[0]{summary}, qr/many nodes look stalled at once: more likely a fault in the watch or the boot service than in the nodes/, 'it says so');
    like($i[0]{summary}, qr/n0\/a, n0\/b/, 'naming the nodes');
    ok(said($f, 'kind=boot subject=watch state=tripped many nodes look stalled at once'), 'and a standing event line');
    is(scalar(issues_of($f, 'boot-stalled')), 0, 'no per-node issue');
    is(tick_at($f, 20), 0, 'the next scan: still nothing');
    is(scalar(issues_of($f, 'boot-watch-many')), 1, 'still the one issue');
    is(resets($f), 0, 'no reset');
    # one of them boots: the other is alone, the breaker clears, and it is reset
    booted($f, 0);
    is(tick_at($f, 20), 1, 'one boots: the breaker closes and the other is reset');
    is(scalar(issues_of($f, 'boot-watch-many')), 0, 'the breaker issue is resolved');
    ok(said($f, 'kind=boot subject=watch state=cleared'), 'with a clearing line');
    is(resets($f), 1, 'one reset');
    like(calls($f), qr/vm-stop\(force\):b/, 'of the VM still not booting');
}

#=== a node that already gave up does not count towards the breaker
{
    my $f = fixture(vms => [ 'a', 'b' ], settings => { window => 180, max => 0, nodes => 1, metal => 0, warnings => [] });
    $f->{reg}->host_set(hk($MAC[1]), 'last_boot_at', $T + 1);    # b boots
    is(tick_at($f, 400), 1, 'max 0: a gives up at once (one stalled node)');
    is(scalar(issues_of($f, 'boot-stalled')), 1, 'its issue');
    $f->{wl_obj}->run('stop', 'n0', vm => 'b');
    $T += 5;
    $f->{wl_obj}->run('start', 'n0', vm => 'b');
    is(tick_at($f, 400), 2, 'b was restarted and does not boot: a (gave up earlier) and b are both acted on');
    is(scalar(issues_of($f, 'boot-watch-many')), 0, 'one newly stalled node and one that gave up earlier: not many, the breaker stays shut');
    is(scalar(issues_of($f, 'boot-stalled')), 2, 'each has its own issue');
}

#=== leftovers: state written by an older rule set is cleared, never resumed
{
    my $f = fixture();
    my $r = rec($f);
    $r->{vms}{a}{boot_watch} = { tries => 2, last_try_at => $T - 10, expect => $r->{vms}{a}{started_at}, gave_up => 1 };
    $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    my ($i) = $f->{issues}->open_issue(kind => 'boot-stalled', fields => { workload => 'n0', vm => 'a' }, key_fields => [ 'workload', 'vm' ],
        severity => 'warning', summary => 'workload n0 VM a did not reach iPXE: 2 reset(s) tried', detail => 'old', by => 'hps-bootwatch');
    is(tick_at($f, 20), 1, 'an old boot_watch state: acted on (cleared)');
    ok(!exists rec($f)->{vms}{a}{boot_watch}, 'the state is gone');
    is($f->{issues}->get($i->{id})->{state}, 'resolved', 'its boot-stalled issue is resolved');
    ok(said($f, 'kind=boot subject=n0/a state=cleared'), 'and a clearing line says so, so a standing boot line ends');
    is(calls($f), '', 'nothing was sent to the node');
    is(tick_at($f, 20), 0, 'the next scan: quiet');
    is(said($f, 'state=cleared'), 1, 'one clearing line');
    is(tick_at($f, 400), 1, 'it is then judged afresh: past the window, started after the watch began: reset 1 of 3');
    like((grep { /state=boot-stalled/ } @{ $f->{log} })[0] // '', qr/reset 1 of 3/, 'with no tries carried over');
}

#=== leftovers: a VM that became out of scope has its state and issues cleared
{
    my $f = fixture();
    tick_at($f, 400);    # reset 1: state written, with the marker
    ok(rec($f)->{vms}{a}{boot_watch}, 'set up: a state exists');
    my %l = %$LAYOUT;
    $l{prov} = { %{ $l{prov} }, purpose => 'workload' };
    $f->{reg}->cluster_set('lab', 'network_layout', \%l);
    $f->{ce}{calls} = [];
    is(tick_at($f, 400), 1, 'the VM is no longer on the provisioning net: cleared');
    ok(!exists rec($f)->{vms}{a}{boot_watch}, 'state removed');
    ok(said($f, 'subject=n0/a state=cleared'), 'a clearing line');
    is(calls($f), '', 'not reset');
    is(tick_at($f, 400), 0, 'and left alone');
}

#=== leftovers with the watch off: state, blind and stalled issues and the breaker issue are cleared, once
{
    my $f = fixture(vms => [ 'a', 'b' ], settings => { window => 180, max => 3, nodes => 1, metal => 0, warnings => [] });
    tick_at($f, 400);    # breaker trips: issue
    is(scalar(issues_of($f, 'boot-watch-many')), 1, 'set up: the breaker issue');
    my $r = rec($f);
    $r->{vms}{a}{boot_watch} = { tries => 1, expect => $r->{vms}{a}{started_at}, gave_up => 1, rules => 2 };
    $f->{reg}->cluster_set('lab', 'workload_n0', $r);
    $f->{issues}->open_issue(kind => 'boot-stalled', fields => { workload => 'n0', vm => 'a' }, key_fields => [ 'workload', 'vm' ],
        severity => 'warning', summary => 's', detail => 'd', by => 'hps-bootwatch');
    $f->{issues}->open_issue(kind => 'boot-watch-blind', fields => { workload => 'n0', vm => 'b' }, key_fields => [ 'workload', 'vm' ],
        severity => 'warning', summary => 's', detail => 'd', by => 'hps-bootwatch');
    $f->{settings}{window} = 0;
    is(tick_at($f, 20), 3, 'the watch is switched off: the node state, the blind issue and the breaker issue cleared');
    ok(!exists rec($f)->{vms}{a}{boot_watch}, 'state removed');
    is(scalar(grep { $_->{state} ne 'resolved' && $_->{kind} =~ /\Aboot-/ } $f->{issues}->list), 0, 'no open boot issue is left');
    ok(said($f, 'subject=n0/a state=cleared .*off'), 'a clearing line for the node');
    ok(said($f, 'subject=watch state=cleared'), 'and one for the breaker');
    my $n = said($f, 'state=cleared');
    is(tick_at($f, 400), 0, 'later scans while off: nothing more');
    is(said($f, 'state=cleared'), $n, 'no repeated clearing line');
    is(calls($f), '', 'no node call');
}

#=== an episode of this rule set is resumed after a restart of the process, not abandoned
{
    my $f = fixture();
    tick_at($f, 400);    # reset 1
    is(rec($f)->{vms}{a}{boot_watch}{tries}, 1, 'set up: one reset recorded');
    $T += 100;
    my $bw2 = HPS::BootWatch->new(registry => $f->{reg}, issues => $f->{issues}, workload => $f->{wl_obj}, now => $clock,
        ready => sub { 'ready' }, logger => sub { push @{ $f->{log} }, "$_[0] $_[1]" }, settings => $f->{settings});
    $T += 100;
    is($bw2->tick, 1, 'a new watch process, a window after the reset: the episode goes on (reset 2)');
    is(rec($f)->{vms}{a}{boot_watch}{tries}, 2, 'two tries');
}

#=== the scope cannot be told: reported, never reset
{
    my $f = fixture();
    $f->{reg}->cluster_set('lab', 'network_layout', 'junk');
    is(tick_at($f, 400), 1, 'layout unreadable: reported');
    is(calls($f), '', 'never a reset');
    my ($b) = issues_of($f, 'boot-watch-blind');
    ok($b, 'a boot-watch-blind issue');
    like($b->{summary}, qr/boot watch cannot judge n0\/\*: definition workloads\/n0\.json is unreadable .*network_layout/, 'saying what is not known (the definition is checked against the layout)');
    $f->{reg}->cluster_set('lab', 'network_layout', $LAYOUT);
    tick_at($f, 20);
    is(scalar(issues_of($f, 'boot-watch-blind')), 0, 'readable again: the issue resolves');
}
{
    my %l = (%$LAYOUT, prov => { %{ $LAYOUT->{prov} } });
    delete $l{prov}{purpose};
    my $f = fixture(layout => \%l);
    tick_at($f, 400);
    is(calls($f), '', 'a network without a purpose: never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary} // '', qr/network 'prov' has no known purpose/, 'reported');
}

{
    # the layout read fails after the definition loaded: cannot tell, per VM
    my $f = fixture();
    no warnings 'redefine';
    local *HPS::BootWatch::_layout = sub { return undef };
    is(tick_at($f, 400), 1, 'layout cannot be read: reported');
    is(calls($f), '', 'never a reset');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary} // '', qr/cannot tell whether VM a boots from this IPS: network_layout \(cluster config\) is unreadable/, 'saying what is not known');
}

#=== a disk-boot VM and a stopped VM are still never touched
{
    my $f = fixture();
    $f->{wl_obj}->run('stop', 'n0', vm => 'a');
    $f->{ce}{calls} = [];
    is(tick_at($f, 1000), 0, 'a VM stopped on purpose: nothing');
    is(calls($f), '', 'no call');
}

#=== settings from the cluster keys: the watch is off unless it is turned on
{
    my $f = fixture(keys => 1);
    my $s = $f->{bw}->settings;
    is($s->{window}, 0, 'no key set: window 0 (off)');
    is($s->{nodes}, 1, 'breaker 1');
    $f->{reg}->cluster_set('lab', 'boot_stall_max_nodes', '4');
    is($f->{bw}->settings->{nodes}, 4, 'boot_stall_max_nodes read');
    $f->{reg}->cluster_set('lab', 'boot_stall_max_nodes', 'x');
    $s = $f->{bw}->settings;
    is($s->{nodes}, 1, 'a bad breaker value: 1');
    like($s->{warnings}[0], qr/boot_stall_max_nodes='x'/, 'with a warning');
    is(tick_at($f, 5000), 0, 'default settings: the watch does nothing');
    is(calls($f), '', 'no call');
}

done_testing;
