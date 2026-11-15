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
is_deeply([ HPS::BootWatch::window(undef) ], [ 180, undef ], 'window: unset is 180');
is_deeply([ HPS::BootWatch::window('0') ], [ 0, undef ], 'window: 0 turns the watch off');
is_deeply([ HPS::BootWatch::window('30') ], [ 30, undef ], 'window: 30 is the least');
is_deeply([ HPS::BootWatch::window('86400') ], [ 86400, undef ], 'window: 86400 is the most');
for my $bad ('29', '86401', 'x', '-5') {
    my ($v, $w) = HPS::BootWatch::window($bad);
    is($v, 180, "window '$bad': 180");
    like($w, qr/boot_stall_window_seconds='\Q$bad\E'/, "window '$bad': warned");
}
is_deeply([ HPS::BootWatch::max_resets(undef) ], [ 3, undef ], 'max_resets: unset is 3');
is_deeply([ HPS::BootWatch::max_resets('0') ], [ 0, undef ], 'max_resets: 0 reports only');
is_deeply([ HPS::BootWatch::max_resets('20') ], [ 20, undef ], 'max_resets: 20');
my ($v, $w) = HPS::BootWatch::max_resets('21');
is($v, 3, 'max_resets 21: 3');
like($w, qr/boot_stall_max_resets='21'/, 'and warned');
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

done_testing;
