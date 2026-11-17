package HPS::Workload::Net;
# The network side of a workload definition and record (IPS-42): the egress
# hosts a definition declares, and what the lab egress proxy needs from them.
# Every function takes an HPS::Workload object ($wl) for its registry, layout
# and clock; nothing here calls a node.
#
# A definition may declare "flavour" (a name) and "egress" (host names). The
# declaration grants nothing by itself: the lab egress proxy's allowance for a
# workload's address comes from lab/egress-allow, which accepts only the hosts
# the owner lists for that flavour in lab/egress-approved.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use POSIX ();
use HPS::Keysafe ();
use HPS::Workload::List ();

our $FLAVOUR_RE = qr/^[a-z][a-z0-9-]{0,31}\z/;
# A host name as the egress proxy compares it: lower case, two labels or more,
# no wildcard, no port, no address.
our $HOST_RE = qr/^(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/;
our $MAX_EGRESS = 16;

# The names a definition may ask the IPS's DNS to answer for its VMs ("dns", IPS-42
# row 6): pattern => what it answers. Only the wildcard exists; a further pattern
# is one more entry here, a case in publish() and its row in the generator.
our %DNS_PATTERNS = ('*' => '<vm>.<domain> and *.<vm>.<domain>');
our $MAX_DNS = 4;

# check_flavour($v): undef when $v is a flavour name, else the complaint.
sub check_flavour ($v) {
    return 'flavour must be a name like podman-host (lower case letters, digits, hyphens)'
        unless defined $v && !ref $v && "$v" =~ $FLAVOUR_RE;
    return undef;
}

# check_egress($v): (\@hosts, undef) for a list of host names, else (undef, complaint).
sub check_egress ($v) {
    return (undef, 'egress must be a list of host names') unless ref $v eq 'ARRAY';
    return (undef, "egress holds more than $MAX_EGRESS hosts") if @$v > $MAX_EGRESS;
    my (%seen, @out);
    for my $h (@$v) {
        return (undef, 'egress holds a value that is not a lower-case host name like registry.example.org (no wildcard, no port)')
            unless defined $h && !ref $h && "$h" =~ $HOST_RE && "$h" !~ /^[0-9.]+\z/;
        push @out, "$h" unless $seen{$h}++;
    }
    return (\@out, undef);
}

# check_dns($v): (\@patterns, undef) for a list of known DNS patterns, else (undef, complaint).
sub check_dns ($v) {
    return (undef, 'dns must be a list of patterns (the one supported is "*")') unless ref $v eq 'ARRAY';
    return (undef, "dns holds more than $MAX_DNS patterns") if @$v > $MAX_DNS;
    my (%seen, @out);
    for my $p (@$v) {
        return (undef, 'dns holds a value that is not a pattern (the one supported is "*")') if !defined $p || ref $p;
        return (undef, "dns pattern '$p' is not supported (supported: " . join(', ', map { "\"$_\"" } sort keys %DNS_PATTERNS) . ')')
            unless $DNS_PATTERNS{$p};
        push @out, "$p" unless $seen{$p}++;
    }
    return (\@out, undef);
}

# validate_fields(\%def): the checked network fields of a definition that are
# present (flavour, egress, dns), for validate() to merge into its result. Dies with
# a refusal naming the field.
sub validate_fields ($def) {
    my %out;
    my $refuse = sub ($msg) { die HPS::Keysafe::Error->new('refused', "workload: $msg") };
    if (exists $def->{flavour}) {
        my $e = check_flavour($def->{flavour});
        $refuse->($e) if defined $e;
        $out{flavour} = "$def->{flavour}";
    }
    if (exists $def->{egress}) {
        my ($list, $e) = check_egress($def->{egress});
        $refuse->($e) if defined $e;
        $out{egress} = $list;
    }
    if (exists $def->{dns}) {
        my ($list, $e) = check_dns($def->{dns});
        $refuse->($e) if defined $e;
        $out{dns} = $list;
    }
    return %out;
}

# The IPv4 addresses a recorded VM is known by: its leases and reservations, by MAC.
sub _ips ($wl, $name, $rec) {
    my $leases = HPS::Workload::List::leases(HPS::Workload::List::leases_file(), $wl->{now}->());
    my $layout = $wl->layout;
    my $resv = HPS::Workload::List::reserved_macs($wl, $name);
    my %ip;
    for my $vm (sort keys %{ $rec->{vms} // {} }) {
        $ip{ $_->{ip} } = 1 for @{ HPS::Workload::List::addresses($rec->{vms}{$vm}, $layout, $leases, $resv) };
    }
    return [ sort keys %ip ];
}

# egress_rows($wl, project => P): [{name, project, flavour, state, egress, addresses}]
# for every recorded workload whose definition declares egress hosts, by name.
# A workload without a record has no address and is listed with none.
sub egress_rows ($wl, %a) {
    my @out;
    for my $name (HPS::Workload::List::names($wl)) {
        my $def = eval { $wl->load($name) } or next;
        next unless $def->{egress} && @{ $def->{egress} };
        next if defined $a{project} && $def->{project} ne $a{project};
        my $rec = $wl->record($name);
        push @out, { name => $name, project => $def->{project}, flavour => $def->{flavour}, state => $rec ? $rec->{state} : undef,
            egress => $def->{egress}, addresses => $rec ? _ips($wl, $name, $rec) : [] };
    }
    return \@out;
}

sub render_egress ($rows) {
    return "no workload declares egress hosts\n" unless @$rows;
    return join('', map { sprintf("%-32s %-12s %-10s %s -> %s\n", $_->{name}, $_->{flavour} // '-', $_->{state} // 'defined',
        join(',', @{ $_->{addresses} }) || 'no address', join(',', @{ $_->{egress} })) } @$rows);
}

#=== DHCP reservations of the workload NICs (IPS-42 row 5) ==============================
#
# A workload's NIC keeps its address: the lease it holds when first recorded is
# reserved for its MAC (the dhcp-hostsfile of the IPS's dnsmasq, the one the
# registered hosts' reservations are written to). The reservation is kept in the
# cluster key workloadnet_<name> by workload, VM and NIC index:
#   { "<vm>": [ { "nic": 0, "net": "prov", "mac": "52:54:00:..", "ip": "10.100.1.162", "since": "..." } ] }
# so a destroy and a create of the same definition (new MACs) hands the same
# address to the new NIC, and `destroy --forget` releases it.
# Published for the generators of dns_regenerate as services/workload_hosts:
#   host <mac> <ip> <label> <dns|->     the dhcp-host line; dns: the name resolves too
#   wild <label> <ip>                   *.<label>.<domain> and <label>.<domain>, for a
#                                       workload whose definition says "dns": ["*"] (row 6)
# Nothing here calls a node. The dnsmasq files are regenerated by the hook in
# $HPS_WORKLOAD_DNS_CMD (hps-workload sets it to scripts/hps-forget-hook.sh, the
# program hps-onboard forget uses; it is run as `<cmd> dns-dhcp`).

sub reserved_key ($name) { return "workloadnet_$name" }

# reservation_names($wl): the workloads that hold a reservation.
sub reservation_names ($wl) {
    return sort grep { defined } map { /^workloadnet_([a-z][a-z0-9-]{0,31})\z/ ? $1 : undef } $wl->{registry}->cluster_list($wl->_cluster);
}

sub _services_file ($wl) { return $wl->{registry}->cluster_dir($wl->_cluster) . '/services/workload_hosts' }

# The label a NIC is known by: the VM's name for NIC 0, <vm>-nic<i> for the others.
sub nic_label ($vm, $i) { return $i == 0 ? $vm : "$vm-nic$i" }

# The addresses other holders have: [ip => who] for the registered hosts, the IPS
# and every other workload's reservations.
sub _taken ($wl, $name) {
    my %t;
    my $reg = $wl->{registry};
    my $c = $wl->_cluster;
    my $ips = eval { $reg->cluster_exists($c, 'network_dhcp_ip') ? $reg->cluster_get($c, 'network_dhcp_ip') : undef };
    $t{$ips} = 'the IPS' if defined $ips && length $ips;
    for my $h (eval { $reg->host_list_all }) {
        my $ip = eval { $reg->host_exists($h, 'IP') ? $reg->host_get($h, 'IP') : undef };
        $t{$ip} = "registered host $h" if defined $ip && length $ip;
    }
    for my $other (reservation_names($wl)) {
        next if $other eq $name;
        my $r = HPS::Workload::List::reserved($wl, $other);
        for my $vm (keys %$r) { $t{ $_->{ip} } = "workload $other" for @{ $r->{$vm} } }
    }
    return \%t;
}

# reserve($wl, $name, dry_run => 0|1): record the reservation of every NIC of the
# workload's VMs that holds a lease and has none, re-point one whose MAC changed
# (a re-created VM keeps its address), publish and regenerate when anything
# changed. A NIC without a lease is left for a later call. Returns {name,
# changes => [{vm, nic, mac, ip, action}], notes, regenerated}.
sub reserve ($wl, $name, %a) {
    my $rec = $wl->record($name) // die HPS::Keysafe::Error->new('notfound', "workload '$name' has not been created (no registry record)");
    my $layout = $wl->layout;
    my $leases = HPS::Workload::List::leases(HPS::Workload::List::leases_file(), $wl->{now}->());
    my $cur = HPS::Workload::List::reserved($wl, $name);
    my $taken = _taken($wl, $name);
    my (@changes, @notes);
    for my $vm (sort keys %{ $rec->{vms} // {} }) {
        my @nics = HPS::Workload::List::nics($rec->{vms}{$vm}, $layout);
        my @have = @{ $cur->{$vm} // [] };
        for my $i (0 .. $#nics) {
            my $n = $nics[$i];
            next unless defined $n->{mac} && length $n->{mac};
            my ($h) = grep { $_->{nic} == $i } @have;
            if ($h) {
                next if $h->{mac} eq $n->{mac};
                push @changes, { vm => $vm, nic => $i, mac => $n->{mac}, ip => $h->{ip}, action => "re-pointed from $h->{mac}" };
                $h->{mac} = $n->{mac};
                $h->{net} = $n->{net} if defined $n->{net};
                next;
            }
            my $l = $leases->{ $n->{mac} };
            if (!$l) { push @notes, "$vm NIC $i ($n->{mac}): no lease yet, nothing to reserve"; next }
            if (my $who = $taken->{ $l->{ip} }) {
                push @notes, "$vm NIC $i ($n->{mac}): $l->{ip} is already held by $who; not reserved";
                next;
            }
            $taken->{ $l->{ip} } = "workload $name";
            push @have, { nic => $i + 0, net => $n->{net}, mac => $n->{mac}, ip => $l->{ip}, since => $wl->_stamp };
            push @changes, { vm => $vm, nic => $i, mac => $n->{mac}, ip => $l->{ip}, action => 'reserved' };
        }
        $cur->{$vm} = [ sort { $a->{nic} <=> $b->{nic} } @have ] if @have;
    }
    my $out = { name => $name, dry_run => $a{dry_run} ? 1 : 0, changes => \@changes, notes => \@notes };
    return $out if $a{dry_run};
    $wl->{registry}->cluster_set($wl->_cluster, reserved_key($name), $cur) if @changes;
    push @notes, regenerate($wl, publish($wl));
    return $out;
}

# release($wl, $name): drop the workload's reservations (destroy --forget).
sub release ($wl, $name) {
    my $reg = $wl->{registry};
    return [] unless $reg->cluster_exists($wl->_cluster, reserved_key($name));
    $reg->cluster_unset($wl->_cluster, reserved_key($name));
    return [ "released the DHCP reservations of $name", regenerate($wl, publish($wl)) ];
}

# publish($wl): write services/workload_hosts from every reservation; true when
# its content changed. Nothing is written when there is no reservation and no
# earlier file.
sub publish ($wl) {
    my $file = _services_file($wl);
    my @lines;
    my (%mac, %ip, %label);
    # A VM that is also a registered host (a nested node onboarded from a workload) has the address
    # the registry gave it, in dhcp_addresses: a reservation recorded from the dynamic lease it held
    # before it was assigned would give dnsmasq a second, different address for the MAC, and the node
    # would be refused pairing ("request source address does not match the allocation").
    my %is_host;
    for my $h (eval { $wl->{registry}->host_list_all }) {
        (my $m = lc $h) =~ s/[^0-9a-f]//g;
        $is_host{$m} = 1 if eval { $wl->{registry}->host_exists($h, 'IP') };
    }
    for my $name (reservation_names($wl)) {
        my $live = $wl->record($name) ? 1 : 0;
        my $r = HPS::Workload::List::reserved($wl, $name);
        # The DNS patterns of the definition ("dns", row 6), for a workload that exists:
        # "*" answers <vm>.<domain> and *.<vm>.<domain> with the VM's NIC 0 address.
        my $def = $live ? eval { $wl->load($name) } : undef;
        my %pat = map { ($_ => 1) } @{ $def && $def->{dns} ? $def->{dns} : [] };
        for my $vm (sort keys %$r) {
            for my $e (@{ $r->{$vm} }) {
                my $label = nic_label($vm, $e->{nic});
                (my $em = lc $e->{mac}) =~ s/[^0-9a-f]//g;
                next if $is_host{$em};
                next if $mac{ $e->{mac} }++ || $ip{ $e->{ip} }++ || $label{$label}++;
                push @lines, "host $e->{mac} $e->{ip} $label " . ($live ? 'dns' : '-');
                push @lines, "wild $label $e->{ip}" if $live && $e->{nic} == 0 && $pat{'*'};
            }
        }
    }
    @lines = sort @lines;
    return 0 unless @lines || -e $file;
    my $text = "# written by hps-workload from the cluster keys workloadnet_<name>; do not edit\n" . join('', map { "$_\n" } @lines);
    my $old;
    if (open(my $in, '<', $file)) { local $/; $old = <$in>; close $in }
    return 0 if defined $old && $old eq $text;
    require File::Path;
    my $dir = $file =~ s{/[^/]+\z}{}r;
    File::Path::make_path($dir) unless -d $dir;
    my $tmp = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or die HPS::Keysafe::Error->new('failed', "cannot write $tmp: $!");
    print {$fh} $text;
    close($fh) or die HPS::Keysafe::Error->new('failed', "cannot write $tmp: $!");
    rename($tmp, $file) or die HPS::Keysafe::Error->new('failed', "cannot rename $tmp to $file: $!");
    return 1;
}

# regenerate($wl, $changed): run the DHCP and DNS regeneration hook when the
# published file changed; the note to print.
sub regenerate ($wl, $changed) {
    return () unless $changed;
    my $cmd = $ENV{HPS_WORKLOAD_DNS_CMD};
    return 'DHCP and DNS files NOT regenerated: no hook (HPS_WORKLOAD_DNS_CMD)' unless defined $cmd && length $cmd;
    my $pid = open(my $out, '-|') // return "DHCP and DNS files NOT regenerated: cannot run $cmd: $!";
    if (!$pid) { open(STDERR, '>&', \*STDOUT); exec($cmd, 'dns-dhcp') or POSIX::_exit(127) }
    my $text = do { local $/; <$out> };
    close $out;
    my $rc = $? >> 8;
    return $rc == 0 ? 'regenerated the DHCP and DNS files, dnsmasq reloaded' : "regenerating the DHCP and DNS files FAILED (exit $rc): " . ($text // '') =~ s/\s+\z//r;
}

sub render_reserve ($r) {
    my $out = '';
    $out .= sprintf("  %s NIC %d %s %s (%s)\n", $_->{vm}, $_->{nic}, $_->{mac}, $_->{ip}, $_->{action}) for @{ $r->{changes} };
    $out .= "  nothing to reserve\n" unless @{ $r->{changes} };
    $out .= "  note: $_\n" for @{ $r->{notes} };
    return ($r->{dry_run} ? "Dry run: reserve $r->{name}; nothing is changed.\n" : "reserve $r->{name}:\n") . $out;
}

# refresh($wl): publish and regenerate when the published file changed (a
# workload came or went: its name starts or stops resolving).
sub refresh ($wl) { return [ regenerate($wl, publish($wl)) ] }

# note_for($code): the lines worth telling an operator from a reserve, release or
# refresh call: what it did, a refusal, a failed hook; never "no lease yet"
# (status says that itself by showing no address). A problem of its own (an
# exception) is one line, never fatal to the verb that called.
sub note_for ($code) {
    my $r = eval { $code->() };
    if (my $e = $@) { $e = $e->message if ref $e && $e->can('message'); $e =~ s/\s+\z//; return "reservation: $e" }
    return () unless defined $r;
    my @n;
    if (ref $r eq 'ARRAY') { push @n, @$r }
    else {
        push @n, map { "reservation: $_->{vm} NIC $_->{nic} $_->{ip} $_->{action}" } @{ $r->{changes} };
        push @n, grep { !/no lease yet/ } @{ $r->{notes} };
    }
    return @n;
}

#=== changing the declared network fields of an existing workload ======================
#
# define --replace refuses while the workload exists, so a workload made before
# egress and dns existed could never gain them. set_net changes exactly three
# declarative fields of the stored definition: flavour (the label the owner's
# egress approval is looked up by), egress and dns. They are checked as at define
# time (the whole new definition goes through the one validator), nothing else of
# the definition or the record changes, and no VM is touched. A value of "none"
# removes the field. Returns {name, changes => [{field, was, now}], dry_run, notes}.
sub set_net ($wl, $name, %a) {
    my %want;
    for my $k (qw(flavour egress dns)) { $want{$k} = $a{$k} if exists $a{$k} }
    die HPS::Keysafe::Error->new('usage', 'set needs at least one of --flavour, --egress, --dns') unless %want;
    my $path = $wl->definition_path($name);
    my (undef, $old) = $wl->_read_definition($name);
    my $raw = eval { JSON::PP->new->utf8->decode($old) };
    die HPS::Keysafe::Error->new('refused', "$path is not a JSON object; put the definition right first (hps-workload define $name --replace)") unless ref $raw eq 'HASH';
    my @changes;
    for my $k (qw(flavour egress dns)) {
        next unless exists $want{$k};
        my $v = $want{$k};
        my $was = $raw->{$k};
        if (!defined $v) { delete $raw->{$k} }    # "none"
        else { $raw->{$k} = $v }
        my $j = JSON::PP->new->canonical;
        my ($x, $y) = (defined $was ? $j->encode($was) : 'null', defined $v ? $j->encode($v) : 'null');
        push @changes, { field => $k, was => $was, now => $v } if $x ne $y;
    }
    my $text = JSON::PP->new->utf8->canonical->pretty->encode($raw);
    $wl->_checked($name, $text, "$path with the new network fields");    # dies, naming the field
    my $out = { name => $name, changes => \@changes, dry_run => $a{dry_run} ? 1 : 0, notes => [] };
    return $out if $a{dry_run} || !@changes;
    $wl->_write_definition($name, $path, $text, 1);
    $wl->_event('notice', $name, 'done', "set $name: " . join(', ', map { $_->{field} } @changes) . " by $wl->{by}");
    push @{ $out->{notes} }, note_for(sub { refresh($wl) }) if $wl->record($name);
    return $out;
}

sub render_set ($r) {
    my $out = ($r->{dry_run} ? "Dry run: set $r->{name}; nothing is changed.\n" : "set $r->{name}:\n");
    my $j = JSON::PP->new->canonical->allow_nonref;
    $out .= sprintf("  %s: %s -> %s\n", $_->{field}, defined $_->{was} ? $j->encode($_->{was}) : 'none', defined $_->{now} ? $j->encode($_->{now}) : 'none') for @{ $r->{changes} };
    $out .= "  nothing to change\n" unless @{ $r->{changes} };
    $out .= "  note: $_\n" for @{ $r->{notes} };
    $out .= "  (the definition only; a running guest is not touched. egress needs the proxy allowance made by lab/egress-allow)\n" if @{ $r->{changes} } && !$r->{dry_run};
    return $out;
}

1;
