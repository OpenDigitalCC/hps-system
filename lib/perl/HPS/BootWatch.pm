package HPS::BootWatch;
# Boot-stalled detection and recovery (docs/BOOT-RELIABILITY.md, layer 2).
#
# A VM of a workload that boots from the network ("boot": "network"), or a metal
# node the IPS powered on through its BMC, was started at T. The IPS records
# every iPXE init of a node (host key last_boot_at). No init after T within the
# window means the node never reached the IPS: for a VM that is the OVMF
# firmware shell (IPS-40), for metal a NIC that gave up after one PXE pass.
# The state is boot-stalled. The recovery is a reset (a VM: stop --force then
# start, through HPS::Workload; metal: BMC reset), at most boot_stall_max_resets
# times with the window between tries, then an issue (kind boot-stalled) that
# names the node, the tries and the console command.
#
# Pure parts (unit tested): parse_stamp, netboot_state, decide, the setting
# parsers, status_note. The class is the thin caller: it gathers the facts from
# the registry, asks decide, and acts. It runs in hps-issue-watch's tick (the
# healer's loop: same root process, same HPS::Issues, same runner), rate limited
# to one scan every SCAN_EVERY seconds.
#
# Scope and baseline (docs/BOOT-RELIABILITY.md): the watch acts only on a node THIS IPS can
# expect to see boot, by positive evidence: a VM with a NIC on a network of purpose
# provisioning whose MAC is on record (assigned by this IPS), or a metal node this IPS
# powered on. A nested cluster's VM (its only NIC on a fabric net) netboots from its own IPS
# and is out of scope: never judged, reset, noted or issued, and its state is cleared. A scope
# that cannot be told is reported (boot-watch-blind) and never acted on. A node that was
# already running when the watch was enabled (process start, or the window key leaving 0) is
# baselined, not judged: only a start after that can be judged. The watch ships off
# (boot_stall_window_seconds 0), is re-read before every action, resets at most one node per
# scan, and a breaker (boot_stall_max_nodes) stops all resets when many nodes look stalled at
# once. State written by an older rule set (no rules marker) is cleared, never resumed.
#
# Never reset: a VM whose recorded state is not running (stopped on purpose,
# suspended, creating, failed...); a node without a start time on record; a
# node whose record or last_boot_at cannot be read (that is its own reported
# case, issue kind boot-watch-blind, never "fine" and never a reset); a node
# while this IPS's boot services do not answer (the try is not spent); a VM
# whose compute host carries the host key drain (HPS::Workload::Drain: its
# guests were stopped on purpose, a reset would fight the drain, and its start
# would be refused), or whose host's drain key cannot be read (reported).
#
# State kept: the VM's record vms.<vm>.boot_watch, or the host key boot_watch:
# {tries, last_try_at, expect (the start stamp after our last reset), gave_up}.
# A start that is not ours (another stamp) begins a new episode: tries 0.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Time::Local ();
use POSIX ();
use HPS::BootReady ();
use HPS::Event ();
use HPS::Issues ();
use HPS::Registry ();

# The watch ships switched off (docs/BOOT-RELIABILITY.md): 0 until an operator turns it on.
use constant DEFAULT_WINDOW => 0;
use constant MIN_WINDOW     => 30;
use constant MAX_WINDOW     => 86400;
use constant DEFAULT_RESETS => 3;
use constant MAX_RESETS     => 20;
use constant DEFAULT_NODES  => 1;
use constant MAX_NODES      => 100;
# Written into every boot_watch state this code saves. A state without it comes from an
# older rule set and is cleared, never resumed.
use constant RULES          => 2;
# While the watch is off, the leftovers of an earlier run are looked for this often.
use constant STAND_DOWN_EVERY => 300;
use constant SCAN_EVERY     => 15;
# The start stamp is written when vm-start returns, a little after the guest
# began to boot; a netboot this much before the stamp still counts as ours.
use constant SLACK          => 60;
use constant FUTURE         => 300;

#=== settings (pure) =====================================================================

# window($raw): (seconds, warning). 0, the default, disables the watch; else 30..86400. A
# value that is not usable gives 0 (off) and a warning: never a guess at a window.
sub window ($raw) {
    my ($v, $w) = HPS::BootReady::int_setting($raw, DEFAULT_WINDOW, 0, MAX_WINDOW, 'boot_stall_window_seconds');
    return ($v, $w) if !$v || $v >= MIN_WINDOW;
    return (DEFAULT_WINDOW, "boot_stall_window_seconds='$raw' is not 0 or " . MIN_WINDOW . '..' . MAX_WINDOW . '; using ' . DEFAULT_WINDOW . ' (off)');
}

# max_nodes($raw): (n, warning). 1..100: the circuit breaker. More than n distinct nodes
# judged stalled in one scan and none of them is reset.
sub max_nodes ($raw) { return HPS::BootReady::int_setting($raw, DEFAULT_NODES, 1, MAX_NODES, 'boot_stall_max_nodes') }

# max_resets($raw): (n, warning). 0..20; 0 detects and reports only.
sub max_resets ($raw) { return HPS::BootReady::int_setting($raw, DEFAULT_RESETS, 0, MAX_RESETS, 'boot_stall_max_resets') }

# metal_reset($raw): (bool, warning). true or false; unset is false.
sub metal_reset ($raw) {
    return (0, undef) unless defined $raw && length $raw;
    my $v = lc $raw;
    $v =~ s/\A\s+|\s+\z//g;
    return (1, undef) if $v eq 'true';
    return (0, undef) if $v eq 'false';
    return (0, "boot_stall_metal_reset='$raw' is not true or false; using false");
}

#=== facts (pure) ========================================================================

# parse_stamp($text): epoch of "YYYY-MM-DD HH:MM:SS UTC" (what the workload record
# holds), "YYYY-MM-DDTHH:MM:SSZ", or a plain epoch; undef when it is none of them.
sub parse_stamp ($text) {
    return undef unless defined $text && !ref $text;
    return $text + 0 if $text =~ /\A[0-9]{9,11}\z/;
    my @p = $text =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]([0-9]{2}):([0-9]{2}):([0-9]{2})(?: UTC|Z)\z/ or return undef;
    return eval { Time::Local::timegm($p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0]) };
}

# netboot_state($last_boot_at, $since, $now): (state, detail).
#   seen        an iPXE init at or after the start (less the SLACK)
#   not_seen    none recorded, or only an older one
#   unreadable  the value is not an epoch, or lies in the future
# undef $last_boot_at: nothing recorded (a node that never booted has no host).
sub netboot_state ($last, $since, $now) {
    return ('not_seen', 'no iPXE init recorded') unless defined $last;
    return ('unreadable', "last_boot_at '$last' is not an epoch") unless !ref $last && $last =~ /\A[0-9]{9,11}\z/;
    return ('unreadable', "last_boot_at $last is in the future") if $last > $now + FUTURE;
    return $last >= $since - SLACK ? ('seen', "iPXE init at $last") : ('not_seen', "last iPXE init at $last is before the start");
}

# decide(%f): {state, action, reason}. Facts:
#   window, max, tries, gave_up, now, since (epoch or undef), last_try (epoch or undef),
#   recorded (the recorded state: only 'running' is watched), netboot (seen|not_seen|unreadable),
#   netboot_detail, ready (1 / 0 / undef = boot services answer / do not / unknown),
#   may_reset (false: report only, never act on the node),
#   stalled (a boot-stalled line was logged for this start: booted must say so),
#   draining (1 the VM's compute host carries host key drain, 0 it does not,
#   'unknown' the key cannot be read; undef = not asked, taken as 0).
# state:  disabled, not-watched, unreadable, booted, booting, draining, boot-stalled
# action: none, report (unreadable: report it, touch nothing), resolve (booted after
#         an episode), reset, defer (the IPS is deaf: try later, no try spent), give_up (open the issue)
sub decide (%f) {
    return { state => 'disabled', action => 'none', reason => 'boot_stall_window_seconds is 0' } unless $f{window};
    my $rec = $f{recorded} // '';
    return { state => 'not-watched', action => 'none', reason => "recorded state is '$rec', not running" } unless $rec eq 'running';
    return { state => 'unreadable', action => 'report', reason => 'no usable start time on record' } unless defined $f{since};
    # Already running when the watch first saw it (process start, or the window key
    # changing from 0): not judged. Only a start after that is.
    return { state => 'baselined', action => 'none', reason => 'running before the watch was enabled; not judged' } if $f{baselined};
    return { state => 'unreadable', action => 'report', reason => $f{netboot_detail} // 'netboot state unreadable' }
        if ($f{netboot} // 'unreadable') eq 'unreadable';
    if ($f{netboot} eq 'seen') {
        return { state => 'booted', action => ($f{tries} || $f{gave_up} || $f{stalled} ? 'resolve' : 'none'), reason => $f{netboot_detail} // 'netboot seen' };
    }
    my $from = defined $f{last_try} && $f{last_try} > $f{since} ? $f{last_try} : $f{since};
    my $elapsed = $f{now} - $from;
    return { state => 'booting', action => 'none', reason => "no netboot seen since start ($elapsed s of $f{window})" } if $elapsed < $f{window};
    # A draining host's guests were stopped on purpose: never reset (or start) one.
    if (($f{draining} // 0) eq 'unknown') {
        return { state => 'unreadable', action => 'report', reason => 'cannot tell whether the VM\'s compute host is draining (host key drain)' };
    }
    return { state => 'draining', action => 'none', reason => 'the VM\'s compute host carries the host key drain; never reset on a draining host' }
        if $f{draining};
    my $why = "no netboot seen $elapsed s after the start (window $f{window} s)";
    if (!$f{may_reset}) {
        return { state => 'boot-stalled', action => 'give_up', reason => "$why; automatic reset is off for this node" };
    }
    if (($f{tries} // 0) >= $f{max}) {
        return { state => 'boot-stalled', action => 'give_up', reason => "$why; reset $f{tries} time(s) already (limit $f{max})" };
    }
    if (defined $f{ready} && !$f{ready}) {
        return { state => 'boot-stalled', action => 'defer', reason => "$why; this IPS's boot services do not answer, not resetting into them" };
    }
    return { state => 'boot-stalled', action => 'reset', reason => $why };
}

# status_note($state, $seconds): the line hps-workload status shows, or undef.
sub status_note ($netboot, $seconds, $detail = '') {
    return "no netboot seen since start ($seconds s)" if $netboot eq 'not_seen';
    return "netboot state unreadable ($detail)" if $netboot eq 'unreadable';
    return undef;
}

# net_name($nic): the network name of one entry of a VM's nets (a name, or {net, ...}).
sub net_name ($n) { return ref $n eq 'HASH' ? $n->{net} : $n }

# vm_scope($vm, $layout, $macs): (scope, detail). Whether THIS IPS can expect to see the VM
# boot: in, out, or unknown. $vm is the definition's VM, $layout the cluster key
# network_layout (a hash), $macs the record's MACs (one per NIC, in order), or undef.
#   in       a NIC on a network of purpose provisioning (the L2 this IPS serves DHCP and
#            TFTP on), and, when $macs is given, that NIC's MAC is on record: the IPS's
#            own workload engine assigned it (and a host that netbooted with it is
#            registered under it). Positive evidence, not the absence of a boot.
#   out      every NIC is on a network whose purpose is known and is not provisioning (the
#            fabric net of a nested cluster: the VM netboots from its own IPS)
#   unknown  the layout, a network's purpose or the MAC cannot be told: reported, never acted on
# Without $macs (the readiness gate, before a MAC exists) only the network is looked at.
sub vm_scope ($vm, $layout, $macs = undef) {
    return ('unknown', 'network_layout (cluster config) is unreadable') unless ref $layout eq 'HASH';
    my @nets = map { net_name($_) } @{ ref $vm->{nets} eq 'ARRAY' ? $vm->{nets} : [] };
    return ('unknown', 'the definition lists no NIC') unless @nets;
    my (@prov, @unk);
    for my $i (0 .. $#nets) {
        my $n = $nets[$i];
        my $l = defined $n && !ref $n ? $layout->{$n} : undef;
        my $p = ref $l eq 'HASH' ? $l->{purpose} : undef;
        if (!defined $p || ref $p || !length $p) { push @unk, "network '" . (defined $n && !ref $n ? $n : '?') . "' has no known purpose"; next }
        push @prov, $i if $p eq 'provisioning';
    }
    unless (@prov) {
        return ('unknown', join('; ', @unk)) if @unk;
        return ('out', 'no NIC on a network of purpose provisioning: it boots from another IPS');
    }
    return ('in', 'a NIC on the provisioning network') unless defined $macs;
    return ('unknown', 'the record has no MAC for the VM') unless ref $macs eq 'ARRAY' && @$macs;
    return ('unknown', 'the record has ' . scalar(@$macs) . ' MAC(s), the definition ' . scalar(@nets) . ' NIC(s)') if @$macs != @nets;
    for my $i (@prov) {
        my $m = $macs->[$i];
        return ('in', "NIC $i ($m) is on the provisioning network and its MAC was assigned by this IPS")
            if defined $m && !ref $m && $m =~ /\A[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/i;
    }
    return ('unknown', 'the provisioning NIC has no usable MAC on record');
}

# netboot_vms($def, $only_vm, $layout): names of the VMs of a validated definition that
# boot from the network (the one named only, when given), for the readiness gate and the
# status note. With $layout (the network_layout hash) a VM that is out of scope (it does
# not boot from this IPS) is left out; one whose scope cannot be told is kept, because
# being gated is harmless. Without a layout every network-boot VM.
sub netboot_vms ($def, $only = undef, $layout = undef) {
    return map { $_->{name} } grep {
        ($_->{boot} // 'disk') eq 'network' && (!defined $only || $_->{name} eq $only)
            && (ref $layout ne 'HASH' || (vm_scope($_, $layout))[0] ne 'out')
    } @{ $def->{vms} // [] };
}

# _layout(): the cluster's network_layout hash, or undef when it cannot be read.
sub _layout ($self) {
    my $reg = $self->_reg;
    my $l = eval { $reg->cluster_get_json($reg->active_cluster, 'network_layout') };
    return ref $l eq 'HASH' ? $l : undef;
}

#=== the facts from the registry =========================================================

sub new ($class, %o) {
    my $reg = $o{registry} // HPS::Registry->new;
    my $now = $o{now} // sub { time };
    return bless {
        registry => $reg,
        issues   => $o{issues},                    # HPS::Issues, made on first use
        workload => $o{workload},                  # HPS::Workload, made on first use
        bmc      => $o{bmc},                       # HPS::BMC, made on first use
        ready    => $o{ready} // sub { HPS::BootReady::check(registry => $reg)->{verdict} },
        now      => $now,
        logger   => $o{logger} // \&_default_logger,
        settings => $o{settings},                  # tests: a hash, or a sub returning {window, max, nodes, metal}; else the cluster keys
        # When the watch was (last) enabled: the process start, or the scan that saw the window
        # key leave 0. A VM started before that is baselined, not judged. undef while it is off.
        enabled_at => $o{enabled_at} // $now->(),
        next_scan => 0, next_standdown => 0, blind => undef, said => {},
    }, $class;
}

sub _default_logger ($level, $msg) {
    print STDERR "hps-bootwatch: $msg\n";
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-bootwatch: $msg");
    };
    return;
}

sub _now ($self) { return $self->{now}->() }
sub _reg ($self) { return $self->{registry} }
sub _issues ($self) { return $self->{issues} //= HPS::Issues->new(registry => $self->{registry}) }
sub _wl ($self) { return $self->{workload} //= do { require HPS::Workload; HPS::Workload->new(registry => $self->{registry}) } }
sub _bmc ($self) { return $self->{bmc} //= do { require HPS::BMC; HPS::BMC->new(registry => $self->{registry}) } }

# _event($pri, $subject, $state, $text): the one place an event line is made: an
# HPS::Event marker line, kind boot (docs/LOGGING.md), subject <workload/vm or
# host>. The states boot-stalled, gave-up, unreadable and reset-failed are standing
# (a problem until a booted line); the callers repeat them every HPS::Event::REMIND.
sub _event ($self, $pri, $subject, $state, $text) {
    HPS::Event::log_event($self->{logger}, pri => $pri, kind => 'boot', subject => $subject, state => $state, text => $text);
    return;
}

# _say_once($key, $every, ...): the event, at most once per $every seconds per key.
sub _event_every ($self, $key, $every, @event) {
    my $now = $self->_now;
    return if defined $self->{said}{$key} && $now - $self->{said}{$key} < $every;
    $self->{said}{$key} = $now;
    $self->_event(@event);
    return;
}

sub _setting ($self, $key) {
    my $reg = $self->_reg;
    my $c = eval { $reg->active_cluster };
    return defined $c ? eval { $reg->cluster_get($c, $key) } : undef;
}

# settings(): {window, max, nodes, metal, warnings}, read afresh from the registry on every call
# (the keys may change: tick calls it at the start of a scan and again before every action).
sub settings ($self) {
    if (my $s = $self->{settings}) { return ref $s eq 'CODE' ? $s->() : $s }
    my ($w, $ww) = window($self->_setting('boot_stall_window_seconds'));
    my ($m, $mw) = max_resets($self->_setting('boot_stall_max_resets'));
    my ($t, $tw) = metal_reset($self->_setting('boot_stall_metal_reset'));
    my ($n, $nw) = max_nodes($self->_setting('boot_stall_max_nodes'));
    return { window => $w, max => $m, nodes => $n, metal => $t, warnings => [ grep { defined } $ww, $mw, $tw, $nw ] };
}

# last_boot($mac): (raw last_boot_at or undef when none recorded, error text or undef).
sub _last_boot ($self, $mac) {
    my $reg = $self->_reg;
    my $m = eval { $reg->resolve_mac($mac) } // return (undef, "not a MAC: $mac");
    my $v = eval { $reg->host_exists($m, 'last_boot_at') ? $reg->host_get($m, 'last_boot_at') : undef };
    return (undef, "host $m unreadable: " . ($@ =~ s/\s+\z//r)) if $@;
    return ($v, undef);
}

# vm_netboot($rv, $since, $now): (state, detail, ever) over every MAC of the VM's record:
# seen when any of them netbooted; unreadable when none did and any cannot be read. ever
# is 1 when this IPS has recorded a boot (any last_boot_at) for any of the MACs, ever.
sub vm_netboot ($self, $rv, $since, $now) {
    my @macs = ref $rv->{macs} eq 'ARRAY' ? grep { defined && !ref } @{ $rv->{macs} } : ();
    return ('unreadable', 'the record has no MAC for the VM', 0) unless @macs;
    my (@bad, $ever);
    for my $mac (@macs) {
        my ($raw, $err) = $self->_last_boot($mac);
        if (defined $err) { push @bad, $err; next }
        $ever = 1 if defined $raw;
        my ($s, $d) = netboot_state($raw, $since, $now);
        if ($s eq 'seen') { return ($s, "$mac: $d", 1) }
        push @bad, "$mac: $d" if $s eq 'unreadable';
    }
    return ('unreadable', join('; ', @bad), $ever // 0) if @bad;
    return ('not_seen', 'no iPXE init recorded after the start', $ever // 0);
}

#=== the scan ============================================================================

# _baselined($item): true when the item must not be judged: its start is older than the
# moment the watch was enabled (it was already running when the watch first saw it). An
# episode this rule set began (a state with the rules marker for the same start stamp) is
# resumed instead, so a restart of the process does not abandon a node mid-recovery. A VM
# this IPS has never recorded a boot for is a special case of the same rule: it can only be
# judged when it was started after the watch was enabled.
sub _baselined ($self, $it) {
    return 0 unless defined $it->{since};
    my $w = $it->{watch} // {};
    return 0 if ($w->{rules} // 0) == RULES && defined $w->{expect} && defined $it->{stamp} && $w->{expect} eq $it->{stamp};
    return 0 if defined $self->{enabled_at} && $it->{since} >= $self->{enabled_at};
    return 1;
}

# items(): one {kind, key, subject, ...facts, report?} per node the watch may judge: a
# VM (in scope: a NIC on the provisioning net, its MAC on record) or a metal node the IPS
# powered on. An item may carry:
#   report     the node cannot be judged (scope or facts unreadable): reported, never acted on
#   scope      'out' for a VM that boots from another IPS: no judgement, only a clean-up
#   clear_why  boot_watch state or issues that must be removed (out of scope, or written by
#              an older rule set)
#   baselined  running before the watch was enabled: not judged
sub items ($self) {
    my @out;
    my $reg = $self->_reg;
    my $c = eval { $reg->active_cluster } // return ();
    my $now = $self->_now;
    my $layout = $self->_layout;
    my @keys = eval { $reg->cluster_list($c) };
    for my $key (sort @keys) {
        my ($name) = $key =~ /\Aworkload_([a-z][a-z0-9-]{0,31})\z/ or next;
        my $rec = eval { $reg->cluster_get_json($c, $key) };
        my $err = $@ ? $@ =~ s/\s+\z//r : ref $rec ne 'HASH' ? 'not an object' : undef;
        my $def = defined $err ? undef : eval { $self->_wl->load($name) };
        my $derr = defined $err || $def ? undef : ($@ ? (ref $@ && $@->can('message') ? $@->message : $@ =~ s/\s+\z//r) : 'unreadable');
        if (defined $err) {
            # An unreadable record may hold a network-boot VM: report it, once per workload.
            push @out, { kind => 'vm', workload => $name, vm => '*', subject => "$name/*", key => "blind:$name",
                report => "workload record $key is unreadable: $err" };
            next;
        }
        if (defined $derr) {
            push @out, { kind => 'vm', workload => $name, vm => '*', subject => "$name/*", key => "blind:$name",
                report => "definition workloads/$name.json is unreadable ($derr), so it is not known whether its VMs boot from the network" };
            next;
        }
        # Readable again: a workload-level report from an earlier scan can end.
        push @out, { kind => 'vm', workload => $name, vm => '*', subject => "$name/*", key => "recovered:$name", recovered => 1 };
        for my $vmdef (grep { ($_->{boot} // 'disk') eq 'network' } @{ $def->{vms} // [] }) {
            my $vm = $vmdef->{name};
            my $rv = ref $rec->{vms} eq 'HASH' ? $rec->{vms}{$vm} : undef;
            my $it = { kind => 'vm', workload => $name, vm => $vm, subject => "$name/$vm", key => "$name/$vm" };
            my $macs = ref $rv eq 'HASH' ? (ref $rv->{macs} eq 'ARRAY' ? $rv->{macs} : []) : undef;
            my ($scope, $why) = vm_scope($vmdef, $layout, $macs);
            $it->{scope} = $scope;
            $it->{watch} = ref $rv eq 'HASH' && ref $rv->{boot_watch} eq 'HASH' ? $rv->{boot_watch} : {};
            if ($scope eq 'out') {
                $it->{clear_why} = "VM $vm boots from another IPS ($why)";
                push @out, $it;
                next;
            }
            if ($scope eq 'unknown') {
                $it->{report} = "cannot tell whether VM $vm boots from this IPS: $why";
                $it->{key} = "blind:$name/$vm";
                push @out, $it;
                next;
            }
            if (ref $rv ne 'HASH') {
                $it->{report} = "workload record $key has no entry for VM $vm";
                $it->{key} = "blind:$name/$vm";
                push @out, $it;
                next;
            }
            if (%{ $it->{watch} } && ($it->{watch}{rules} // 0) != RULES) {
                $it->{clear_why} = 'the boot-watch state was written by an older rule set';
                $it->{clear_state} = 1;
                $it->{watch} = {};
            }
            $it->{recorded} = $rv->{state};
            $it->{compute} = $rv->{host};
            $it->{stamp} = $rv->{started_at};
            $it->{since} = parse_stamp($rv->{started_at});
            if (($rv->{state} // '') eq 'running' && defined $it->{since}) {
                @$it{qw(netboot netboot_detail ever)} = $self->vm_netboot($rv, $it->{since}, $now);
            }
            $it->{baselined} = $self->_baselined($it);
            push @out, $it;
        }
    }
    push @out, $self->_metal_items($now);
    return @out;
}

sub _metal_items ($self, $now) {
    my $reg = $self->_reg;
    my @out;
    my @macs = eval { $reg->host_list_all };
    for my $mac (sort @macs) {
        my $on = eval { $reg->host_exists($mac, 'bmc_power_on_at') ? $reg->host_get($mac, 'bmc_power_on_at') : undef };
        next unless defined $on || $@;
        my $name = eval { $reg->fqdn($mac) } // $mac;
        my $it = { kind => 'metal', mac => $mac, host => $name, subject => $name, key => "metal:$mac", recorded => 'running', stamp => $on };
        if ($@) { $it->{report} = "host $mac unreadable: " . ($@ =~ s/\s+\z//r); $it->{key} = "blind:$mac"; push @out, $it; next }
        $it->{since} = parse_stamp($on);
        my $w = eval { $reg->host_exists($mac, 'boot_watch') ? $reg->host_get_json($mac, 'boot_watch') : undef };
        $it->{watch} = ref $w eq 'HASH' ? $w : {};
        if (%{ $it->{watch} } && ($it->{watch}{rules} // 0) != RULES) {
            $it->{clear_why} = 'the boot-watch state was written by an older rule set';
            $it->{clear_state} = 1;
            $it->{watch} = {};
        }
        if (defined $it->{since}) {
            my ($raw, $err) = $self->_last_boot($mac);
            @$it{qw(netboot netboot_detail)} = defined $err ? ('unreadable', $err) : netboot_state($raw, $it->{since}, $now);
            $it->{ever} = defined $raw ? 1 : 0;
        }
        $it->{baselined} = $self->_baselined($it);
        push @out, $it;
    }
    return @out;
}

# _draining($item): 1 when the VM's compute host carries the host key drain, 0 when
# it does not, 'unknown' when the host or the key cannot be looked up.
sub _draining ($self, $it) {
    my $host = $it->{compute};
    return 'unknown' unless defined $host && !ref $host && length $host;
    my $r = eval { $self->_reg->host_exists($self->_wl->_mac($host), 'drain') ? 1 : 0 };
    return defined $r ? $r : 'unknown';
}

# verdict_for($item, $settings, $ready_cb): decide() over an item's facts. The
# boot-services check ($ready_cb: 1, 0 or undef) runs only when a reset is due.
sub verdict_for ($self, $it, $s, $ready_cb) {
    my $w = $it->{watch} // {};
    my $same = defined $w->{expect} && defined $it->{stamp} && $w->{expect} eq $it->{stamp};
    my %f = (
        window => $s->{window}, max => $s->{max}, now => $self->_now,
        tries => ($same ? ($w->{tries} // 0) : 0), gave_up => ($same ? $w->{gave_up} : 0), last_try => ($same ? $w->{last_try_at} : undef),
        stalled => ($same ? $w->{stalled} : 0),
        draining => ($it->{kind} eq 'vm' && ($it->{netboot} // '') eq 'not_seen' ? $self->_draining($it) : 0),
        since => $it->{since}, recorded => $it->{recorded}, netboot => $it->{netboot}, netboot_detail => $it->{netboot_detail},
        may_reset => ($it->{kind} eq 'metal' ? $s->{metal} : $s->{max} > 0 ? 1 : 0),
        baselined => $it->{baselined},
    );
    my $v = decide(%f, ready => 1);
    $v = decide(%f, ready => $ready_cb->()) if $v->{action} eq 'reset';
    return $v;
}

#=== acting ==============================================================================

sub _issue_parts ($it) {
    return $it->{kind} eq 'vm'
        ? ({ workload => $it->{workload}, vm => ($it->{vm} eq '*' ? 'any' : $it->{vm}) }, [ 'workload', 'vm' ])
        : ({ host => $it->{host} }, ['host']);
}

sub _issue_key ($it, $kind) {
    my ($f, $kf) = _issue_parts($it);
    return HPS::Issues::make_key($kind, HPS::Issues::check_fields($f), @$kf);
}

sub _console_hint ($it) {
    return $it->{kind} eq 'vm' ? "hps-workload console $it->{workload} --vm $it->{vm}" : "hps-bmc console $it->{host}";
}

sub _msg ($e) {
    return ref $e && $e->can('message') ? $e->message : ($e // 'unknown error') =~ s/\s+\z//r;
}

# _open_keys($kind): the keys of the unresolved issues of that kind, read once and
# kept up to date by _open and _close.
sub _open_keys ($self, $kind) {
    return $self->{open}{$kind} //= { map { $_->{key} => 1 } grep { $_->{kind} eq $kind && $_->{state} ne 'resolved' } $self->_issues->list };
}

sub _open ($self, $it, $kind, $summary, $detail, %x) {
    my ($f, $kf) = _issue_parts($it);
    my ($rec) = $self->_issues->open_issue(kind => $kind, fields => $f, key_fields => $kf, severity => 'warning',
        summary => $summary, detail => $detail, by => 'hps-bootwatch', %x);
    $self->_open_keys($kind)->{ $rec->{key} } = 1;
    return $rec;
}

# _close($item, $kind, $by, $action, $result): resolves the item's open issue of
# that kind, when there is one. Returns true when it did.
sub _close ($self, $it, $kind, $action, $result) {
    my $key = _issue_key($it, $kind);
    return 0 unless delete $self->_open_keys($kind)->{$key};
    eval { $self->_issues->resolve_key($key, $action, resolution => { by => 'healer', action => $action, result => $result }) };
    return 1;
}

sub _watch_save ($self, $it, $w) {
    my $reg = $self->_reg;
    $w = { %$w, rules => RULES } if defined $w;    # this rule set's own episode: resumable
    if ($it->{kind} eq 'vm') {
        my $c = $reg->active_cluster;
        my $rec = $reg->cluster_get_json($c, "workload_$it->{workload}");
        return unless ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH' && ref $rec->{vms}{ $it->{vm} } eq 'HASH';
        if (defined $w) { $rec->{vms}{ $it->{vm} }{boot_watch} = $w } else { delete $rec->{vms}{ $it->{vm} }{boot_watch} }
        $reg->cluster_set($c, "workload_$it->{workload}", $rec);
    }
    elsif (defined $w) { $reg->host_set($it->{mac}, 'boot_watch', $w) }
    else { $reg->host_unset($it->{mac}, 'boot_watch') }
    return;
}

# The start stamp the record holds now (after our reset), or undef.
sub _stamp_now ($self, $it) {
    my $reg = $self->_reg;
    if ($it->{kind} eq 'vm') {
        my $rec = eval { $reg->cluster_get_json($reg->active_cluster, "workload_$it->{workload}") };
        return ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH' && ref $rec->{vms}{ $it->{vm} } eq 'HASH' ? $rec->{vms}{ $it->{vm} }{started_at} : undef;
    }
    return eval { $reg->host_get($it->{mac}, 'bmc_power_on_at') };
}

# _reset($item): the reset itself. A VM: stop --force then start, the paths hps-workload
# uses (the record's state and started_at follow). Metal: BMC reset, else power on.
# Returns undef on success, else the error text.
sub _reset ($self, $it) {
    if ($it->{kind} eq 'vm') {
        my $wl = $self->_wl;
        eval { $wl->run('stop', $it->{workload}, vm => $it->{vm}, force => 1); 1 } or return 'stop --force failed: ' . _msg($@);
        eval { $wl->run('start', $it->{workload}, vm => $it->{vm}); 1 } or return 'start failed: ' . _msg($@);
        return undef;
    }
    my $r = eval { $self->_bmc->run($it->{mac}, 'reset') };
    return 'BMC reset failed: ' . _msg($@) unless $r;
    if ($r->{rc} != 0) {
        $r = eval { $self->_bmc->run($it->{mac}, 'on') };
        return 'BMC reset and power on failed: ' . ($r ? "exit $r->{rc}" : _msg($@)) unless $r && $r->{rc} == 0;
    }
    return undef;
}

sub _blind ($self, $it, $reason) {
    $self->_event_every("blind:$it->{key}", HPS::Event::REMIND, 'warning', $it->{subject}, 'unreadable', $reason);
    $self->_open($it, 'boot-watch-blind', "boot watch cannot judge $it->{subject}: $reason", $reason);
    return;
}

sub _give_up ($self, $it, $reason, $tries) {
    my $hint = _console_hint($it);
    my $what = $it->{kind} eq 'vm' ? "workload $it->{workload} VM $it->{vm}" : "node $it->{host}";
    my $rec = $self->_open($it, 'boot-stalled', "$what did not reach iPXE: $tries reset(s) tried; see the console: $hint",
        "$reason; console: $hint", urgent_after => 3600);
    $self->_event('warning', $it->{subject}, 'gave-up', "boot-stalled, $tries reset(s) tried, issue $rec->{id}; console: $hint");
    $self->{said}{"gaveup:$it->{key}"} = $self->_now;
    return;
}

# handle($item, $settings, $ready_cb): decide and act on one item; returns the verdict.
sub handle ($self, $it, $s, $ready_cb) {
    if (defined $it->{report}) {
        $self->_blind($it, $it->{report});
        return { state => 'unreadable', action => 'report', reason => $it->{report} };
    }
    my $v = $self->verdict_for($it, $s, $ready_cb);
    my $w = $it->{watch} // {};
    my $same = defined $w->{expect} && defined $it->{stamp} && $w->{expect} eq $it->{stamp};
    my $tries = $same ? ($w->{tries} // 0) : 0;
    my $a = $v->{action};
    if ($v->{state} ne 'unreadable'
        && $self->_close($it, 'boot-watch-blind', 'readable again', "$it->{subject}: $v->{state}")) {
        $self->_event('notice', $it->{subject}, 'ok', "readable again; $v->{state}");
    }
    if ($a eq 'report') {
        $self->_blind($it, $v->{reason});
    }
    elsif ($v->{state} eq 'booted') {
        my $closed = $self->_close($it, 'boot-stalled', "netboot seen after $tries reset(s)", $v->{reason});
        if ($a eq 'resolve' || $closed) {
            $self->_event('notice', $it->{subject}, 'booted', "netboot seen again after $tries reset(s); $v->{reason}");
            $self->_watch_save($it, undef) if $same;
        }
    }
    elsif ($a eq 'defer') {
        $self->_event_every("defer:$it->{key}", 300, 'warning', $it->{subject}, 'boot-stalled', $v->{reason});
        # Remembered, so that a later boot is logged as booted and closes the line above.
        $self->_watch_save($it, { %{ $same ? $w : {} }, tries => $tries, expect => $it->{stamp}, stalled => 1 })
            unless $same && $w->{stalled};
    }
    elsif ($a eq 'reset') {
        my $n = $tries + 1;
        $self->_event('warning', $it->{subject}, 'boot-stalled', "$v->{reason}; reset $n of $s->{max}");
        my $err = $self->_reset($it);
        my $new = { tries => $n, last_try_at => $self->_now, expect => ($self->_stamp_now($it) // $it->{stamp}) };
        if (defined $err) {
            $self->_event('warning', $it->{subject}, 'reset-failed', $err);
            $new->{gave_up} = 1;
            $self->_watch_save($it, $new);
            $self->_give_up($it, "reset $n failed: $err; $v->{reason}", $n);
        }
        else {
            $self->_watch_save($it, $new);
            $self->_event('notice', $it->{subject}, 'reset', "reset $n of $s->{max} done; watching for the next $s->{window} s");
        }
    }
    elsif ($a eq 'give_up' && !($same && $w->{gave_up})) {
        $self->_watch_save($it, { %{ $same ? $w : {} }, tries => $tries, expect => $it->{stamp}, gave_up => 1 });
        $self->_give_up($it, $v->{reason}, $tries);
    }
    elsif ($a eq 'give_up') {
        # Gave up on an earlier tick: the standing line is repeated, as docs/LOGGING.md asks.
        $self->_event_every("gaveup:$it->{key}", HPS::Event::REMIND, 'warning', $it->{subject}, 'gave-up',
            "boot-stalled, $tries reset(s) tried; console: " . _console_hint($it));
    }
    return $v;
}

#=== clean-up: state and issues that outlived their cause ================================

# _clear_item($item, $why): removes the boot_watch state of a node and resolves its open
# boot-stalled and boot-watch-blind issues; when it removed anything, logs the clearing
# event (kind boot, state cleared) so that a standing boot line in hps-log attention ends
# with its cause. Returns true when it did something; nothing to remove: no line.
sub _clear_item ($self, $it, $why) {
    my $did = 0;
    if ($it->{clear_state} || (ref $it->{watch} eq 'HASH' && %{ $it->{watch} })) {
        $did = 1 if eval { $self->_watch_save($it, undef); 1 };
    }
    for my $kind (qw(boot-stalled boot-watch-blind)) {
        $did = 1 if $self->_close($it, $kind, 'boot watch state cleared', $why);
    }
    $self->_event('notice', $it->{subject}, 'cleared', "$why; its boot-watch state and issues are removed") if $did;
    return $did;
}

# _stand_down($now): the watch is off. The leftovers of an earlier run (boot_watch state in
# a workload record or host, and the open issues of kind boot-stalled, boot-watch-blind and
# boot-watch-many) are removed, each with a cleared line, so that nothing keeps saying a node
# is stalled for a watch that no longer runs. Looked for every STAND_DOWN_EVERY seconds.
# Returns the number of nodes and issues cleared.
sub _stand_down ($self, $now) {
    return 0 if $now < $self->{next_standdown};
    $self->{next_standdown} = $now + STAND_DOWN_EVERY;
    my $reg = $self->_reg;
    my $c = eval { $reg->active_cluster } // return 0;
    my $why = 'the boot watch is off (boot_stall_window_seconds is 0)';
    my ($n, %said) = (0);
    $self->{open} = {};
    for my $key (sort eval { $reg->cluster_list($c) }) {
        my ($name) = $key =~ /\Aworkload_([a-z][a-z0-9-]{0,31})\z/ or next;
        my $rec = eval { $reg->cluster_get_json($c, $key) };
        next unless ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH';
        for my $vm (sort keys %{ $rec->{vms} }) {
            my $rv = $rec->{vms}{$vm};
            next unless ref $rv eq 'HASH' && ref $rv->{boot_watch} eq 'HASH';
            my $it = { kind => 'vm', workload => $name, vm => $vm, subject => "$name/$vm", watch => $rv->{boot_watch} };
            if (eval { $self->_clear_item($it, $why) }) { $n++; $said{ $it->{subject} } = 1 }
        }
    }
    for my $mac (sort eval { $reg->host_list_all }) {
        next unless eval { $reg->host_exists($mac, 'boot_watch') };
        my $name = eval { $reg->fqdn($mac) } // $mac;
        my $w = eval { $reg->host_get_json($mac, 'boot_watch') };
        my $it = { kind => 'metal', mac => $mac, host => $name, subject => $name, watch => (ref $w eq 'HASH' && %$w ? $w : { rules => 0 }) };
        if (eval { $self->_clear_item($it, $why) }) { $n++; $said{$name} = 1 }
    }
    # Issues that have no state behind them (a blind report, the breaker's issue).
    for my $i (eval { $self->_issues->list }) {
        next unless $i->{state} ne 'resolved' && ($i->{kind} // '') =~ /\Aboot-(?:stalled|watch-blind|watch-many)\z/;
        my $f = ref $i->{fields} eq 'HASH' ? $i->{fields} : {};
        my $subject = defined $f->{workload} ? "$f->{workload}/" . (($f->{vm} // 'any') eq 'any' ? '*' : $f->{vm}) : defined $f->{host} ? $f->{host} : 'watch';
        eval { $self->_issues->resolve_key($i->{key}, 'boot watch off', resolution => { by => 'healer', action => 'boot watch off', result => $why }); 1 } or next;
        $n++;
        $self->_event('notice', $subject, 'cleared', "$why; issue $i->{id} resolved") unless $said{$subject}++;
    }
    return $n;
}

#=== the breaker ===============================================================================

# _breaker_open($names, $limit): more than $limit distinct nodes look stalled in this scan:
# one standing event and one issue, no reset of any of them.
sub _breaker_open ($self, $names, $limit) {
    my @n = sort @$names;
    my $list = join(', ', @n > 10 ? (@n[ 0 .. 9 ], '...') : @n);
    my $text = scalar(@n) . " nodes look stalled at once (limit $limit): more likely a fault in the watch or the boot service than in the nodes; none was reset ($list)";
    $self->_event_every('breaker', HPS::Event::REMIND, 'warning', 'watch', 'tripped', "many nodes look stalled at once: $text");
    my $key = HPS::Issues::make_key('boot-watch-many', { scope => 'cluster' }, 'scope');
    return if $self->_open_keys('boot-watch-many')->{$key};
    eval {
        $self->_issues->open_issue(kind => 'boot-watch-many', fields => { scope => 'cluster' }, key_fields => ['scope'], severity => 'warning',
            summary => "many nodes look stalled at once: more likely a fault in the watch or the boot service than in the nodes ($list)",
            detail => $text, by => 'hps-bootwatch', urgent_after => 3600);
        $self->_open_keys('boot-watch-many')->{$key} = 1;
    };
    return;
}

# _breaker_clear(): the scan no longer has too many stalled nodes: the issue resolves.
sub _breaker_clear ($self) {
    my $key = HPS::Issues::make_key('boot-watch-many', { scope => 'cluster' }, 'scope');
    return unless delete $self->_open_keys('boot-watch-many')->{$key};
    eval { $self->_issues->resolve_key($key, 'healer', resolution => { by => 'healer', action => 'boot watch', result => 'no longer many nodes stalled at once' }) };
    delete $self->{said}{breaker};
    $self->_event('notice', 'watch', 'cleared', 'no longer many nodes stalled at once');
    return;
}

# _counts_as_stalled($item, $verdict): a node newly judged stalled in this scan. One that
# already gave up (its issue stands) is not new.
sub _counts_as_stalled ($it, $v) {
    return 0 unless $v->{state} eq 'boot-stalled';
    my $w = $it->{watch} // {};
    my $same = defined $w->{expect} && defined $it->{stamp} && $w->{expect} eq $it->{stamp};
    return $v->{action} eq 'give_up' && $same && $w->{gave_up} ? 0 : 1;
}

#=== the tick ===================================================================================

# tick(): one rate-limited scan. Returns the number of items acted on (reset, give up,
# resolve, report, clear), 0 when it was not time or the watch is off.
#   * the settings are read at the start and again before every item that may act, so a
#     window set to 0 stops the scan at the next item, not at the end of the pass;
#   * at most one reset per scan, then it returns to the caller's loop (the other watcher
#     work and a changed key are seen before the next one, SCAN_EVERY seconds on);
#   * the breaker: more than boot_stall_max_nodes distinct nodes newly judged stalled in
#     this scan and none is reset or given up on; one issue says so.
sub tick ($self) {
    my $now = $self->_now;
    return 0 if $now < $self->{next_scan};
    $self->{next_scan} = $now + SCAN_EVERY;
    my $s = $self->settings;
    $self->_event_every("setting:$_", 3600, 'warning', 'settings', 'bad-setting', $_) for @{ $s->{warnings} // [] };
    if (!$s->{window}) {
        $self->{enabled_at} = undef;
        return $self->_stand_down($now);
    }
    $self->{enabled_at} //= $now;
    $self->{next_standdown} = 0;
    $self->{open} = {};
    my @items = eval { $self->items };
    if ($@) { $self->_event_every('scan', 600, 'warning', 'scan', 'failed', 'cannot read the registry: ' . _msg($@)); return 0 }
    my ($asked, $ready);
    my $cb = sub {
        if (!$asked++) {
            my $r = $self->{ready}->();
            $ready = $r eq 'ready' ? 1 : $r eq 'not_ready' ? 0 : undef;
        }
        return $ready;
    };
    my $n = 0;
    my @live;
    for my $it (@items) {
        if ($it->{recovered}) {
            $n++ if eval { $self->_close($it, 'boot-watch-blind', 'readable again', "$it->{subject}: readable") && do { $self->_event('notice', $it->{subject}, 'ok', 'readable again'); 1 } };
            next;
        }
        if (defined $it->{clear_why}) {
            my $did = eval { $self->_clear_item($it, $it->{clear_why}) };
            $n++ if $did;
            if ($@) { $self->_event_every("err:$it->{key}", 600, 'warning', $it->{subject}, 'failed', 'boot watch failed: ' . _msg($@)) }
        }
        next if ($it->{scope} // '') eq 'out';
        push @live, $it;
    }
    # The first pass only judges: how many nodes look stalled right now.
    my %stalled;
    for my $it (@live) {
        next if defined $it->{report};
        my $v = eval { $self->verdict_for($it, $s, $cb) } or next;
        $stalled{ $it->{subject} } = 1 if _counts_as_stalled($it, $v);
    }
    my $limit = $s->{nodes} // DEFAULT_NODES;
    my $tripped = keys %stalled > $limit;
    if ($tripped) { $self->_breaker_open([ keys %stalled ], $limit) }
    else          { $self->_breaker_clear }
    for my $it (@live) {
        next if $tripped && $stalled{ $it->{subject} };
        my $now_s = $self->settings;
        if (!$now_s->{window}) {    # switched off while the scan ran: stop here, touch nothing more
            $self->{enabled_at} = undef;
            last;
        }
        my $v = eval { $self->handle($it, $now_s, $cb) };
        if ($@) { $self->_event_every("err:$it->{key}", 600, 'warning', $it->{subject}, 'failed', 'boot watch failed: ' . _msg($@)); next }
        $n++ if $v->{action} =~ /\A(?:reset|give_up|resolve|report)\z/;
        last if $v->{action} eq 'reset';    # one reset per scan
    }
    return $n;
}

# annotate_status($class, $wl, $name, $out): for hps-workload status, a netboot_note on
# each VM of the status result that boots from the network and is recorded running.
sub annotate_status ($class, $wl, $name, $out, %o) {
    my $def = eval { $wl->load($name) } or return;
    my $self = $class->new(registry => $wl->{registry}, now => $o{now});
    my %nb = map { $_ => 1 } netboot_vms($def, undef, $self->_layout);
    my $rec = $wl->record($name) // return;
    for my $v (@{ $out->{vms} // [] }) {
        next unless $nb{ $v->{vm} } && ($v->{recorded_state} // '') eq 'running';
        my $rv = $rec->{vms}{ $v->{vm} } // next;
        my $since = parse_stamp($rv->{started_at});
        if (!defined $since) { $v->{netboot_note} = status_note('unreadable', 0, 'no usable start time on record'); next }
        my ($s, $d) = $self->vm_netboot($rv, $since, $self->_now);
        my $note = status_note($s, $self->_now - $since, $d);
        $v->{netboot_note} = $note if defined $note;
    }
    return;
}

1;
