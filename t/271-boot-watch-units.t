#!/usr/bin/env perl
# Layer 2 (docs/BOOT-RELIABILITY.md): the pure parts of HPS::BootWatch - the three
# settings, parse_stamp, netboot_state, decide (every state and action), status_note
# and netboot_vms.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::BootWatch;

#--- settings
is_deeply([ HPS::BootWatch::window(undef) ], [ 0, undef ], 'window: unset is 0, the watch ships off');
is_deeply([ HPS::BootWatch::window('0') ], [ 0, undef ], 'window: 0 turns the watch off');
is_deeply([ HPS::BootWatch::window('30') ], [ 30, undef ], 'window: 30 is the least');
is_deeply([ HPS::BootWatch::window('86400') ], [ 86400, undef ], 'window: 86400 is the most');
for my $bad ('29', '86401', 'x', '-5') {
    my ($v, $w) = HPS::BootWatch::window($bad);
    is($v, 0, "window '$bad': off (0), never a guessed window");
    like($w, qr/boot_stall_window_seconds='\Q$bad\E'/, "window '$bad': warned");
}
is_deeply([ HPS::BootWatch::max_resets(undef) ], [ 3, undef ], 'max_resets: unset is 3');
is_deeply([ HPS::BootWatch::max_resets('0') ], [ 0, undef ], 'max_resets: 0 reports only');
is_deeply([ HPS::BootWatch::max_resets('20') ], [ 20, undef ], 'max_resets: 20');
my ($v, $w) = HPS::BootWatch::max_resets('21');
is($v, 3, 'max_resets 21: 3');
like($w, qr/boot_stall_max_resets='21'/, 'and warned');
is_deeply([ HPS::BootWatch::max_nodes(undef) ], [ 1, undef ], 'max_nodes: unset is 1');
is_deeply([ HPS::BootWatch::max_nodes('100') ], [ 100, undef ], 'max_nodes: 100');
for my $bad ('0', '101', 'x') {
    my ($nv, $nw) = HPS::BootWatch::max_nodes($bad);
    is($nv, 1, "max_nodes '$bad': 1");
    like($nw, qr/boot_stall_max_nodes='\Q$bad\E'/, "max_nodes '$bad': warned");
}
is_deeply([ HPS::BootWatch::metal_reset(undef) ], [ 0, undef ], 'metal_reset: unset is false');
is_deeply([ HPS::BootWatch::metal_reset('true') ], [ 1, undef ], 'metal_reset: true');
is_deeply([ HPS::BootWatch::metal_reset('False') ], [ 0, undef ], 'metal_reset: False');
($v, $w) = HPS::BootWatch::metal_reset('yes');
is($v, 0, 'metal_reset yes: false');
like($w, qr/boot_stall_metal_reset='yes'/, 'and warned');

#--- parse_stamp
is(HPS::BootWatch::parse_stamp('2026-11-15 19:05:00 UTC'), 1794769500, 'the workload record stamp');
is(HPS::BootWatch::parse_stamp('2026-11-15T19:05:00Z'), 1794769500, 'ISO UTC');
is(HPS::BootWatch::parse_stamp('1794769500'), 1794769500, 'an epoch');
for my $bad (undef, '', 'yesterday', '2026-11-15', '2026-13-45 99:99:99 UTC', [1]) {
    is(HPS::BootWatch::parse_stamp($bad), undef, 'not a stamp: ' . (defined $bad ? (ref $bad ? 'a reference' : "'$bad'") : 'undef'));
}

#--- netboot_state
my $now = 2_000_000_000;
my $since = $now - 500;
is_deeply([ HPS::BootWatch::netboot_state(undef, $since, $now) ], [ 'not_seen', 'no iPXE init recorded' ], 'no last_boot_at: not seen');
is((HPS::BootWatch::netboot_state($since + 10, $since, $now))[0], 'seen', 'an init after the start: seen');
is((HPS::BootWatch::netboot_state($since, $since, $now))[0], 'seen', 'an init at the start: seen');
is((HPS::BootWatch::netboot_state($since - 30, $since, $now))[0], 'seen', 'an init 30 s before the stamp: seen (the stamp is written after vm-start returns)');
is((HPS::BootWatch::netboot_state($since - 61, $since, $now))[0], 'not_seen', 'an init 61 s before the start: not seen');
is((HPS::BootWatch::netboot_state($since - 5000, $since, $now))[0], 'not_seen', 'an old init: not seen');
for my $bad ('', 'abc', '12', '1e9') {
    is((HPS::BootWatch::netboot_state($bad, $since, $now))[0], 'unreadable', "last_boot_at '$bad': unreadable");
}
my ($s, $d) = HPS::BootWatch::netboot_state($now + 10_000, $since, $now);
is($s, 'unreadable', 'an init in the future: unreadable');
like($d, qr/in the future/, 'and says so');
is((HPS::BootWatch::netboot_state($now + 100, $since, $now))[0], 'seen', 'a small clock skew is tolerated');

#--- decide
my %base = (window => 180, max => 3, tries => 0, gave_up => 0, now => $now, since => $now - 400, last_try => undef,
    recorded => 'running', netboot => 'not_seen', netboot_detail => 'x', ready => 1, may_reset => 1);
sub d { my (%o) = @_; return HPS::BootWatch::decide(%base, %o) }
sub is_da { my ($got, $state, $action, $label) = @_; is_deeply([ $got->{state}, $got->{action} ], [ $state, $action ], $label) or diag $got->{reason} }

is_da(d(), 'boot-stalled', 'reset', 'running, no netboot past the window: reset');
is_da(d(window => 0), 'disabled', 'none', 'window 0: the watch is off');
for my $r (qw(stopped suspended creating defined created partial failed), '', undef) {
    is_da(d(recorded => $r), 'not-watched', 'none', 'recorded ' . ($r // 'undef') . ": never reset");
}
is_da(d(since => undef), 'unreadable', 'report', 'no start time: reported, not a reset');
is_da(d(since => undef, netboot => 'seen'), 'unreadable', 'report', 'no start time beats a seen netboot (the start is what is unknown)');
is_da(d(netboot => 'unreadable', netboot_detail => 'last_boot_at is junk'), 'unreadable', 'report', 'last_boot_at unreadable: reported');
is(d(netboot => 'unreadable', netboot_detail => 'last_boot_at is junk')->{reason}, 'last_boot_at is junk', 'with the detail');
is_da(d(netboot => undef), 'unreadable', 'report', 'no netboot fact at all: reported, never fine');
is_da(d(netboot => 'seen'), 'booted', 'none', 'netboot seen: booted');
is_da(d(netboot => 'seen', tries => 2), 'booted', 'resolve', 'netboot seen after resets: resolve');
is_da(d(netboot => 'seen', gave_up => 1), 'booted', 'resolve', 'netboot seen after giving up: resolve');
is_da(d(since => $now - 100), 'booting', 'none', 'within the window: waiting');
is_da(d(since => $now - 179), 'booting', 'none', '179 s of 180: still waiting');
is_da(d(since => $now - 180), 'boot-stalled', 'reset', '180 s: stalled');
is_da(d(since => $now - 5000, last_try => $now - 100, tries => 1), 'booting', 'none', 'the window runs from the last try');
is_da(d(since => $now - 5000, last_try => $now - 200, tries => 1), 'boot-stalled', 'reset', 'a window after the last try: the next reset');
is_da(d(tries => 2), 'boot-stalled', 'reset', 'two resets done, limit 3: one more');
is_da(d(tries => 3), 'boot-stalled', 'give_up', 'three done: give up');
like(d(tries => 3)->{reason}, qr/reset 3 time\(s\) already \(limit 3\)/, 'the reason names the tries');
is_da(d(max => 0), 'boot-stalled', 'give_up', 'limit 0: report only, no reset');
is_da(d(may_reset => 0), 'boot-stalled', 'give_up', 'resets not allowed for this node: the issue only');
like(d(may_reset => 0)->{reason}, qr/automatic reset is off/, 'and says why');
is_da(d(ready => 0), 'boot-stalled', 'defer', 'the IPS boot services do not answer: defer, no try spent');
is_da(d(ready => undef), 'boot-stalled', 'reset', 'cannot tell if the IPS answers: reset');
is_da(d(ready => 0, tries => 3), 'boot-stalled', 'give_up', 'give up does not wait for the IPS');
is_da(d(since => $now - 100, ready => 0), 'booting', 'none', 'within the window the IPS state does not matter');

# a draining host: its guests were stopped on purpose, never reset one (and never start it)
is_da(d(draining => 1), 'draining', 'none', 'a VM on a draining host: never reset');
is_da(d(draining => 1, tries => 3), 'draining', 'none', 'nor reported as given up');
is_da(d(draining => 1, ready => 0), 'draining', 'none', 'nor deferred');
is_da(d(draining => 1, max => 0), 'draining', 'none', 'with the limit at 0 as well');
is_da(d(draining => 0), 'boot-stalled', 'reset', 'not draining: reset as before');
is_da(d(draining => undef), 'boot-stalled', 'reset', 'not asked (metal): reset as before');
is_da(d(draining => 'unknown'), 'unreadable', 'report', 'the drain key cannot be read: reported, never a reset');
is_da(d(draining => 1, netboot => 'seen'), 'booted', 'none', 'a draining host whose VM booted is still booted');
is_da(d(draining => 1, since => $now - 100), 'booting', 'none', 'within the window it is simply booting');
is_da(d(baselined => 1), 'baselined', 'none', 'running before the watch was enabled: not judged, never reset');
is_da(d(baselined => 1, netboot => 'unreadable'), 'baselined', 'none', 'and not reported either');
is_da(d(baselined => 1, since => undef), 'unreadable', 'report', 'no start time is still reported');
is_da(d(baselined => 1, window => 0), 'disabled', 'none', 'window 0 beats it');
# a stall that was logged is resolved by the boot that follows
is_da(d(netboot => 'seen', stalled => 1), 'booted', 'resolve', 'netboot seen after a boot-stalled line: resolve');

#--- status_note
is(HPS::BootWatch::status_note('not_seen', 95), 'no netboot seen since start (95 s)', 'status: not seen');
is(HPS::BootWatch::status_note('seen', 95), undef, 'status: seen has no note');
is(HPS::BootWatch::status_note('unreadable', 0, 'junk'), 'netboot state unreadable (junk)', 'status: unreadable');

#--- netboot_vms
my $def = { vms => [ { name => 'a', boot => 'network' }, { name => 'b', boot => 'disk' }, { name => 'c' }, { name => 'd', boot => 'network' } ] };
is_deeply([ HPS::BootWatch::netboot_vms($def) ], [ 'a', 'd' ], 'netboot_vms: the network-boot VMs');
is_deeply([ HPS::BootWatch::netboot_vms($def, 'd') ], ['d'], 'with a VM named');
is_deeply([ HPS::BootWatch::netboot_vms($def, 'b') ], [], 'a disk-boot VM named: none');
is_deeply([ HPS::BootWatch::netboot_vms({}) ], [], 'an empty definition: none');

#--- vm_scope: positive evidence that THIS IPS boots the VM
my $lay = { prov => { purpose => 'provisioning' }, fab => { kind => 'fabric', purpose => 'emulated-switch' }, mgmt => { purpose => 'workload' }, nop => { cidr => '10.0.0.0/24' } };
my $mac1 = '52:54:00:00:00:01';
sub sc { my ($nets, $macs) = @_; return (HPS::BootWatch::vm_scope({ nets => $nets }, $lay, $macs))[0] }
is(sc(['prov']), 'in', 'scope: a NIC on the provisioning net is in (gate form, no MACs)');
is(sc(['fab']), 'out', 'scope: a fabric-only VM (a nested cluster node) is out');
is(sc([ { net => 'fab', pvid => 110 } ]), 'out', 'scope: a NIC given as an object, fabric: out');
is(sc(['mgmt']), 'out', 'scope: a net of another known purpose: out');
is(sc(['fab', { net => 'prov' }]), 'in', 'scope: one NIC on provisioning is enough');
is(sc(['nop']), 'unknown', 'scope: a net without a purpose: cannot tell');
is(sc(['gone']), 'unknown', 'scope: a net not in the layout: cannot tell');
is(sc(['fab', 'gone']), 'unknown', 'scope: no provisioning NIC and one NIC unknown: cannot tell, not out');
is(sc([]), 'unknown', 'scope: no NIC: cannot tell');
is((HPS::BootWatch::vm_scope({ nets => ['prov'] }, undef))[0], 'unknown', 'scope: no layout: cannot tell');
is((HPS::BootWatch::vm_scope({ nets => ['prov'] }, 'junk'))[0], 'unknown', 'scope: a layout that is not a hash: cannot tell');
is(sc(['prov'], [$mac1]), 'in', 'scope with MACs: the provisioning NIC has its MAC on record: in');
is(sc(['fab', 'prov'], [ 'aa:aa:aa:aa:aa:aa', $mac1 ]), 'in', 'scope with MACs: the MAC of the provisioning NIC (index 1)');
is(sc(['prov'], []), 'unknown', 'scope with MACs: none on record: cannot tell');
is(sc(['prov', 'fab'], [$mac1]), 'unknown', 'scope with MACs: the count differs from the NICs: cannot tell');
is(sc(['prov'], ['junk']), 'unknown', 'scope with MACs: a MAC that is not one: cannot tell');
is(sc(['fab'], [$mac1]), 'out', 'scope with MACs: out stays out');

#--- netboot_vms with a layout (the readiness gate and the status note)
my $ldef = { vms => [ { name => 'p', boot => 'network', nets => ['prov'] }, { name => 'o', boot => 'network', nets => [ 'fab', { net => 'prov' } ] },
    { name => 'f', boot => 'network', nets => [ { net => 'fab', pvid => 110 } ] }, { name => 'm', boot => 'network', nets => ['mgmt'] },
    { name => 'x', boot => 'network', nets => ['gone'] }, { name => 'd', boot => 'disk', nets => ['prov'] } ] };
is_deeply([ HPS::BootWatch::netboot_vms($ldef, undef, $lay) ], [qw(p o x)], 'with a layout: the VMs that boot from this IPS, and the ones that cannot be told (gating is harmless); not fabric-only or other-purpose ones');
is_deeply([ HPS::BootWatch::netboot_vms($ldef, 'f', $lay) ], [], 'a fabric-only VM named: none, so it is not gated');
is_deeply([ HPS::BootWatch::netboot_vms($ldef, 'x', $lay) ], ['x'], 'an unknown-scope VM named: gated');
is_deeply([ HPS::BootWatch::netboot_vms($ldef) ], [qw(p o f m x)], 'without a layout: every network-boot VM');
is_deeply([ HPS::BootWatch::netboot_vms($ldef, undef, 'junk') ], [qw(p o f m x)], 'a layout that is not a hash: every network-boot VM (cannot tell: gated)');

done_testing;

