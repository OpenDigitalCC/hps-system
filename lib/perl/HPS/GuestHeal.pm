package HPS::GuestHeal;
# The healer's part for guest-paused issues (docs/ISSUES.md "A paused guest",
# docs/STORAGE-FAULTS.md): a guest the hypervisor paused on a disk I/O error is
# resumed by the node script vm-resume once its disks can be read again. Called
# by HPS::IssueHeal (tick, attempt, heal), which owns the schedule, the trail and
# the escalation; this module decides what one attempt does and says what the
# standing state of the guest is in the event lines (kind workload, subject
# <workload>/<vm>, or <host>/<vm> when no workload has the guest: state paused
# until resumed or stopped).
#
# attempt($heal, $rec) returns {outcome, detail, ...} for HPS::IssueHeal::heal:
#   clean       the guest is running (or shut off, or gone): the issue resolves
#   healing     vm-resume succeeded; the state is checked again in CHECK_DELAY, and
#               a guest paused again by then is a failed attempt
#   wait        nothing is done yet and no try is spent: the host is draining, or a
#               mirror-leg or storage-path issue of the host is still being healed
#   unreadable  the state needed to decide cannot be read (a workload record, the
#               drain key): reported, never a resume
#   failed      a try that did not work (the disks are not healthy yet, the node
#               did not answer, the guest paused again); retried by the backoff,
#               and after MAX_TRIES escalated to needs-human by the caller
#   human       a decision for a person: paused by an operator or any other reason
#               than an I/O error, the workload records the VM stopped or
#               suspended, the pause reason cannot be read, the host is unknown
#
# Never resumed here: a guest paused for any reason but ioerror, a guest of a
# workload recorded stopped or suspended, a guest on a host with the key drain,
# and anything whose state cannot be read.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::Event ();
use HPS::Issues ();
use HPS::Registry ();

use constant MAX_TRIES => 6;      # failed tries before the issue needs a human
use constant WAIT_CAP  => 600;    # seconds a guest waits for the host's other issues to heal
use constant WAIT_DELAY => 60;    # seconds between looks while it waits

# parse_status($stdout, $vm): {state, reason} of vm-status's output: the state of
# the last "VM <vm> <state>" line, the reason of "PAUSED <vm> reason=<token>"
# (undef when the node printed none: an older image). undef without a VM line.
sub parse_status ($stdout, $vm) {
    my ($state) = reverse(($stdout // '') =~ /^VM \Q$vm\E (.+?)\s*$/mg);
    return undef unless defined $state;
    my ($reason) = ($stdout // '') =~ /^PAUSED \Q$vm\E reason=([a-z0-9]+)\s*$/m;
    return { state => $state, reason => $reason };
}

# parse_refusal($stdout): (code, detail) of vm-resume's "REFUSED <code> <detail>".
sub parse_refusal ($stdout) {
    my ($code, $detail) = ($stdout // '') =~ /^REFUSED (\S+) (.*?)\s*$/m or return ();
    return ($code, $detail);
}

# find_guest($heal, $mac, $vm): ($found, $error). $found is {workload, state}
# of the workload record that has the VM on that host (undef: no workload has
# it); $error is why the records could not be read (a record that does not
# decode, with no record naming the guest): then nothing may be decided.
sub find_guest ($heal, $mac, $vm) {
    my $reg = $heal->_reg;
    my $c = eval { $reg->active_cluster };
    return (undef, 'no active cluster in the registry') unless defined $c;
    my @keys = eval { $reg->cluster_list($c) };
    return (undef, "the workload records cannot be listed: " . ($@ =~ s/\s+\z//r)) if $@;
    my @bad;
    for my $key (@keys) {
        my ($wl) = $key =~ /\Aworkload_(.+)\z/ or next;
        next if $wl =~ /_destroyed\z/;
        my $rec = eval { $reg->cluster_get_json($c, $key) };
        unless (ref $rec eq 'HASH' && ref $rec->{vms} eq 'HASH') {
            push @bad, $key;
            next;
        }
        my $v = $rec->{vms}{$vm};
        next unless ref $v eq 'HASH';
        my $vmac = $heal->find_host($v->{host} // '');
        next unless defined $vmac && $vmac eq $mac;
        return ({ workload => $wl, state => ($v->{state} // ''), wl_state => ($rec->{state} // '') }, undef);
    }
    return (undef, 'the workload record ' . join(', ', @bad) . ' cannot be read, so it is not known whether it holds this guest') if @bad;
    return (undef, undef);
}

# subject($heal, $rec): the event subject of the guest: <workload>/<vm> when a
# workload record has it on that host (looked up once per issue), else <host>/<vm>.
sub subject ($heal, $rec) {
    my $f = $rec->{fields} // {};
    my $wl = $f->{workload} // $heal->{gp_wl}{ $rec->{id} };
    if (!defined $wl && length($f->{host} // '') && length($f->{guest} // '')) {
        my $mac = $heal->find_host($f->{host});
        my ($g) = defined $mac ? find_guest($heal, $mac, $f->{guest}) : ();
        $wl = $heal->{gp_wl}{ $rec->{id} } = $g->{workload} if $g;
    }
    return HPS::Event::subject_token((defined $wl && length $wl ? $wl : $f->{host} // '-') . '/' . ($f->{guest} // '-'));
}

# blockers($heal, $rec): the unresolved mirror-leg and storage-path issues of the
# same host that are still being healed (open or healing).
sub blockers ($heal, $rec) {
    my $host = HPS::Registry::short_name($rec->{fields}{host} // '');
    return grep {
        $_->{id} ne $rec->{id} && ($_->{kind} eq 'mirror-leg' || $_->{kind} eq 'storage-path')
            && ($_->{state} eq 'open' || $_->{state} eq 'healing')
            && HPS::Registry::short_name(($_->{fields} // {})->{host} // '') eq $host
    } $heal->{issues}->list;
}

# attempt($heal, $rec): one look and, when it is safe, one vm-resume.
sub attempt ($heal, $rec) {
    my $f = $rec->{fields} // {};
    my ($host, $guest) = ($f->{host} // '', $f->{guest} // '');
    return { outcome => 'human', detail => 'the issue names no host and guest' } unless length $host && length $guest;
    my $mac = $heal->find_host($host)
        or return { outcome => 'human', detail => "host '$host' is not in the registry" };
    my %set;

    # What the records say.
    my ($g, $err) = find_guest($heal, $mac, $guest);
    return { outcome => 'unreadable', detail => "cannot tell whether to resume $guest: $err" } if defined $err;
    if ($g) {
        $set{workload} = $g->{workload};
        return { outcome => 'human', set_fields => \%set,
            detail => "workload $g->{workload} records VM $guest $g->{state}: not resumed automatically (a guest meant to be down is never resumed)" }
            if $g->{state} eq 'stopped' || $g->{state} eq 'suspended' || $g->{wl_state} eq 'stopped' || $g->{wl_state} eq 'suspended';
    }
    my $drain = eval { $heal->_reg->host_exists($mac, 'drain') ? 1 : 0 };
    return { outcome => 'unreadable', set_fields => \%set, detail => "cannot read the drain mark of host $host: " . ($@ =~ s/\s+\z//r) }
        unless defined $drain;
    return { outcome => 'wait', set_fields => \%set, detail => "host $host is draining (it carries the drain mark): $guest is not resumed while it drains" }
        if $drain;

    # What the node says now.
    my $s = $heal->_call($mac, 'vm-status', $guest);
    return { outcome => 'clean', set_fields => \%set, by => "vm-status: $guest is not defined on $host",
        detail => "vm-status: $guest is not defined on $host (the node restarted)", stopped => 1 } if $s->{rc} == 4;
    return { outcome => 'failed', set_fields => \%set, detail => "vm-status $guest exit $s->{rc}: " . HPS::IssueHeal::result_line($s) } if $s->{rc} != 0;
    my $st = parse_status($s->{stdout}, $guest)
        or return { outcome => 'failed', set_fields => \%set, detail => "vm-status $guest printed no VM line" };
    my $h = $rec->{heal} // {};
    return { outcome => 'clean', set_fields => \%set, by => "vm-status: $guest running", detail => "vm-status: $guest running",
        result => "vm-status: $guest running" . ($h->{resumed} ? ' after vm-resume' : ' (resumed by someone else or by itself)'),
        mark => { resumed => undef } } if $st->{state} eq 'running';
    return { outcome => 'clean', set_fields => \%set, by => "vm-status: $guest shut off", detail => "vm-status: $guest shut off",
        stopped => 1, mark => { resumed => undef } } if $st->{state} eq 'shut off';
    return { outcome => 'human', set_fields => \%set, detail => "$guest is $st->{state}, not paused: nothing to resume" }
        unless $st->{state} eq 'paused';
    my $reason = $st->{reason};
    return { outcome => 'human', set_fields => \%set,
        detail => "the pause reason of $guest cannot be read (vm-status prints no PAUSED line: a node image older than vm-resume?): not resumed" }
        unless defined $reason;
    $set{reason} = $reason;
    return { outcome => 'human', set_fields => \%set,
        detail => "$guest is paused ($reason), not by an I/O error: a pause an operator made is never resumed automatically; "
            . "hps-workload resume-paused --any-reason does it by hand" }
        unless $reason eq 'ioerror';
    # Resumed by us earlier and paused again: a failed try (the storage is not usable yet).
    return { outcome => 'failed', set_fields => \%set, mark => { resumed => undef },
        detail => "$guest paused again (ioerror) after vm-resume: the storage is not usable yet" } if $h->{resumed};

    # Other issues of the host being healed come first, for a while.
    my @b = blockers($heal, $rec);
    my $age = $heal->_now - HPS::IssueHeal::_epoch($rec->{opened_at});
    return { outcome => 'wait', set_fields => \%set,
        detail => 'waiting for ' . join(', ', map { "$_->{kind} issue $_->{id} ($_->{state})" } @b) . " of $host to heal first" }
        if @b && $age < WAIT_CAP;

    # Resume. The node checks every disk of the guest itself.
    my $r = $heal->_call($mac, 'vm-resume', $guest);
    my $line = HPS::IssueHeal::result_line($r);
    my $d = "vm-resume $guest exit $r->{rc}" . (length $line ? ": $line" : '');
    return { outcome => 'healing', set_fields => \%set, attempted => 1, action => "vm-resume $guest", mark => { resumed => 1 },
        detail => "$d (resumed; checked again later)" } if $r->{rc} == 0;
    if ($r->{rc} == 3) {
        my ($code, $why) = parse_refusal($r->{stdout});
        $code //= 'refused';
        return { outcome => 'human', set_fields => \%set, attempted => 1, detail => "$d (paused by an operator)" } if $code eq 'operator-paused';
        return reassemble($heal, $mac, $guest, \%set, $d) if $code eq 'broken-mirror';
        return { outcome => 'failed', set_fields => \%set, attempted => 1, detail => "$d ($code: " . ($why // $line) . ')' };
    }
    return { outcome => 'clean', set_fields => \%set, by => "vm-resume: $guest is not defined on $host", detail => $d, stopped => 1 } if $r->{rc} == 4;
    return { outcome => 'failed', set_fields => \%set, attempted => 1, detail => $d };
}

# reassemble($heal, $mac, $guest, $set, $detail): vm-resume refused because the kernel
# calls the guest's mirror broken (it fails writes until it is assembled again, and the
# paused guest holds the device open, so a resume cannot fix it; owner ruling 2026-11-16).
# The node script vm-reassemble powers the guest off, assembles the mirror from its
# recorded legs and starts the guest; it checks for itself that both legs are present and
# logged in. Exit 0: running again, checked later like a resume. Exit 3: refused with
# nothing changed (a leg is missing, ...): a failed try, retried by the backoff, the
# reason in the detail. Anything else: the guest may be off with its mirror stopped,
# which no automatic retry can mend: a decision for a person.
sub reassemble ($heal, $mac, $guest, $set, $detail) {
    my $r = $heal->_call($mac, 'vm-reassemble', $guest);
    my $line = HPS::IssueHeal::result_line($r);
    my $d = "$detail; vm-reassemble $guest exit $r->{rc}" . (length $line ? ": $line" : '');
    return { outcome => 'healing', set_fields => $set, attempted => 1, action => "vm-reassemble $guest", mark => { resumed => 1 },
        detail => "$d (the mirror was assembled again and the guest started; checked again later)" } if $r->{rc} == 0;
    if ($r->{rc} == 3) {
        my ($code, $why) = parse_refusal($r->{stdout});
        return { outcome => 'failed', set_fields => $set, attempted => 1, detail => "$d (" . ($code // 'refused') . ': ' . ($why // $line) . ')' };
    }
    return { outcome => 'clean', set_fields => $set, by => "vm-reassemble: $guest is not defined", detail => $d, stopped => 1 } if $r->{rc} == 4;
    return { outcome => 'human', set_fields => $set, attempted => 1,
        detail => "$d (the guest may be powered off with its mirror stopped: hps-workload start assembles and starts it)" };
}

# events($heal): the standing state of each unresolved guest-paused issue as an
# event line, repeated every HPS::Event::REMIND seconds; and "resumed" (or
# "stopped": the guest is shut off or gone) for a guest whose issue resolved
# since. Called every tick; returns the number of lines written.
sub events ($heal) {
    my $issues = $heal->{issues};
    my $now = $heal->_now;
    my $gp = $heal->{gp} //= {};
    my $remind = $heal->{gp_remind} //= {};
    my %live;
    my $n = 0;
    for my $rec ($issues->list) {
        next unless $rec->{kind} eq 'guest-paused';
        $live{ $rec->{id} } = 1;
        my $subject = subject($heal, $rec);
        $gp->{ $rec->{id} } = $subject;
        next unless HPS::Event::remind_due($remind, $rec->{id}, $now);
        my $f = $rec->{fields} // {};
        my $text = "hps-guest-paused: guest " . ($f->{guest} // '-') . ' on ' . ($f->{host} // '-')
            . (defined $f->{workload} ? " of workload $f->{workload}" : '')
            . ' is paused' . (defined $f->{reason} ? " ($f->{reason})" : '') . "; issue $rec->{id} is $rec->{state}";
        HPS::Event::log_event(sub ($l, $m) { $issues->_log($l, $m) },
            pri => ($rec->{severity} eq 'urgent' ? 'urgent' : 'warning'), kind => 'workload', subject => $subject, state => 'paused', text => $text);
        $n++;
    }
    for my $id (sort keys %$gp) {
        next if $live{$id};
        my $subject = delete $gp->{$id};
        delete $remind->{$id};
        my $rec = eval { $issues->get($id) } or next;
        my $r = $rec->{resolution} // {};
        my $state = ($r->{result} // '') =~ /shut off|not defined/ ? 'stopped' : 'resumed';
        HPS::Event::log_event(sub ($l, $m) { $issues->_log($l, $m) },
            pri => 'notice', kind => 'workload', subject => $subject, state => $state,
            text => "hps-guest-paused: issue $id resolved by " . ($r->{by} // '-') . ': ' . ($r->{result} // '-'));
        $n++;
    }
    return $n;
}

# unreadable_event($heal, $rec, $detail): the "state cannot be read" case of one
# issue, as a standing line, repeated like the paused line.
sub unreadable_event ($heal, $rec, $detail) {
    my $now = $heal->_now;
    return 0 unless HPS::Event::remind_due($heal->{gp_remind} //= {}, "$rec->{id}/unreadable", $now);
    my $issues = $heal->{issues};
    HPS::Event::log_event(sub ($l, $m) { $issues->_log($l, $m) },
        pri => 'warning', kind => 'workload', subject => subject($heal, $rec), state => 'unreadable',
        text => 'hps-guest-paused: ' . HPS::Issues::clean_text($detail));
    return 1;
}

1;
