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
# Never reset: a VM whose recorded state is not running (stopped on purpose,
# suspended, creating, failed...); a node without a start time on record; a
# node whose record or last_boot_at cannot be read (that is its own reported
# case, issue kind boot-watch-blind, never "fine" and never a reset); a node
# while this IPS's boot services do not answer (the try is not spent).
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
use HPS::Issues ();
use HPS::Registry ();

use constant DEFAULT_WINDOW => 180;
use constant MIN_WINDOW     => 30;
use constant MAX_WINDOW     => 86400;
use constant DEFAULT_RESETS => 3;
use constant MAX_RESETS     => 20;
use constant SCAN_EVERY     => 15;
# The start stamp is written when vm-start returns, a little after the guest
# began to boot; a netboot this much before the stamp still counts as ours.
use constant SLACK          => 60;
use constant FUTURE         => 300;

#=== settings (pure) =====================================================================

# window($raw): (seconds, warning). 0 disables the watch; else 30..86400.
sub window ($raw) {
    my ($v, $w) = HPS::BootReady::int_setting($raw, DEFAULT_WINDOW, 0, MAX_WINDOW, 'boot_stall_window_seconds');
    return ($v, $w) if !$v || $v >= MIN_WINDOW;
    return (DEFAULT_WINDOW, "boot_stall_window_seconds='$raw' is not 0 or " . MIN_WINDOW . '..' . MAX_WINDOW . '; using ' . DEFAULT_WINDOW);
}

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
#   may_reset (false: report only, never act on the node).
# state:  disabled, not-watched, unreadable, booted, booting, boot-stalled
# action: none, report (unreadable: report it, touch nothing), resolve (booted after
#         an episode), reset, defer (the IPS is deaf: try later, no try spent), give_up (open the issue)
sub decide (%f) {
    return { state => 'disabled', action => 'none', reason => 'boot_stall_window_seconds is 0' } unless $f{window};
    my $rec = $f{recorded} // '';
    return { state => 'not-watched', action => 'none', reason => "recorded state is '$rec', not running" } unless $rec eq 'running';
    return { state => 'unreadable', action => 'report', reason => 'no usable start time on record' } unless defined $f{since};
    return { state => 'unreadable', action => 'report', reason => $f{netboot_detail} // 'netboot state unreadable' }
        if ($f{netboot} // 'unreadable') eq 'unreadable';
    if ($f{netboot} eq 'seen') {
        return { state => 'booted', action => ($f{tries} || $f{gave_up} ? 'resolve' : 'none'), reason => $f{netboot_detail} // 'netboot seen' };
    }
    my $from = defined $f{last_try} && $f{last_try} > $f{since} ? $f{last_try} : $f{since};
    my $elapsed = $f{now} - $from;
    return { state => 'booting', action => 'none', reason => "no netboot seen since start ($elapsed s of $f{window})" } if $elapsed < $f{window};
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

# netboot_vms($def, $only_vm): names of the VMs of a validated definition that boot
# from the network (the one named only, when given).
sub netboot_vms ($def, $only = undef) {
    return map { $_->{name} } grep { ($_->{boot} // 'disk') eq 'network' && (!defined $only || $_->{name} eq $only) } @{ $def->{vms} // [] };
}

#=== the facts from the registry =========================================================

sub new ($class, %o) {
    my $reg = $o{registry} // HPS::Registry->new;
    return bless {
        registry => $reg,
        issues   => $o{issues},                    # HPS::Issues, made on first use
        workload => $o{workload},                  # HPS::Workload, made on first use
        bmc      => $o{bmc},                       # HPS::BMC, made on first use
        ready    => $o{ready} // sub { HPS::BootReady::check(registry => $reg)->{verdict} },
        now      => $o{now} // sub { time },
        logger   => $o{logger} // \&_default_logger,
        settings => $o{settings},                  # tests: {window, max, metal}; else the cluster keys
        next_scan => 0, blind => undef, said => {},
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

# _event($level, $subject, $state, $text): the one place an event line is made.
# Written for the log split (HPS::Event): subject=<workload/vm or host> state=<state>.
sub _event ($self, $level, $subject, $state, $text) {
    $self->{logger}->($level, "kind=boot subject=$subject state=$state $text");
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

# settings(): {window, max, metal, warnings}, read afresh (the keys may change).
sub settings ($self) {
    return $self->{settings} if $self->{settings};
    my ($w, $ww) = window($self->_setting('boot_stall_window_seconds'));
    my ($m, $mw) = max_resets($self->_setting('boot_stall_max_resets'));
    my ($t, $tw) = metal_reset($self->_setting('boot_stall_metal_reset'));
    return { window => $w, max => $m, metal => $t, warnings => [ grep { defined } $ww, $mw, $tw ] };
}

# last_boot($mac): (raw last_boot_at or undef when none recorded, error text or undef).
sub _last_boot ($self, $mac) {
    my $reg = $self->_reg;
    my $m = eval { $reg->resolve_mac($mac) } // return (undef, "not a MAC: $mac");
    my $v = eval { $reg->host_exists($m, 'last_boot_at') ? $reg->host_get($m, 'last_boot_at') : undef };
    return (undef, "host $m unreadable: " . ($@ =~ s/\s+\z//r)) if $@;
    return ($v, undef);
}

# vm_netboot($rv, $since, $now): (state, detail) over every MAC of the VM's record:
# seen when any of them netbooted; unreadable when none did and any cannot be read.
sub vm_netboot ($self, $rv, $since, $now) {
    my @macs = ref $rv->{macs} eq 'ARRAY' ? grep { defined && !ref } @{ $rv->{macs} } : ();
    return ('unreadable', 'the record has no MAC for the VM') unless @macs;
    my ($best, @bad, $seen_detail) = ('not_seen');
    for my $mac (@macs) {
        my ($raw, $err) = $self->_last_boot($mac);
        if (defined $err) { push @bad, $err; next }
        my ($s, $d) = netboot_state($raw, $since, $now);
        if ($s eq 'seen') { return ($s, "$mac: $d") }
        push @bad, "$mac: $d" if $s eq 'unreadable';
    }
    return ('unreadable', join('; ', @bad)) if @bad;
    return ('not_seen', 'no iPXE init recorded after the start');
}

#=== the scan ============================================================================

# items(): one {kind, key, subject, ...facts, report?} per watched VM and metal node.
sub items ($self) {
    my @out;
    my $reg = $self->_reg;
    my $c = eval { $reg->active_cluster } // return ();
    my $now = $self->_now;
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
        for my $vm (netboot_vms($def)) {
            my $rv = ref $rec->{vms} eq 'HASH' ? $rec->{vms}{$vm} : undef;
            my $it = { kind => 'vm', workload => $name, vm => $vm, subject => "$name/$vm", key => "$name/$vm" };
            if (ref $rv ne 'HASH') {
                $it->{report} = "workload record $key has no entry for VM $vm";
                $it->{key} = "blind:$name/$vm";
                push @out, $it;
                next;
            }
            $it->{recorded} = $rv->{state};
            $it->{stamp} = $rv->{started_at};
            $it->{since} = parse_stamp($rv->{started_at});
            $it->{watch} = ref $rv->{boot_watch} eq 'HASH' ? $rv->{boot_watch} : {};
            if (($rv->{state} // '') eq 'running' && defined $it->{since}) {
                @$it{qw(netboot netboot_detail)} = $self->vm_netboot($rv, $it->{since}, $now);
            }
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
        if (defined $it->{since}) {
            my ($raw, $err) = $self->_last_boot($mac);
            @$it{qw(netboot netboot_detail)} = defined $err ? ('unreadable', $err) : netboot_state($raw, $it->{since}, $now);
        }
        push @out, $it;
    }
    return @out;
}

# verdict_for($item, $settings, $ready_cb): decide() over an item's facts. The
# boot-services check ($ready_cb: 1, 0 or undef) runs only when a reset is due.
sub verdict_for ($self, $it, $s, $ready_cb) {
    my $w = $it->{watch} // {};
    my $same = defined $w->{expect} && defined $it->{stamp} && $w->{expect} eq $it->{stamp};
    my %f = (
        window => $s->{window}, max => $s->{max}, now => $self->_now,
        tries => ($same ? ($w->{tries} // 0) : 0), gave_up => ($same ? $w->{gave_up} : 0), last_try => ($same ? $w->{last_try_at} : undef),
        since => $it->{since}, recorded => $it->{recorded}, netboot => $it->{netboot}, netboot_detail => $it->{netboot_detail},
        may_reset => ($it->{kind} eq 'metal' ? $s->{metal} : $s->{max} > 0 ? 1 : 0),
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
    $self->_event_every("blind:$it->{key}", 3600, 'warning', $it->{subject}, 'unreadable', $reason);
    $self->_open($it, 'boot-watch-blind', "boot watch cannot judge $it->{subject}: $reason", $reason);
    return;
}

sub _give_up ($self, $it, $reason, $tries) {
    my $hint = _console_hint($it);
    my $what = $it->{kind} eq 'vm' ? "workload $it->{workload} VM $it->{vm}" : "node $it->{host}";
    my $rec = $self->_open($it, 'boot-stalled', "$what did not reach iPXE: $tries reset(s) tried; see the console: $hint",
        "$reason; console: $hint", urgent_after => 3600);
    $self->_event('warning', $it->{subject}, 'gave-up', "boot-stalled, $tries reset(s) tried, issue $rec->{id}; console: $hint");
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
    if ($v->{state} ne 'unreadable') { $self->_close($it, 'boot-watch-blind', 'readable again', "$it->{subject}: $v->{state}") }
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
    return $v;
}

# tick(): one rate-limited pass. Returns the number of items acted on (reset, give up,
# resolve, report), 0 when it was not time or the watch is off.
sub tick ($self) {
    my $now = $self->_now;
    return 0 if $now < $self->{next_scan};
    $self->{next_scan} = $now + SCAN_EVERY;
    my $s = $self->settings;
    $self->_event_every("setting:$_", 3600, 'warning', 'settings', 'bad-setting', $_) for @{ $s->{warnings} // [] };
    return 0 unless $s->{window};
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
    for my $it (@items) {
        my $v = eval { $self->handle($it, $s, $cb) };
        if ($@) { $self->_event_every("err:$it->{key}", 600, 'warning', $it->{subject}, 'failed', 'boot watch failed: ' . _msg($@)); next }
        $n++ if $v->{action} =~ /\A(?:reset|give_up|resolve|report)\z/;
    }
    return $n;
}

# annotate_status($class, $wl, $name, $out): for hps-workload status, a netboot_note on
# each VM of the status result that boots from the network and is recorded running.
sub annotate_status ($class, $wl, $name, $out, %o) {
    my $def = eval { $wl->load($name) } or return;
    my %nb = map { $_ => 1 } netboot_vms($def);
    my $self = $class->new(registry => $wl->{registry}, now => $o{now});
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
