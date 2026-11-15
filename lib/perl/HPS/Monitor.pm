package HPS::Monitor;
# Resource monitor (docs/MONITORING.md): turns the answer of the node script
# nagios-check (ctrl-exec agent plugin, JSON) into log lines, and holds the pure
# rules of hps-monitor: the interval key, the tick schedule, the target list.
# The IPS names the checks (--all) and decides when; the node's checks.conf
# decides how. No I/O to syslog here: hps-monitor writes what this returns.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use POSIX ();
use HPS::Event ();
use HPS::Registry;

use constant DEFAULT_INTERVAL => 60;
use constant MIN_INTERVAL     => 10;
use constant MAX_INTERVAL     => 86400;

my %RANK = (OK => 0, UNKNOWN => 1, WARNING => 2, CRITICAL => 3);
my %PRIO = (OK => 'info', WARNING => 'warning', CRITICAL => 'err', UNKNOWN => 'err', UNREACHABLE => 'err');

sub priority ($state) { return $PRIO{$state} // 'err' }

# interval($raw): (seconds, warning). $raw is the stored value (undef = unset).
# 0 disables; 10..86400 is used; unset gives the default silently; anything else
# gives the default and a warning text.
sub interval ($raw) {
    return (DEFAULT_INTERVAL, undef) unless defined $raw && length $raw;
    my $v = $raw;
    $v =~ s/\A\s+|\s+\z//g;
    return (0, undef) if $v =~ /\A0+\z/;
    return ($v + 0, undef) if $v =~ /\A[1-9][0-9]*\z/ && $v >= MIN_INTERVAL && $v <= MAX_INTERVAL;
    return (DEFAULT_INTERVAL, "monitor_interval_seconds='$raw' is not 0 or " . MIN_INTERVAL . '..' . MAX_INTERVAL . '; using ' . DEFAULT_INTERVAL);
}

# missed_ticks($elapsed, $interval): how many whole ticks a run of $elapsed
# seconds overran (0 when it finished inside its own interval).
sub missed_ticks ($elapsed, $interval) {
    return 0 if $elapsed < $interval;
    return int($elapsed / $interval);
}

sub _one_line ($text, $max = 200) {
    my $t = $text // '';
    $t =~ s/[\x00-\x1f\x7f]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return length($t) > $max ? substr($t, 0, $max) : $t;
}

# perf_text(\@perfdata): "label=value[unit] ..." (thresholds left out).
sub perf_text ($perf) {
    my @out;
    for my $p (@{ $perf // [] }) {
        next unless ref $p eq 'HASH' && defined $p->{label};
        (my $label = $p->{label}) =~ s/\s+/_/g;
        next unless defined $p->{value};
        push @out, $label . '=' . $p->{value} . ($p->{uom} // '');
    }
    return join ' ', @out;
}

# parse_reply($rc, $text): the answer of `hps-run.sh --json <host> nagios-check
# --all` (ctrl-exec-cli JSON: {ok, results:[{exit, stdout, stderr, error}]}, the
# stdout being the nagios-check document). Returns { checks => [...] } or
# { unreachable => reason }.
sub parse_reply ($rc, $text, $err = '') {
    my $why = sub ($m) { return { unreachable => _one_line($m) } };
    if ($rc != 0) {
        my $e = _one_line($err);
        return $why->($rc == 124 ? 'timed out' : length $e ? "hps-run exit $rc: $e" : "hps-run exit $rc");
    }
    my $d = eval { JSON::PP::decode_json($text // '') };
    return $why->('no readable reply from ctrl-exec-cli') unless ref $d eq 'HASH';
    return $why->($d->{error} // 'ctrl-exec-cli reported failure') unless $d->{ok};
    my $r = ref $d->{results} eq 'ARRAY' ? $d->{results}[0] : undef;
    return $why->('no result for the host') unless ref $r eq 'HASH';
    my $w = eval { JSON::PP::decode_json($r->{stdout} // '') };
    unless (ref $w eq 'HASH' && ref $w->{checks} eq 'ARRAY') {
        return $why->((ref $w eq 'HASH' && $w->{error}) || $r->{error} || $r->{stderr}
                      || 'exit ' . ($r->{exit} // '?') . ': no readable nagios-check reply');
    }
    my @checks;
    for my $c (@{ $w->{checks} }) {
        next unless ref $c eq 'HASH' && defined $c->{name};
        my $s = $c->{state} // '';
        $s = 'UNKNOWN' unless exists $RANK{$s};
        push @checks, { name => $c->{name}, state => $s, summary => _one_line($c->{summary}),
                        perf => perf_text($c->{perfdata}), pcts => _fill_pcts($c->{perfdata}) };
    }
    return { checks => \@checks };
}

#--- persistent filesystems (disk_*, zpool_cap) -------------------------------------
# The node grades its own disk checks at 80/90 (hps-monitor.nix); the IPS grades
# the same figures again with the cluster keys monitor_disk_warn_pct and
# monitor_disk_crit_pct, so a threshold change needs no new image. The same
# thresholds grade the IPS's own resources and log filesystems.

use constant DISK_WARN => 80;
use constant DISK_CRIT => 90;

my $FILL_LABEL = qr/(?:\A|_)(?:used_pct|inode_pct|cap)\z/;

# _fill_pcts(\@perfdata): the fill percentages of a disk check (labels
# used_pct, inode_pct, <pool>_cap, any prefix; unit %).
sub _fill_pcts ($perf) {
    my @p;
    for my $x (@{ $perf // [] }) {
        next unless ref $x eq 'HASH' && defined $x->{label} && defined $x->{value};
        push @p, $x->{value} + 0 if $x->{label} =~ $FILL_LABEL && ($x->{uom} // '') eq '%';
    }
    return \@p;
}

sub is_disk_check ($name) { return $name =~ /\Adisk_/ && $name ne 'disk_root' || $name eq 'zpool_cap' }

# disk_thresholds($warn, $crit): (warn, crit, warning text). Each is the stored
# key (undef when unset: the default silently); a value that is not 1..100, or
# a warn not below crit, gives the defaults and a warning.
sub disk_thresholds ($w, $c) {
    my $ok = sub ($v) { defined $v && $v =~ /\A(?:[1-9][0-9]?|100)\z/ };
    my @bad;
    push @bad, "monitor_disk_warn_pct='$w'" if defined $w && length $w && !$ok->($w);
    push @bad, "monitor_disk_crit_pct='$c'" if defined $c && length $c && !$ok->($c);
    my $wv = $ok->($w) ? $w + 0 : DISK_WARN;
    my $cv = $ok->($c) ? $c + 0 : DISK_CRIT;
    if (!@bad && $wv >= $cv) { push @bad, "monitor_disk_warn_pct=$wv is not below monitor_disk_crit_pct=$cv" }
    return (DISK_WARN, DISK_CRIT, join('; ', @bad) . '; using ' . DISK_WARN . ' and ' . DISK_CRIT) if @bad;
    return ($wv, $cv, undef);
}

sub grade_pct ($pct, $warn, $crit) {
    return 'CRITICAL' if $pct >= $crit;
    return 'WARNING'  if $pct >= $warn;
    return 'OK';
}

# regrade($parsed, $warn, $crit): the node's disk checks graded with the IPS's
# thresholds (in place). A check the node could not measure (UNKNOWN, or no fill
# figures: not mounted) keeps its state. A changed state is also put in the
# summary's state word and noted.
sub regrade ($parsed, $warn, $crit) {
    for my $c (@{ $parsed->{checks} // [] }) {
        next unless is_disk_check($c->{name}) && $c->{state} ne 'UNKNOWN' && @{ $c->{pcts} // [] };
        my $s = 'OK';
        for my $p (@{ $c->{pcts} }) {
            my $g = grade_pct($p, $warn, $crit);
            $s = $g if $RANK{$g} > $RANK{$s};
        }
        next if $s eq $c->{state};
        $c->{summary} =~ s/\A(\S+) \Q$c->{state}\E\b/$1 $s/;
        $c->{summary} .= " (graded at warn $warn% crit $crit%)";
        $c->{state} = $s;
    }
    return $parsed;
}

# parse_df($df, $dfi): {size, used, avail, pct, ipct, mount} from the text of
# `df -P -B1 <path>` and `df -P -i <path>`; undef when it is not readable.
# ipct is undef where the filesystem has no fixed inode count ("-").
sub parse_df ($df, $dfi = '') {
    my @l = grep { length } split /\n/, $df // '';
    my @f = split ' ', $l[-1] // '';
    return undef unless @l >= 2 && @f >= 6 && $f[1] =~ /\A\d+\z/ && $f[2] =~ /\A\d+\z/ && $f[3] =~ /\A\d+\z/;
    my ($size, $used, $avail) = @f[1 .. 3];
    my $den = $used + $avail;
    my $pct = $den > 0 ? int(($used * 100 + $den - 1) / $den) : 0;
    my $ipct;
    my @i = grep { length } split /\n/, $dfi // '';
    my @g = split ' ', $i[-1] // '';
    if (@i >= 2 && @g >= 6 && $g[1] =~ /\A\d+\z/ && $g[1] > 0 && $g[2] =~ /\A\d+\z/) {
        $ipct = int(($g[2] * 100 + $g[1] - 1) / $g[1]);
    }
    return { size => $size + 0, used => $used + 0, avail => $avail + 0, pct => $pct, ipct => $ipct, mount => $f[-1] };
}

sub _human ($b) {
    return sprintf('%.1f TiB', $b / 1024**4) if $b >= 1024**4;
    return sprintf('%.1f GiB', $b / 1024**3) if $b >= 1024**3;
    return sprintf('%.1f MiB', $b / 1024**2);
}

# fs_check($name, $path, $fs, $warn, $crit): one check result in the form of
# parse_reply's, for the IPS's own filesystems. $fs from parse_df, or undef
# with $why saying what failed.
sub fs_check ($name, $path, $fs, $warn, $crit, $why = 'df failed') {
    return { name => $name, state => 'UNKNOWN', summary => "DISK UNKNOWN - $path: " . _one_line($why), perf => '', pcts => [] }
        unless $fs;
    my $s = grade_pct($fs->{pct}, $warn, $crit);
    if (defined $fs->{ipct}) {
        my $g = grade_pct($fs->{ipct}, $warn, $crit);
        $s = $g if $RANK{$g} > $RANK{$s};
    }
    my $sum = sprintf('DISK %s - %s %d%% used (%s of %s)', $s, $path, $fs->{pct}, _human($fs->{used}), _human($fs->{size}));
    $sum .= ", inodes $fs->{ipct}%" if defined $fs->{ipct};
    $sum .= " on $fs->{mount}" if $fs->{mount} ne $path;
    my $perf = "used_pct=$fs->{pct}%";
    $perf .= " inode_pct=$fs->{ipct}%" if defined $fs->{ipct};
    $perf .= " used=$fs->{used}B size=$fs->{size}B";
    return { name => $name, state => $s, summary => $sum, perf => $perf,
             pcts => [ $fs->{pct}, defined $fs->{ipct} ? $fs->{ipct} : () ] };
}

#--- event lines (docs/LOGGING.md) ---------------------------------------------------------
# The host-state lines (UNREACHABLE, REACHABLE, PAIR_FAILED, STOPPED) carry the
# marker so events.log holds them; the line itself stays as the readers
# (HPS::Metrics) parse it, after the marker. A check that is not OK is an event
# when its state changes and again every HPS::Event::REMIND seconds while it
# holds; OK after a bad state is the clearing line.

my %MARK = (
    UNREACHABLE => [ 'warning', 'unreachable' ],
    REACHABLE   => [ 'notice',  'reachable' ],
    PAIR_FAILED => [ 'urgent',  'pair-failed' ],
    STOPPED     => [ 'info',    'stopped' ],
);

# mark([level, line]): the pair with the marker in front of a host-state line,
# at the syslog level of its priority; any other pair unchanged.
sub mark ($pair) {
    my ($level, $line) = @$pair;
    my ($host, $st) = $line =~ /\Ahps-monitor: host=(\S+) state=(UNREACHABLE|REACHABLE|PAIR_FAILED|STOPPED)\b/ or return $pair;
    my ($pri, $state) = @{ $MARK{$st} };
    return [ HPS::Event::syslog_level($pri),
        HPS::Event::line(pri => $pri, kind => 'monitor', subject => $host, state => $state, text => $line) ];
}

my %CHECK_EVENT = (WARNING => [ 'warning', 'warning' ], CRITICAL => [ 'urgent', 'critical' ], UNKNOWN => [ 'warning', 'unknown' ]);

# check_events($memo, $now, @pairs): the extra event lines ([level, line]) for the
# check lines of @pairs ("hps-monitor: host=<h> check=<c> state=<S> <text>").
# $memo (the loop's hash; undef in a one-off run, which logs every bad state)
# remembers each check's last state and when it was last logged.
sub check_events ($memo, $now, @pairs) {
    my $m = $memo ? ($memo->{_check} //= {}) : {};
    my @out;
    for my $p (@pairs) {
        my ($host, $name, $state, $text) = $p->[1] =~ /\Ahps-monitor: host=(\S+) check=(\S+) state=([A-Z]+) ?(.*)\z/s or next;
        $text =~ s/ \| .*\z//s;
        $text = substr($text, 0, 157) . '...' if length $text > 160;
        my $key = "$host/$name";
        my $prev = $m->{$key};
        if ($state eq 'OK') {
            next unless $prev;
            delete $m->{$key};
            push @out, _event('notice', $key, 'ok', "hps-monitor: $name on $host is OK again: $text");
            next;
        }
        my $c = $CHECK_EVENT{$state} or next;
        next if $prev && $prev->{state} eq $state && $now - $prev->{at} < HPS::Event::REMIND;
        $m->{$key} = { state => $state, at => $now };
        push @out, _event($c->[0], $key, $c->[1], "hps-monitor: $name on $host is $state: $text");
    }
    return @out;
}

sub _event ($pri, $subject, $state, $text) {
    return [ HPS::Event::syslog_level($pri),
        HPS::Event::line(pri => $pri, kind => 'monitor', subject => $subject, state => $state, text => $text) ];
}

# service_event($state, $text, $pri): the monitor's own line (started, stopped,
# failed, ok = alive) as an event of kind service.
sub service_event ($state, $text, $pri = 'info') {
    return [ HPS::Event::syslog_level($pri),
        HPS::Event::line(pri => $pri, kind => 'service', subject => 'hps-monitor', state => $state, text => "hps-monitor: $text") ];
}

# heartbeat($memo, $now, $interval): "alive" every HPS::Event::REMIND seconds,
# so a quiet cluster still has event lines in the last hour (hps-log
# attention reads silence as "cannot tell"); () between.
sub heartbeat ($memo, $now, $interval) {
    return () unless HPS::Event::remind_due($memo, '_heartbeat', $now);
    return (service_event('ok', $interval ? "alive interval=${interval}s" : 'alive, checks off'));
}

# host_lines($host, $parsed, $duration): list of [priority, line] for one host.
sub host_lines ($host, $parsed, $duration) {
    my $dur = sprintf '%.1f', $duration;
    if (defined $parsed->{unreachable}) {
        return ([ priority('UNREACHABLE'), "hps-monitor: host=$host state=UNREACHABLE $parsed->{unreachable}" ]);
    }
    my @out;
    my $worst = 'OK';
    for my $c (@{ $parsed->{checks} }) {
        my $line = "hps-monitor: host=$host check=$c->{name} state=$c->{state} $c->{summary}";
        $line .= " | $c->{perf}" if length $c->{perf};
        push @out, [ priority($c->{state}), $line ];
        $worst = $c->{state} if $RANK{ $c->{state} } > $RANK{$worst};
    }
    my $n = @{ $parsed->{checks} };
    $worst = 'UNKNOWN' if $n == 0;
    push @out, [ priority($worst), "hps-monitor: host=$host checks=$n worst=$worst duration=$dur" ];
    return @out;
}

# throttle($memo, $host, $lines, $now, $every): the lines of one host's result
# that the loop logs. An unreachable host (a node powered off or booting) is
# logged when it becomes unreachable and then once every $every seconds (600
# by default), not on every tick; the first result after that logs
# "state=REACHABLE after <n>s" before its check lines. $memo is the loop's
# hash, kept across ticks. Other results pass through unchanged.
sub throttle ($memo, $host, $lines, $now, $every = 600) {
    my $unreach = @$lines == 1 && $lines->[0][1] =~ /\shost=\S+ state=UNREACHABLE /;
    my $m = $memo->{$host};
    if ($unreach) {
        if ($m && $m->{since} && $now - ($m->{logged} // 0) < $every) { return () }
        $memo->{$host} = { since => ($m && $m->{since}) ? $m->{since} : $now, logged => $now, tried => (($m && $m->{tried}) // $now) };
        return @$lines;
    }
    if ($m && $m->{since}) {
        delete $memo->{$host};
        return ([ 'info', sprintf('hps-monitor: host=%s state=REACHABLE after %ds unreachable', $host, $now - $m->{since}) ], @$lines);
    }
    return @$lines;
}

# skip_call($memo, $host, $now, $boot_at, $retry): true when the loop should
# not call an unreachable host this tick. A host unreachable since an earlier
# tick is called again every $retry seconds (300 by default); at once when
# the IPS has seen it netboot since the last call (registry last_boot_at,
# set at every iPXE init); and every 60 s within 15 minutes of that netboot,
# while the node comes up. Each call to a powered-off node makes ctrl-exec
# log an error of its own (lab 2026-11-11: one every 30 s while the DL360
# booted).
sub skip_call ($memo, $host, $now, $boot_at = undef, $retry = 300) {
    my $m = $memo->{$host} or return 0;
    return 0 unless $m->{since};
    my $tried = $m->{tried} // 0;
    return 0 if defined $boot_at && $boot_at > $tried;
    # within 15 minutes of a netboot the node is coming up: retry every 60 s
    my $every = (defined $boot_at && $now - $boot_at < 900) ? 60 : $retry;
    return $now - $tried < $every ? 1 : 0;
}

# pair_failed_lines($reg, $now, $memo, $every): the hosts the IPS gave up
# pairing (registry pair_failed_at, set by the pairing approver after the last
# allowed reboot): one err line each, "hps-monitor: host=<name> state=PAIR_FAILED
# since=<UTC time> reboots=<n>". Such a node is not paired, so it is never a
# check target; this line is how it shows. With a memo (the loop) a host is
# logged when first seen and then once every $every seconds (600 by default).
sub pair_failed_lines ($reg, $now, $memo = undef, $every = 600) {
    my @out;
    for my $mac (sort $reg->host_list_all) {
        my $at = eval { $reg->host_get($mac, 'pair_failed_at') };
        next unless defined $at && $at =~ /\A\d+\z/;
        if ($memo) {
            my $m = $memo->{"pair_failed:$mac"};
            next if defined $m && $now - $m < $every;
            $memo->{"pair_failed:$mac"} = $now;
        }
        my $name = eval { $reg->fqdn($mac) } // eval { $reg->host_get($mac, 'HOSTNAME') } // $mac;
        my $n = eval { $reg->host_get($mac, 'pair_reboots') } // 0;
        my $since = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($at));
        push @out, [ 'err', "hps-monitor: host=$name state=PAIR_FAILED since=$since reboots=$n"
            . ' the node missed its pairing window after every allowed reboot; fix the cause and reboot it' ];
    }
    return @out;
}

#--- nodes stopped on purpose (a node that is a workload VM) ------------------------
# A node can itself be a VM of a workload (the builder). `hps-workload stop`
# or `suspend` of that workload records the VM's state in the workload record
# (cluster key workload_<name>: vms.<vm>.state, vms.<vm>.macs); the node is
# then stopped, not down: hps-monitor does not call it (each call to a node
# that is off makes ctrl-exec log an error) and logs a STOPPED line instead.

my %STOPPED = (stopped => 1, suspended => 1);

# workload_records($reg): {name => record} of the active cluster's workload
# records. A record that cannot be read or is not an object is left out (its
# VMs are then checked as before); the _destroyed notes are not records.
sub workload_records ($reg) {
    my %out;
    my $c = eval { $reg->active_cluster } // return \%out;
    for my $key (eval { $reg->cluster_list($c) }) {
        my ($name) = $key =~ /\Aworkload_([a-z][a-z0-9-]{0,31})\z/ or next;
        my $rec = eval { $reg->cluster_get_json($c, $key) };
        $out{$name} = $rec if ref $rec eq 'HASH';
    }
    return \%out;
}

# stopped_hosts($reg, $records): {fqdn => {workload, vm, state}}: the registry
# hosts that are a VM of a workload whose record says the VM is stopped or
# suspended. $records: {name => record} (workload_records). A VM's MACs
# (vms.<vm>.macs, as vm-define reported them) are matched to registry hosts
# (resolve_mac: a host key or one of a host's recorded MACs). Only a recorded
# state of stopped or suspended counts: a record that is missing or
# unreadable, a VM with no state, no macs, or a MAC that is no registry host
# with a HOSTNAME gives nothing, and a host that any record names with
# another state (running, creating, ...) is never stopped.
sub stopped_hosts ($reg, $records) {
    my (%out, %live);
    return \%out unless ref $records eq 'HASH';
    for my $name (sort keys %$records) {
        my $rec = $records->{$name};
        next unless ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH';
        for my $vm (sort keys %{ $rec->{vms} }) {
            my $v = $rec->{vms}{$vm};
            next unless ref $v eq 'HASH' && ref $v->{macs} eq 'ARRAY';
            my $state = defined $v->{state} && !ref $v->{state} ? $v->{state} : '';
            for my $raw (@{ $v->{macs} }) {
                next unless defined $raw && !ref $raw;
                my $mac = eval { $reg->resolve_mac($raw) } // next;
                my $f = eval { $reg->fqdn($mac) } // next;
                if ($STOPPED{$state}) { $out{$f} //= { workload => $name, vm => $vm, state => $state } }
                else { $live{$f} = 1 }
            }
        }
    }
    delete @out{ keys %live };
    return \%out;
}

# stopped_lines($stopped, $hosts, $now, $memo, $every): one info line for each
# of @$hosts (the targets) that is in $stopped (stopped_hosts):
# "hps-monitor: host=<fqdn> state=STOPPED workload=<name> vm=<vm> recorded
# state <stopped|suspended>; not checked". With a memo (the loop) a host is
# logged when first seen stopped and then once every $every seconds (600 by
# default); what the memo holds of the host as unreachable is dropped, and a
# host no longer stopped is forgotten, so it is a normal target again and a
# later stop is logged at once.
sub stopped_lines ($stopped, $hosts, $now, $memo = undef, $every = 600) {
    my @out;
    my %is;
    for my $host (@$hosts) {
        my $s = $stopped->{$host} or next;
        next if $is{$host}++;
        if ($memo) {
            delete $memo->{$host};
            my $m = $memo->{"stopped:$host"};
            next if defined $m && $now - $m < $every;
            $memo->{"stopped:$host"} = $now;
        }
        push @out, [ 'info', "hps-monitor: host=$host state=STOPPED workload=$s->{workload} vm=$s->{vm} recorded state $s->{state}; not checked" ];
    }
    if ($memo) {
        delete @{$memo}{ grep { /\Astopped:(.+)\z/ && !$stopped->{$1} } keys %$memo };
    }
    return @out;
}

# targets($agents, $registry): the paired nodes to check: agent names known to
# the dispatcher that are also hosts of the registry (by FQDN). The IPS and
# anything else that is not a registered host is never a target.
sub targets ($agents, $reg) {
    my %agent = map { lc($_) => 1 } grep { defined && length && !/\Astale-/ } @$agents;
    my @out;
    for my $mac (sort $reg->host_list_all) {
        my $f = eval { $reg->fqdn($mac) };
        push @out, $f if defined $f && $agent{$f};
    }
    my %seen;
    return grep { !$seen{$_}++ } sort @out;
}

1;
