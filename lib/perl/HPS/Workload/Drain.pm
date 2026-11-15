package HPS::Workload::Drain;
# hps-workload drain <host> and undrain <host>: empty a compute host before a
# planned reboot and bring its guests back afterwards (plans/upgradability.md,
# items U1 and U2; docs/WORKLOADS.md "Drain and undrain").
#
# drain marks the host not placeable (host key `drain`; HPS::Workload create,
# start and resume refuse a host that carries it), then handles each guest the
# workload records say is running there, lowest class first:
#   class 4            stop (clean, never forced)
#   class 3            suspend
#   class 1 and 2      suspend for now; live migration is not built
# A guest that is itself a cluster node or infrastructure (one of its MACs is a
# registered host, or it boots from the network) is never suspended: drain
# refuses while one runs on the host, or with include_nodes stops them cleanly
# after every other guest.
#
# The host key `drain` is both the mark and the record of what drain did:
#   {state, started_at, finished_at, by, guests: [{workload, vm, class, action,
#    node, seq, result, at, error}]}
# result: attempting (written before the node call), done, left (the action
# failed; the guest still runs). undrain reverses the `done` entries only
# (resume what was suspended, start what was stopped; nodes first, then class 1
# to 4), drops each entry it reversed and removes the key when none is left, so
# a guest that was stopped or suspended before the drain is left as it was and
# a partly failed undrain can be run again.
#
# Every function takes an HPS::Workload object ($wl) for its registry, clock,
# logger and node calls. Nothing here calls a node itself: the guest actions
# are HPS::Workload's own stop, suspend, start and resume.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::Registry;
use HPS::Keysafe;
use HPS::Workload::List ();
use HPS::Event ();

# Outcome => exit status of the verb. 3 is the tool's "refused"; 5 is drain's
# own: guests are left (drain: still running, the host is not ready for reboot;
# undrain: not brought back). Nothing to do is 0: the host is marked and ready.
our %EXIT = (drained => 0, 'guests-left' => 5, 'nothing-to-do' => 0, refused => 3,
    undrained => 0, 'not-drained' => 0, incomplete => 5, plan => 0);

my %ACTION  = (4 => 'stop', 3 => 'suspend', 2 => 'suspend', 1 => 'suspend');
my %REVERSE = (stop => 'start', suspend => 'resume');
my %TARGET  = (stop => 'stopped', suspend => 'suspended');
my %KNOWN   = map { $_ => 1 } qw(creating defined running stopped suspended);

sub _fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

sub _msg ($e) {
    my $m = ref $e && $e->can('message') ? $e->message : "$e";
    $m =~ s/\s+\z//;
    return $m;
}

# The host's display name: its registry HOSTNAME, else what the caller typed.
sub _label ($wl, $mac, $host) {
    my $reg = $wl->{registry};
    return $reg->host_exists($mac, 'HOSTNAME') ? $reg->host_get($mac, 'HOSTNAME') : $host;
}

# record($wl, $mac): the host's drain record, undef when the host is not marked.
# A key that is there and cannot be read is refused: it is never "not drained".
sub record ($wl, $mac) {
    my $reg = $wl->{registry};
    return undef unless $reg->host_exists($mac, 'drain');
    my $d = eval { $reg->host_get_json($mac, 'drain') };
    _fail('refused', "host key drain of $mac cannot be read as a drain record (an object with a guests list); "
        . 'look at it with hps-registry and put it right, or remove it, before drain or undrain')
        unless ref $d eq 'HASH' && ref $d->{guests} eq 'ARRAY' && !grep { ref $_ ne 'HASH' } @{ $d->{guests} };
    return $d;
}

# Why a recorded VM counts as a node or infrastructure, else undef.
sub _node_reason ($reg, $idx, $rv) {
    for my $raw (@{ ref $rv->{macs} eq 'ARRAY' ? $rv->{macs} : [] }) {
        next unless defined $raw && !ref $raw;
        my $m = eval { HPS::Registry::normalise_mac($raw) } // next;
        my $h = $idx->{$m} // next;
        return 'registered host ' . ($reg->host_exists($h, 'HOSTNAME') ? $reg->host_get($h, 'HOSTNAME') : $h);
    }
    my @d = ref $rv->{define} eq 'ARRAY' ? @{ $rv->{define} } : ();
    for my $i (0 .. $#d - 1) {
        return 'network-boot VM (a node or infrastructure)' if $d[$i] eq '--boot' && $d[ $i + 1 ] eq 'network';
    }
    return undef;
}

# The memory of a recorded VM in MiB: the --memory of its recorded vm-define
# arguments, else the definition's, else undef.
sub _memory ($rv, $dvm) {
    my @d = ref $rv->{define} eq 'ARRAY' ? @{ $rv->{define} } : ();
    for my $i (0 .. $#d - 1) {
        return $d[ $i + 1 ] + 0 if $d[$i] eq '--memory' && $d[ $i + 1 ] =~ /^[0-9]+\z/;
    }
    return $dvm ? $dvm->{memory_mib} : undef;
}

# survey($wl, $mac): what the workload records say about the host:
#   running  the guests recorded as running on it: [{workload, vm, class,
#            memory_mib, node, order, def_error}]
#   idle     the guests on it that are not running (left as they are)
#   problems why the answer cannot be trusted: a record that cannot be read, a
#            VM with no host or an unknown state, a running VM on a host the
#            registry does not know, a class that is not 1 to 4. With any
#            problem drain refuses: an unreadable record is never "nothing
#            running".
sub survey ($wl, $mac) {
    my $reg = $wl->{registry};
    my $idx = $reg->mac_index;
    my (@running, @idle, @problems, %host_mac);
    for my $name (sort(HPS::Workload::List::names($wl))) {
        my $rec = eval { $wl->record($name) };
        my $err = $@;
        unless (ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH') {
            push @problems, "workload $name: its record (cluster key workload_$name) "
                . ($err ? 'cannot be read: ' . _msg($err) : !defined $rec ? 'is missing' : 'has no vms object');
            next;
        }
        my $class = HPS::Workload::class_of($rec);
        my ($def, %order, %dvm, $def_error);
        my $loaded = 0;
        for my $vm (sort keys %{ $rec->{vms} }) {
            my $rv = $rec->{vms}{$vm};
            unless (ref $rv eq 'HASH' && defined $rv->{host} && !ref $rv->{host} && length $rv->{host}) {
                push @problems, "workload $name VM $vm: its record names no compute host";
                next;
            }
            my $state = defined $rv->{state} && !ref $rv->{state} ? $rv->{state} : undef;
            my $h = $rv->{host};
            $host_mac{$h} = eval { $wl->_mac($h) } unless exists $host_mac{$h};
            if (!defined $host_mac{$h}) {
                push @problems, "workload $name VM $vm: recorded as running on '$h', which is not a host of the registry"
                    if defined $state && $state eq 'running' && !$rec->{destroy_pending};
                next;
            }
            next unless $host_mac{$h} eq $mac;
            if ($rec->{destroy_pending}) {
                push @idle, { workload => $name, vm => $vm, state => 'partly destroyed' };
                next;
            }
            unless (defined $state && $KNOWN{$state}) {
                push @problems, "workload $name VM $vm: its recorded state " . (defined $state ? "'$state'" : '(none)') . ' is not one drain knows';
                next;
            }
            if ($state ne 'running') {
                push @idle, { workload => $name, vm => $vm, state => $state };
                next;
            }
            unless (defined $class) {
                push @problems, "workload $name: its recorded class is not 1 to 4 (hps-workload set-class $name <1-4>)";
                next;
            }
            unless ($loaded++) {
                # The definition gives the stop order inside the workload. Without
                # it the guest stays in the plan; its action then fails and says why.
                $def = eval { $wl->load($name) };
                $def_error = _msg($@) unless $def;
                if ($def) {
                    my $i = 0;
                    $order{ $_->{name} } = $i++ for reverse $wl->_ordered($def);
                    $dvm{ $_->{name} } = $_ for @{ $def->{vms} };
                }
            }
            push @running, { workload => $name, vm => $vm, class => $class, memory_mib => _memory($rv, $dvm{$vm}),
                node => _node_reason($reg, $idx, $rv), order => $order{$vm} // 0,
                (defined $def_error ? (def_error => $def_error) : ()) };
        }
    }
    return { running => \@running, idle => \@idle, problems => \@problems };
}

# plan(\@running): the guests in the order drain handles them, each with its
# action: ordinary guests class 4 first, then the nodes (stopped, last). Inside
# a class by workload name, inside a workload in its stop order.
sub plan ($running) {
    my @sorted = sort {
        ($a->{node} ? 1 : 0) <=> ($b->{node} ? 1 : 0) || $b->{class} <=> $a->{class}
            || $a->{workload} cmp $b->{workload} || $a->{order} <=> $b->{order} || $a->{vm} cmp $b->{vm}
    } @$running;
    my @out;
    for my $g (@sorted) {
        my $action = $g->{node} ? 'stop' : $ACTION{ $g->{class} };
        my $note = $g->{node} ? "$g->{node}: never suspended; stopped cleanly after the other guests"
            : $g->{class} <= 2 ? "class $g->{class}: would be live-migrated when migration exists; suspending" : undef;
        # vm-save needs free space of the guest's memory; the file is about that size.
        my $bytes = $action eq 'suspend' && defined $g->{memory_mib} ? $g->{memory_mib} * 1048576 : undef;
        push @out, { workload => $g->{workload}, vm => $g->{vm}, class => $g->{class}, action => $action,
            node => ($g->{node} ? 1 : 0), (defined $g->{node} ? (node_reason => $g->{node}) : ()),
            memory_mib => $g->{memory_mib}, state_file_bytes_estimate => $bytes,
            (defined $note ? (note => $note) : ()), (defined $g->{def_error} ? (def_error => $g->{def_error}) : ()) };
    }
    return \@out;
}

sub _entry ($rec, $g) {
    my ($e) = grep { $_->{workload} eq $g->{workload} && $_->{vm} eq $g->{vm} } @{ $rec->{guests} };
    return $e;
}

sub _vm_state ($wl, $workload, $vm) {
    my $wrec = $wl->record($workload);
    return (0, undef) unless ref $wrec eq 'HASH';
    my $rv = ref $wrec->{vms} eq 'HASH' ? $wrec->{vms}{$vm} : undef;
    return (1, ref $rv eq 'HASH' && defined $rv->{state} && !ref $rv->{state} ? $rv->{state} : undef);
}

# An entry still `attempting` belongs to a drain that died between its node
# call and its record. The workload record settles it: in the state the action
# leads to, drain did it (done); else it did not happen and the entry goes.
sub _settle ($wl, $rec) {
    my @keep;
    for my $e (@{ $rec->{guests} }) {
        if (($e->{result} // '') eq 'attempting') {
            my (undef, $state) = eval { _vm_state($wl, $e->{workload}, $e->{vm}) };
            next unless defined $state && $state eq ($TARGET{ $e->{action} // '' } // '');
            $e->{result} = 'done';
        }
        push @keep, $e;
    }
    $rec->{guests} = \@keep;
    return;
}

# _ev($wl, $kind, $pri, $subject, $state, $text): one event line (HPS::Event,
# docs/LOGGING.md) through the workload driver's logger. A drain or undrain of a
# host is kind node, subject the host; what happens to one guest is kind
# workload, subject the workload. The terminal text is the text alone.
sub _ev ($wl, $kind, $pri, $subject, $state, $text) {
    HPS::Event::log_event(sub ($l, $m) { $wl->_log($l, $m) }, pri => $pri, kind => $kind, subject => $subject, state => $state, text => $text);
    return;
}

sub _refused ($wl, $out, $why, %more) {
    _ev($wl, 'node', 'notice', $out->{host}, 'refused', "$out->{op} $out->{host} refused: $why");
    return { %$out, outcome => 'refused', exit => $EXIT{refused}, reason => $why, %more };
}

# drain($wl, $host, dry_run => 0|1, include_nodes => 0|1): returns {op, host,
# mac, key, outcome, exit, ready_for_reboot, guests, still_running, idle} and
# for a refusal {outcome => 'refused', reason, problems|nodes}. Dies (not found)
# only for a host the registry does not know. outcome: drained, guests-left,
# nothing-to-do, refused; with dry_run: plan, nothing-to-do, refused.
sub drain ($wl, $host, %a) {
    my $mac = $wl->_mac($host);
    my $reg = $wl->{registry};
    my $label = _label($wl, $mac, $host);
    my $out = { op => 'drain', host => $label, mac => $mac, key => 'drain', dry_run => ($a{dry_run} ? 1 : 0) };
    my $rec = eval { record($wl, $mac) };
    return _refused($wl, $out, _msg($@)) if $@;
    my $s = survey($wl, $mac);
    return _refused($wl, $out, "the workload records do not say for certain what runs on $label, so nothing is changed: "
        . join('; ', @{ $s->{problems} }), problems => $s->{problems}) if @{ $s->{problems} };
    my $plan = plan($s->{running});
    my @nodes = grep { $_->{node} } @$plan;
    if (@nodes && !$a{include_nodes}) {
        return _refused($wl, $out, scalar(@nodes) . " guest(s) running on $label are cluster nodes or infrastructure: "
            . join(', ', map {"$_->{workload}/$_->{vm} ($_->{node_reason})"} @nodes)
            . '. A node VM is never suspended. Stop them yourself first, or give --include-nodes to have drain stop them cleanly after the other guests. Nothing is changed',
            nodes => [ map { +{ workload => $_->{workload}, vm => $_->{vm}, class => $_->{class}, reason => $_->{node_reason} } } @nodes ]);
    }
    $out->{idle} = $s->{idle};
    $out->{already_marked} = $rec ? 1 : 0;
    if ($a{dry_run}) {
        my $outcome = @$plan ? 'plan' : 'nothing-to-do';
        return { %$out, outcome => $outcome, exit => $EXIT{$outcome}, guests => $plan, still_running => [],
            ready_for_reboot => (@$plan ? 0 : 1) };
    }

    $rec //= { started_at => $wl->_stamp, by => $wl->{by}, guests => [] };
    _settle($wl, $rec);
    # A guest an earlier drain left running is in this plan again if it still
    # runs; if it does not, someone else stopped it and it is not drain's to undo.
    $rec->{guests} = [ grep { ($_->{result} // '') ne 'left' } @{ $rec->{guests} } ];
    $rec->{state} = 'draining';
    delete $rec->{finished_at};
    $reg->host_set($mac, 'drain', $rec);
    _ev($wl, 'node', 'notice', $label, 'started', "drain $label: host marked not placeable (host key drain) by $wl->{by}; " . scalar(@$plan) . ' guest(s) to handle');
    my $seq = 0;
    for my $e (@{ $rec->{guests} }) { $seq = $e->{seq} if ($e->{seq} // 0) > $seq }
    my @results;
    for my $g (@$plan) {
        my $what = "$g->{action} of $g->{workload}/$g->{vm} (class $g->{class})";
        _ev($wl, 'workload', 'notice', $g->{workload}, 'requested', "drain $label: $g->{note}") if defined $g->{note};
        my $e = _entry($rec, $g);
        if (!$e) {
            $e = { workload => $g->{workload}, vm => $g->{vm} };
            push @{ $rec->{guests} }, $e;
        }
        delete $e->{error};
        @$e{qw(class action node seq result at)} = ($g->{class}, $g->{action}, $g->{node}, ++$seq, 'attempting', $wl->_stamp);
        $reg->host_set($mac, 'drain', $rec);
        my $ok = eval { $wl->run($g->{action}, $g->{workload}, vm => $g->{vm}); 1 };
        my $err = $ok ? undef : _msg($@);
        if ($ok) {
            $e->{result} = 'done';
            _ev($wl, 'workload', 'info', $g->{workload}, 'done', "drain $label: $what ok");
        }
        else {
            @$e{qw(result error)} = ('left', $err);
            _ev($wl, 'workload', 'warning', $g->{workload}, 'failed', "drain $label: $what failed; the guest is left running: $err");
        }
        $e->{at} = $wl->_stamp;
        $reg->host_set($mac, 'drain', $rec);
        push @results, { %$g, result => $e->{result}, (defined $err ? (error => $err) : ()) };
    }
    my @left = grep { $_->{result} eq 'left' } @results;
    $rec->{state} = @left ? 'guests-left' : 'drained';
    $rec->{finished_at} = $wl->_stamp;
    $reg->host_set($mac, 'drain', $rec);
    my $outcome = !@$plan ? 'nothing-to-do' : @left ? 'guests-left' : 'drained';
    _ev($wl, 'node', (@left ? 'warning' : 'notice'), $label, (@left ? 'failed' : 'done'), "drain $label: " . (
        !@$plan ? 'nothing to do, no guest is running on it; ready for reboot'
        : @left ? 'NOT ready for reboot, ' . scalar(@left) . ' guest(s) still running: ' . join(', ', map {"$_->{workload}/$_->{vm}"} @left)
        : scalar(@results) . ' guest(s) handled; ready for reboot'));
    return { %$out, outcome => $outcome, exit => $EXIT{$outcome}, guests => \@results,
        still_running => [ map { +{ workload => $_->{workload}, vm => $_->{vm}, class => $_->{class}, error => $_->{error} } } @left ],
        ready_for_reboot => (@left ? 0 : 1) };
}

# undrain($wl, $host, dry_run => 0|1): reverse what drain did and clear the
# mark. Returns {op, host, mac, key, outcome, exit, guests, failed}. outcome:
# undrained, not-drained (exit 0, nothing changed), incomplete (the record
# keeps the guests that could not be brought back; run it again), refused;
# with dry_run: plan, not-drained.
sub undrain ($wl, $host, %a) {
    my $mac = $wl->_mac($host);
    my $reg = $wl->{registry};
    my $label = _label($wl, $mac, $host);
    my $out = { op => 'undrain', host => $label, mac => $mac, key => 'drain', dry_run => ($a{dry_run} ? 1 : 0) };
    my $rec = eval { record($wl, $mac) };
    return _refused($wl, $out, _msg($@)) if $@;
    unless ($rec) {
        _ev($wl, 'node', 'info', $label, 'done', "undrain $label: the host is not drained (no host key drain); nothing to do") unless $a{dry_run};
        return { %$out, outcome => 'not-drained', exit => $EXIT{'not-drained'}, guests => [], failed => [] };
    }
    _settle($wl, $rec);
    # Nodes first (drain stopped them last), then class 1 to 4; inside a
    # workload the reverse of the order drain took them in.
    my @todo = sort {
        ($b->{node} ? 1 : 0) <=> ($a->{node} ? 1 : 0) || ($a->{class} // 9) <=> ($b->{class} // 9)
            || $a->{workload} cmp $b->{workload} || ($b->{seq} // 0) <=> ($a->{seq} // 0)
    } grep { ($_->{result} // '') eq 'done' && $REVERSE{ $_->{action} // '' } } @{ $rec->{guests} };
    my @rows = map { +{ workload => $_->{workload}, vm => $_->{vm}, class => $_->{class}, node => ($_->{node} ? 1 : 0),
        was => $_->{action}, action => $REVERSE{ $_->{action} } } } @todo;
    if ($a{dry_run}) {
        return { %$out, outcome => 'plan', exit => $EXIT{plan}, guests => \@rows, failed => [] };
    }
    _ev($wl, 'node', 'notice', $label, 'started', "undrain $label: by $wl->{by}; " . scalar(@todo) . ' guest(s) to bring back');
    my (@failed, @results);
    for my $i (0 .. $#todo) {
        my ($e, $row) = ($todo[$i], $rows[$i]);
        my $what = "$row->{action} of $e->{workload}/$e->{vm} (class " . ($e->{class} // '?') . ')';
        my ($exists, $state) = eval { _vm_state($wl, $e->{workload}, $e->{vm}) };
        my $err = $@ ? 'its workload record cannot be read: ' . _msg($@) : undef;
        if (!defined $err && !$exists) {
            _ev($wl, 'workload', 'notice', $e->{workload}, 'done', "undrain $label: $what skipped: the workload no longer exists");
            push @results, { %$row, result => 'skipped', note => 'the workload no longer exists' };
            next;
        }
        if (!defined $err && ($state // '') ne $TARGET{ $e->{action} }) {
            my $now = $state // 'unknown';
            _ev($wl, 'workload', 'notice', $e->{workload}, 'done', "undrain $label: $what skipped: the guest is now $now, not $TARGET{ $e->{action} } as drain left it");
            push @results, { %$row, result => 'skipped', note => "now $now, not $TARGET{ $e->{action} } as drain left it; left as it is" };
            next;
        }
        if (!defined $err) {
            eval { $wl->run($row->{action}, $e->{workload}, vm => $e->{vm}, undrain => 1); 1 } or $err = _msg($@);
        }
        if (defined $err) {
            $e->{undo_error} = $err;
            $e->{at} = $wl->_stamp;
            push @failed, $e;
            _ev($wl, 'workload', 'warning', $e->{workload}, 'failed', "undrain $label: $what failed; kept in the drain record: $err");
            push @results, { %$row, result => 'failed', error => $err };
            next;
        }
        _ev($wl, 'workload', 'info', $e->{workload}, 'done', "undrain $label: $what ok");
        push @results, { %$row, result => 'done' };
    }
    if (@failed) {
        $rec->{guests} = \@failed;
        $rec->{state} = 'undrain-incomplete';
        $rec->{finished_at} = $wl->_stamp;
        $reg->host_set($mac, 'drain', $rec);
        _ev($wl, 'node', 'warning', $label, 'failed', "undrain $label: incomplete, " . scalar(@failed) . ' guest(s) not brought back: '
            . join(', ', map {"$_->{workload}/$_->{vm}"} @failed) . '; the host stays marked (host key drain), run undrain again');
        return { %$out, outcome => 'incomplete', exit => $EXIT{incomplete}, guests => \@results,
            failed => [ map { +{ workload => $_->{workload}, vm => $_->{vm}, class => $_->{class}, error => $_->{undo_error} } } @failed ] };
    }
    $reg->host_unset($mac, 'drain');
    _ev($wl, 'node', 'notice', $label, 'done', "undrain $label: mark cleared (host key drain removed); the host is placeable again");
    return { %$out, outcome => 'undrained', exit => $EXIT{undrained}, guests => \@results, failed => [] };
}

#--- text --------------------------------------------------------------------------

sub _mib ($bytes) { return defined $bytes ? int($bytes / 1048576) . ' MiB' : '-' }

sub _guest_line ($g) {
    my $out = sprintf("  %-28s class %s  %-8s memory %-10s state file %s%s\n", "$g->{workload}/$g->{vm}", $g->{class} // '?',
        $g->{action}, (defined $g->{memory_mib} ? "$g->{memory_mib} MiB" : '-'),
        (defined $g->{state_file_bytes_estimate} ? 'about ' . _mib($g->{state_file_bytes_estimate}) : '-'),
        (defined $g->{result} ? ($g->{result} eq 'done' ? '  ok' : '  FAILED, left running') : ''));
    $out .= "    $g->{note}\n" if defined $g->{note};
    $out .= "    the definition cannot be loaded, so the action will fail: $g->{def_error}\n" if defined $g->{def_error} && !defined $g->{result};
    $out .= "    $g->{error}\n" if defined $g->{error};
    return $out;
}

# render($r): the text form of a drain or undrain result.
sub render ($r) {
    my ($h, $o) = ($r->{host}, $r->{outcome});
    return '' if $o eq 'refused';    # the caller prints the reason on stderr
    my $out = '';
    if ($r->{op} eq 'drain') {
        $out .= "Drain $h" . ($r->{dry_run} ? ' (dry run: the plan, nothing is sent or changed)' : '') . ":\n";
        $out .= _guest_line($_) for @{ $r->{guests} };
        $out .= "  (no guest is running on $h)\n" unless @{ $r->{guests} };
        $out .= "  left as it is: $_->{workload}/$_->{vm} ($_->{state})\n" for @{ $r->{idle} // [] };
        if ($r->{dry_run}) {
            $out .= $o eq 'plan' ? "drain would mark $h not placeable (host key drain) and handle " . scalar(@{ $r->{guests} }) . " guest(s) in this order\n"
                : "nothing to do: drain would only mark $h not placeable (host key drain)\n";
        }
        elsif ($o eq 'drained') {
            $out .= "drain ok: $h is drained and ready for reboot; it is marked not placeable (host key drain) until hps-workload undrain $h\n";
        }
        elsif ($o eq 'nothing-to-do') {
            $out .= "drain: nothing to do, no guest is running on $h; it is marked not placeable (host key drain) and ready for reboot; hps-workload undrain $h clears the mark\n";
        }
        else {
            $out .= "drain INCOMPLETE: $h is NOT ready for reboot; still running: "
                . join(', ', map {"$_->{workload}/$_->{vm}"} @{ $r->{still_running} })
                . ". Put right what stopped them and run drain $h again, or undrain $h to bring back what was handled\n";
        }
        return $out;
    }
    return "undrain: $h is not drained (no host key drain); nothing to do\n" if $o eq 'not-drained';
    $out .= "Undrain $h" . ($r->{dry_run} ? ' (dry run: the plan, nothing is sent or changed)' : '') . ":\n";
    for my $g (@{ $r->{guests} }) {
        $out .= sprintf("  %-28s class %s  %-8s%s\n", "$g->{workload}/$g->{vm}", $g->{class} // '?', $g->{action},
            (!defined $g->{result} ? " (drain did: $g->{was})" : $g->{result} eq 'done' ? '  ok' : $g->{result} eq 'skipped' ? '  skipped' : '  FAILED'));
        $out .= "    $g->{note}\n" if defined $g->{note};
        $out .= "    $g->{error}\n" if defined $g->{error};
    }
    $out .= "  (drain handled no guest)\n" unless @{ $r->{guests} };
    $out .= $o eq 'plan' ? "undrain would bring these back in this order and clear the mark (host key drain)\n"
        : $o eq 'undrained' ? "undrain ok: $h is placeable again (host key drain removed)\n"
        : "undrain INCOMPLETE: not brought back: " . join(', ', map {"$_->{workload}/$_->{vm}"} @{ $r->{failed} })
            . ". $h stays marked (host key drain) with these in its record; put them right and run undrain $h again\n";
    return $out;
}

1;
