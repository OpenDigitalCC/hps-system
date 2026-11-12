package HPS::Vxlan;
# VXLAN workload networks (layout entries of kind vxlan): which hosts carry
# them, their addresses on the transit network, and the node call that builds
# one on a host (net-vxlan-ensure). Pure reads of the registry; no state is
# added: a host's transit address follows from its provisioning address
# (HPS::ClusterConfig::vlan_host_address), the same rule hps-node net-up uses
# to give it that address.
#
# Transit hosts: every host whose TYPE contains TCH (a converged SCH,TCH too)
# and whose os_id is a NixOS system, as net-up gives a transit address to
# exactly those. Peers of a host on a vxlan network: every other transit host
# with an address on the network's transit (`over`) network. Every vxlan
# network is built on every transit host (one transit VLAN per cluster,
# separation by VNI; plans/networking.md).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HPS::ClusterConfig ();

our $SCRIPT = 'net-vxlan-ensure';

sub _host_val ($reg, $mac, $key) { return $reg->host_exists($mac, $key) ? $reg->host_get($mac, $key) : undef }

sub _ip_int ($ip) { return unpack('N', pack('C4', split /\./, $ip)) }

# names($layout): the vxlan networks of a layout, sorted.
sub names ($layout) {
    return () unless ref $layout eq 'HASH';
    return grep { ref $layout->{$_} eq 'HASH' && ($layout->{$_}{kind} // '') eq 'vxlan' } sort keys %$layout;
}

sub is_vxlan ($layout, $name) {
    return ref $layout eq 'HASH' && ref $layout->{$name} eq 'HASH' && ($layout->{$name}{kind} // '') eq 'vxlan' ? 1 : 0;
}

# provisioning($reg, $cluster, $mac): ($ip, $prefix) of the host's provisioning
# address (host key IP; prefix from NETMASK, else the cluster's network_cidr).
# Either may be undef.
sub provisioning ($reg, $cluster, $mac) {
    my $ip = _host_val($reg, $mac, 'IP');
    $ip = undef unless defined $ip && length $ip;
    my $prefix = HPS::ClusterConfig::prefix_of_netmask(_host_val($reg, $mac, 'NETMASK'));
    if (!defined $prefix) {
        my $cidr = $reg->cluster_exists($cluster, 'network_cidr') ? $reg->cluster_get($cluster, 'network_cidr') // '' : '';
        ($prefix) = $cidr =~ m{/([0-9]{1,2})\z};
    }
    return ($ip, $prefix);
}

# is_transit_host($reg, $mac): TYPE contains TCH and os_id is NixOS.
sub is_transit_host ($reg, $mac) {
    my %type = map { $_ => 1 } split /,/, (_host_val($reg, $mac, 'TYPE') // '');
    my (undef, $os) = split /:/, (_host_val($reg, $mac, 'os_id') // '');
    return $type{TCH} && defined $os && $os eq 'nixos' ? 1 : 0;
}

# transit_address($reg, $cluster, $mac, \%transit_entry): ($address, undef) or
# (undef, $why).
sub transit_address ($reg, $cluster, $mac, $t) {
    return (undef, 'its transit network is not in the layout') unless ref $t eq 'HASH';
    my $v = $t->{vlan};
    return (undef, 'its transit network has no VLAN (1-4094)')
        unless defined $v && !ref $v && $v =~ /^[1-9][0-9]{0,3}\z/ && $v <= 4094;
    my ($ip, $prefix) = provisioning($reg, $cluster, $mac);
    return (undef, 'no provisioning address (host key IP)') unless defined $ip;
    return (undef, 'no provisioning prefix (host key NETMASK or cluster key network_cidr)') unless defined $prefix;
    return HPS::ClusterConfig::vlan_host_address($ip, $prefix, $t->{cidr});
}

# transit_hosts($reg, $cluster, \%transit_entry): every transit host, sorted by
# MAC, as {mac, name, address} or {mac, name, refused => $why}.
sub transit_hosts ($reg, $cluster, $t) {
    my @out;
    for my $mac (sort $reg->host_list_all) {
        next unless is_transit_host($reg, $mac);
        my $name = _host_val($reg, $mac, 'HOSTNAME') // $mac;
        my ($addr, $why) = transit_address($reg, $cluster, $mac, $t);
        push @out, defined $addr ? { mac => $mac, name => $name, address => $addr } : { mac => $mac, name => $name, refused => $why };
    }
    return @out;
}

# host_plan($reg, $mac, layout => \%layout, only => [names], cluster => $c):
# the net-vxlan-ensure call per vxlan network for host $mac (every vxlan
# network of the layout, or the names in `only`), in name order:
#   {name, vni, bridge, over, mtu, local, peers => [...], script, args}
# or {name, vni, bridge, over, refused => $why}. A host that is not a transit
# host has every network refused.
sub host_plan ($reg, $mac, %o) {
    my $c = $o{cluster} // $reg->active_cluster;
    my $layout = $o{layout};
    if (!exists $o{layout}) {
        $layout = $reg->cluster_exists($c, 'network_layout') ? eval { $reg->cluster_get_json($c, 'network_layout') } : undef;
    }
    my @names = $o{only} ? grep { is_vxlan($layout, $_) } @{ $o{only} } : names($layout);
    my $transit_host = is_transit_host($reg, $mac);
    my (%hosts, @plan);
    for my $name (@names) {
        my $n = $layout->{$name};
        my %e = (name => $name, vni => $n->{vni} + 0, bridge => $n->{bridge}, over => $n->{over});
        push @plan, \%e;
        unless ($transit_host) {
            $e{refused} = 'the host is not a transit host (TYPE TCH, NixOS)';
            next;
        }
        my $t = $layout->{ $n->{over} // '' };
        my ($local, $why) = transit_address($reg, $c, $mac, $t);
        if (!defined $local) {
            $e{refused} = "no address on transit network '" . ($n->{over} // '') . "': $why";
            next;
        }
        $hosts{ $n->{over} } //= [ transit_hosts($reg, $c, $t) ];
        my @peers = sort { _ip_int($a) <=> _ip_int($b) }
            map { $_->{address} } grep { $_->{mac} ne $mac && defined $_->{address} && $_->{address} ne $local } @{ $hosts{ $n->{over} } };
        my %seen;
        @peers = grep { !$seen{$_}++ } @peers;
        $e{mtu}    = HPS::ClusterConfig::vxlan_mtu($n);
        $e{local}  = $local;
        $e{peers}  = \@peers;
        $e{script} = $SCRIPT;
        $e{args}   = [ "$e{vni}", $e{bridge}, '--local', $local, (map { ('--peer', $_) } @peers), '--mtu', "$e{mtu}" ];
    }
    return @plan;
}

1;

__END__

=head1 NAME

HPS::Vxlan - VXLAN workload networks: transit hosts, peers and the node call

=head1 FUNCTIONS

C<names($layout)>, C<is_vxlan($layout, $name)>, C<provisioning($reg, $c, $mac)>,
C<is_transit_host($reg, $mac)>, C<transit_address($reg, $c, $mac, $transit)>,
C<transit_hosts($reg, $c, $transit)>, C<host_plan($reg, $mac, %opt)>.

The node call: C<net-vxlan-ensure VNI BRIDGE --local ADDR [--peer ADDR]... --mtu MTU>.

=cut
