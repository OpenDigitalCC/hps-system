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

use HPS::Keysafe ();
use HPS::Workload::List ();

our $FLAVOUR_RE = qr/^[a-z][a-z0-9-]{0,31}\z/;
# A host name as the egress proxy compares it: lower case, two labels or more,
# no wildcard, no port, no address.
our $HOST_RE = qr/^(?=.{1,253}\z)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\z/;
our $MAX_EGRESS = 16;

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

# validate_fields(\%def): the checked network fields of a definition that are
# present (flavour, egress), for validate() to merge into its result. Dies with
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
    return %out;
}

# The IPv4 addresses a recorded VM is known by: its leases, by MAC.
sub _ips ($wl, $name, $rec) {
    my $leases = HPS::Workload::List::leases(HPS::Workload::List::leases_file(), $wl->{now}->());
    my $layout = $wl->layout;
    my %ip;
    for my $vm (sort keys %{ $rec->{vms} // {} }) {
        $ip{ $_->{ip} } = 1 for @{ HPS::Workload::List::addresses($rec->{vms}{$vm}, $layout, $leases) };
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

1;
