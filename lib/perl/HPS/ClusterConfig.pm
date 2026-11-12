package HPS::ClusterConfig;
# Declarative cluster configuration. One catalogue (the table below) lists
# every key the cluster configure menu (scripts/cluster-config.d/*.sh) asks;
# validation, derived keys, apply/export and the question list for the menu
# and a future web form all come from it. Reads and writes go through
# HPS::Registry only (file-per-key cluster.db/<key>.json).
#
# Rule strings (the `rule` field of a question):
#   text            single line, no control characters
#   regex:PATTERN   the whole value must match PATTERN
#   enum:a,b,c      one of the listed values
#   int:MIN..MAX    decimal integer in range
#   int0:MIN..MAX   0, or a decimal integer in range
#   bool            true or false
#   ip              dotted-quad IPv4 address
#   cidr            IPv4 address with /prefix
#   host            IPv4 address or host name
#   dnsdomain       DNS domain, labels of at most 63 characters, the whole domain at
#                   most 52 (every node FQDN <label>.<domain> must stay within 63,
#                   om3's node-name cap; 10 characters are kept for the label,
#                   the longest generated being nixos-001; docs/NAMING.md)
#   subnet_base     X.Y, the first two octets of the storage subnets
#   iplist          IPv4 addresses separated by commas and/or spaces
#   hostlist        host names or IPv4 addresses separated by commas and/or spaces
#   layout          JSON object {"<name>": {cidr, vlan, bridge, purpose, nic?, uplink?}}
#                   or a fabric entry {kind: "fabric", purpose: "emulated-switch", bridge, mtu?}
#                   (no cidr, vlan, nic or uplink: a VLAN-aware bridge with no uplink)
#                   (uplink boot, only with purpose provisioning: the bridge hps-net builds on the boot NIC)
#                   or a vxlan entry {kind: "vxlan", vni, over, bridge, purpose: "workload", mtu?}
#                   (over: a purpose-transit network; VNIs unique; no cidr, vlan, nic or uplink)
# An optional (not required) key may be the empty string.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use HPS::Registry;

package HPS::ClusterConfig::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message, $detail = undef) {
        return bless { kind => $kind, message => $message, detail => $detail }, $class;
    }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
    sub detail ($self)  { return $self->{detail} }
}

sub _fail ($kind, $msg, $detail = undef) { die HPS::ClusterConfig::Error->new($kind, $msg, $detail) }

#--- the catalogue -----------------------------------------------------------------

my $IP_OCTET = qr/(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/;
my $IP_RE    = qr/^(?:$IP_OCTET\.){3}$IP_OCTET\z/;

sub _q (%f) {
    return {
        key          => $f{key},
        group        => $f{group},
        prompt       => $f{prompt},
        rule         => $f{rule},
        default      => $f{default},
        default_from => $f{default_from},
        required     => $f{required} ? JSON::PP::true : JSON::PP::false,
        derives      => $f{derives} // [],
        menu         => exists $f{menu} && !$f{menu} ? JSON::PP::false : JSON::PP::true,
    };
}

# Menu order: 010, 015, 020, 050, 070, 090. `menu` false: the menu does not
# ask this directly (it discovers the value from the interface or fixes it).
my @CATALOGUE = (
    _q(key => 'DESCRIPTION', group => 'description', required => 1,
        prompt => 'Enter descriptive name for this cluster', rule => 'regex:.+'),

    _q(key => 'network_dns_domain', group => 'dns', required => 1,
        prompt => 'Enter DNS domain name for this cluster', rule => 'dnsdomain', default => 'cluster.local'),

    _q(key => 'network_dhcp_enabled', group => 'dhcp', menu => 0,
        prompt => 'DHCP enabled', rule => 'bool', default => 'true'),
    _q(key => 'network_dhcp_iface', group => 'dhcp', required => 1,
        prompt => 'Select interface to listen on for boot requests', rule => 'regex:[A-Za-z0-9_.:@-]+'),
    _q(key => 'network_dhcp_cidr', group => 'dhcp', required => 1, menu => 0,
        prompt => 'Address of the DHCP interface (IP/prefix)', rule => 'cidr',
        derives => [ 'network_dhcp_ip', 'network_cidr' ]),
    _q(key => 'network_dhcp_rangesize', group => 'dhcp',
        prompt => 'DHCP range size (number of IPs)', rule => 'int:1..16777216', default => '100'),
    _q(key => 'network_dhcp_range_start', group => 'dhcp', menu => 0,
        prompt => 'DHCP range start (blank: from the range size)', rule => 'ip', default => ''),
    _q(key => 'network_dhcp_range_end', group => 'dhcp', menu => 0,
        prompt => 'DHCP range end (blank: from the range size)', rule => 'ip', default => ''),

    _q(key => 'network_static_start', group => 'dhcp', menu => 0,
        prompt => 'Static address range start (inside the DHCP network)', rule => 'ip'),
    _q(key => 'network_static_end', group => 'dhcp', menu => 0,
        prompt => 'Static address range end (inside the DHCP network)', rule => 'ip'),
    _q(key => 'network_reserved', group => 'dhcp', menu => 0,
        prompt => 'Reserved addresses (IPv4, comma or space separated; may be empty)', rule => 'iplist', default => ''),

    _q(key => 'network_storage_count', group => 'storage-networks',
        prompt => 'Number of storage networks to configure (1-10)', rule => 'int:0..10', default => '2',
        derives => ['network_storage_vlanN_*']),
    _q(key => 'network_storage_base_vlan', group => 'storage-networks',
        prompt => 'Storage network base VLAN ID (2-4094)', rule => 'int:2..4094', default => '31',
        derives => ['network_storage_vlanN_*']),
    _q(key => 'network_storage_subnet_base', group => 'storage-networks',
        prompt => 'Storage subnet base', rule => 'subnet_base', default_from => 'network_storage_base_vlan',
        derives => ['network_storage_vlanN_*']),
    _q(key => 'network_storage_subnet_cidr', group => 'storage-networks',
        prompt => 'Storage subnet CIDR mask (16-28)', rule => 'int:16..28', default => '24',
        derives => ['network_storage_vlanN_*']),
    _q(key => 'network_storage_mtu', group => 'storage-networks',
        prompt => 'Enable jumbo frames (9000 MTU) on storage networks?', rule => 'enum:1500,9000', default => '1500'),

    _q(key => 'network_syslog_server', group => 'services',
        prompt => 'Syslog server IP address', rule => 'ip', default_from => 'network_dhcp_ip'),
    _q(key => 'network_name_server', group => 'services',
        prompt => 'DNS server IP address', rule => 'ip', default_from => 'network_dhcp_ip'),
    _q(key => 'network_time_server', group => 'services',
        prompt => 'NTP server address', rule => 'host', default_from => 'network_dhcp_ip'),

    _q(key => 'network_time_upstream', group => 'services', menu => 0,
        prompt => 'Upstream time servers (host names or IPv4, comma or space separated; may be empty)',
        rule => 'hostlist', default => ''),
    _q(key => 'network_layout', group => 'networks', menu => 0,
        prompt => 'Workload network layout (one-line JSON object)', rule => 'layout'),

    _q(key => 'osvc_log_level', group => 'opensvc',
        prompt => 'Log level (debug/info/warn/error)', rule => 'enum:debug,info,warn,error', default => 'info'),
    _q(key => 'osvc_listener_port', group => 'opensvc',
        prompt => 'Listener port (1024-65535)', rule => 'int:1024..65535', default => '1215'),
    _q(key => 'osvc_web_ui', group => 'opensvc',
        prompt => 'Enable Web UI?', rule => 'enum:yes,no', default => 'yes'),
    _q(key => 'osvc_web_port', group => 'opensvc',
        prompt => 'Web UI port (1024-65535)', rule => 'int:1024..65535', default => '1214'),
    _q(key => 'osvc_hb_interval', group => 'opensvc',
        prompt => 'Heartbeat interval in seconds (1-60)', rule => 'int:1..60', default => '5'),
    _q(key => 'osvc_hb_timeout', group => 'opensvc',
        prompt => 'Heartbeat timeout in seconds (5-300)', rule => 'int:5..300', default => '15'),
    _q(key => 'osvc_templates_url', group => 'opensvc',
        prompt => 'Templates URL', rule => 'text', default => ''),
    _q(key => 'osvc_packages_url', group => 'opensvc',
        prompt => 'Packages URL', rule => 'text', default => ''),
    _q(key => 'osvc_hb_type', group => 'opensvc',
        prompt => 'Heartbeat type (multicast/unicast)', rule => 'enum:multicast,unicast', default => 'unicast'),

    # Held nodes (IPS-14): read by the iPXE hold script and the audit boot, not asked by the menu.
    _q(key => 'hold_retry_seconds', group => 'onboarding', menu => 0,
        prompt => 'Seconds a held node with its audit stored waits at iPXE between requests (5-3600)', rule => 'int:5..3600', default => '30'),
    # Audit admission (IPS-16): read by the iPXE menu when a held host needs an audit.
    _q(key => 'audit_max_concurrent', group => 'onboarding', menu => 0,
        prompt => 'Audit boots the IPS serves at once (0-1000; 0 = no limit)', rule => 'int:0..1000', default => '2'),
    _q(key => 'audit_timeout_seconds', group => 'onboarding', menu => 0,
        prompt => 'Seconds after serving the audit image that an unfinished audit frees its slot (30-86400)', rule => 'int:30..86400', default => '900'),
    # Resource monitor (docs/MONITORING.md): hps-monitor loop, run under supervisor.
    _q(key => 'monitor_interval_seconds', group => 'monitoring', menu => 0,
        prompt => 'Seconds between resource checks of the paired nodes (10-86400; 0 disables)', rule => 'int0:10..86400', default => '60'),
    # Persistent filesystems and pools (docs/MONITORING.md): hps-monitor grades the
    # nodes' disk_*, zpool_cap and the IPS's own disks with these; hps-ips-check too.
    _q(key => 'monitor_disk_warn_pct', group => 'monitoring', menu => 0,
        prompt => 'Percent of a persistent filesystem or pool used (space or inodes) that is a WARNING (1-100, below monitor_disk_crit_pct)', rule => 'int:1..100', default => '80'),
    _q(key => 'monitor_disk_crit_pct', group => 'monitoring', menu => 0,
        prompt => 'Percent of a persistent filesystem or pool used (space or inodes) that is CRITICAL (1-100)', rule => 'int:1..100', default => '90'),
    _q(key => 'held_reboot_after_audit', group => 'onboarding', menu => 0,
        prompt => 'Reboot the audit image after the IPS accepts its audit (false keeps it up for inspection)', rule => 'bool', default => 'true'),

    # Operator access (docs/OPERATOR.md): read at IPS start by ce_api_bring_up.
    _q(key => 'operator_api_listen', group => 'operator', menu => 0,
        prompt => 'Address of this IPS where the ctrl-exec API listens with TLS for remote operators (empty: no remote operator)', rule => 'ip', default => ''),
    _q(key => 'ips_admin_read_timeout', group => 'operator', menu => 0,
        prompt => 'Seconds to wait for the IPS\'s own ips-admin agent to answer, so long jobs (publish, storage) return their output (60-3600)', rule => 'int:60..3600', default => '900'),
    # Optional syslog forward, set by the operator action ips-syslog-forward.
    _q(key => 'syslog_forward_host', group => 'operator', menu => 0,
        prompt => 'Collector to forward every syslog message to over TCP 514 (empty: no forwarding)', rule => 'ip', default => ''),
    _q(key => 'syslog_forward_prefix', group => 'operator', menu => 0,
        prompt => 'Host name prefix of the forwarded messages (<prefix>.<hostname>)', rule => 'regex:[a-z0-9][a-z0-9-]{0,31}', default => ''),
    # Image builder (docs/BUILDER.md): its one way out, passed as hps.proxy=.
    _q(key => 'egress_proxy', group => 'operator', menu => 0,
        prompt => 'HTTP proxy the image builder reaches the internet through, http://<host>:<port> (empty: none)',
        rule => 'regex:http://[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[0-9]{1,5}', default => ''),
    # The site repository (docs/REPOSITORY.md): hps-repo drives it.
    _q(key => 'repo_host', group => 'operator', menu => 0,
        prompt => 'The host that holds the site repository (its registry HOSTNAME or MAC; empty: none, hps-repo refuses)',
        rule => 'regex:[A-Za-z0-9][A-Za-z0-9.:-]{0,62}', default => ''),
    _q(key => 'repo_nix_pubkey', group => 'operator', menu => 0,
        prompt => 'The site repository\'s Nix cache public key, <name>:<base64> (hps-repo status stores it when empty)',
        rule => 'regex:[A-Za-z0-9][A-Za-z0-9._-]{0,63}:[A-Za-z0-9+/]{43}=', default => ''),
    _q(key => 'repo_upstream', group => 'operator', menu => 0,
        prompt => 'Whether repo build may also substitute from upstream caches through egress_proxy (false: the repository alone)',
        rule => 'bool', default => 'false'),

    # Host reserve (docs/CLUSTER-CONFIG.md "Host reserve"): read at every node
    # boot by host-reserve-apply. Empty: the default sized from the host.
    _q(key => 'host_reserve_cpus', group => 'resources', menu => 0,
        prompt => 'Logical CPUs every node keeps from its guests for itself (0-1024; 0 = none; empty: 1, or 2 on a host with 16 or more)',
        rule => 'int0:1..1024', default => ''),
    _q(key => 'host_reserve_mem_mib', group => 'resources', menu => 0,
        prompt => 'MiB of RAM every node keeps from its guests for itself (256-16777216; empty: 10% of RAM, at least 2048)',
        rule => 'int:256..16777216', default => ''),
    _q(key => 'zfs_arc_max_pct', group => 'resources', menu => 0,
        prompt => 'ZFS ARC cap on storage nodes, percent of RAM, at least 1024 MiB (1-90)',
        rule => 'int:1..90', default => '25'),
);

my %BY_KEY = map { $_->{key} => $_ } @CATALOGUE;

my @STORAGE_INPUTS = qw(network_storage_count network_storage_base_vlan network_storage_subnet_base
    network_storage_subnet_cidr network_dns_domain);
my %IS_STORAGE_INPUT = map { $_ => 1 } @STORAGE_INPUTS;

# A key no catalogue entry may ever be: nothing secret belongs in this format.
my $SECRET_NAME_RE = qr/(?:secret|passw|token|credential|psk|private|(?:^|_)key(?:$|_))/i;

sub secret_name_re () { return $SECRET_NAME_RE }

# The catalogue, as fresh copies (callers may modify them).
sub questions () {
    return map { +{ %$_, derives => [ @{ $_->{derives} } ] } } @CATALOGUE;
}

sub question ($key) { return $BY_KEY{$key} }

sub is_derived_key ($key) {
    return 1 if $key eq 'network_dhcp_ip' || $key eq 'network_cidr';
    return $key =~ /^network_storage_vlan([0-9]+)_(subnet|gateway|netmask|domain|allocated)\z/ ? 1 : 0;
}

#--- value rules ----------------------------------------------------------------------

sub _valid_ip ($v) { return $v =~ $IP_RE ? 1 : 0 }

sub _ip_to_int ($ip) { return unpack('N', pack('C4', split /\./, $ip)) }
sub _int_to_ip ($n)  { return join '.', unpack('C4', pack('N', $n)) }

sub _netmask ($prefix) {
    my $m = $prefix == 0 ? 0 : (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF;
    return _int_to_ip($m);
}

# Returns an error message, or undef when $value suits the rule of $q.
sub validate_value ($q, $value) {
    my $v = $value // '';
    return 'must be a single line' if $v =~ /[\x00-\x1f\x7f]/;
    if ($v eq '') {
        return $q->{required} ? 'must not be empty' : undef;
    }
    my ($kind, $arg) = split /:/, $q->{rule}, 2;
    if ($kind eq 'text')  { return undef }
    if ($kind eq 'regex') { return $v =~ /^(?:$arg)\z/ ? undef : "does not match $arg" }
    if ($kind eq 'enum') {
        my @ok = split /,/, $arg;
        return (grep { $_ eq $v } @ok) ? undef : 'must be one of ' . join(', ', @ok);
    }
    if ($kind eq 'int') {
        my ($min, $max) = $arg =~ /^(\d+)\.\.(\d+)\z/;
        return "must be a whole number from $min to $max"
            unless $v =~ /^(?:0|[1-9][0-9]*)\z/ && $v >= $min && $v <= $max;
        return undef;
    }
    if ($kind eq 'int0') {    # 0, or an integer in MIN..MAX
        my ($min, $max) = $arg =~ /^(\d+)\.\.(\d+)\z/;
        return "must be 0 or a whole number from $min to $max"
            unless $v =~ /^(?:0|[1-9][0-9]*)\z/ && ($v == 0 || ($v >= $min && $v <= $max));
        return undef;
    }
    if ($kind eq 'bool') { return $v eq 'true' || $v eq 'false' ? undef : 'must be true or false' }
    if ($kind eq 'ip')   { return _valid_ip($v) ? undef : 'must be an IPv4 address' }
    if ($kind eq 'cidr') {
        my ($ip, $p) = $v =~ m{^([0-9.]+)/([0-9]+)\z};
        return 'must be an IPv4 address with /prefix, such as $IP/24'
            unless defined $ip && _valid_ip($ip) && $p <= 32;
        return undef;
    }
    if ($kind eq 'host') {
        return undef if _valid_ip($v);
        return 'must be an IPv4 address or a host name' if $v =~ /^[0-9.]+\z/;
        return $v =~ /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/ ? undef : 'must be an IPv4 address or a host name';
    }
    if ($kind eq 'dnsdomain') {
        return 'must be a DNS domain such as cluster.local'
            unless $v =~ /^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?))*\z/;
        return 'a label is longer than 63 characters' if grep { length($_) > 63 } split /\./, $v;
        return 'is longer than 52 characters: a node FQDN <name>.<domain> must stay within 63 (om3 node names)' if length($v) > 52;
        return undef;
    }
    if ($kind eq 'subnet_base') {
        my ($a, $b) = $v =~ /^([0-9]{1,3})\.([0-9]{1,3})\z/;
        return 'must be X.Y, such as 10.31' unless defined $a && $a <= 255 && $b <= 255;
        return undef;
    }
    if ($kind eq 'iplist') {
        my @bad = grep { !_valid_ip($_) } split /[,\s]+/, $v;
        return @bad ? 'not an IPv4 address: ' . join(', ', @bad) : undef;
    }
    if ($kind eq 'hostlist') {
        for my $h (split /[,\s]+/, $v) {
            next if _valid_ip($h);
            return "not a host name or IPv4 address: $h" if $h =~ /^[0-9.]+\z/;
            return "not a host name or IPv4 address: $h" unless $h =~ /^[A-Za-z0-9][A-Za-z0-9.-]*\z/;
        }
        return undef;
    }
    if ($kind eq 'layout') { return validate_layout($v) }
    die "Unknown rule '$q->{rule}' for $q->{key}\n";
}

# The transit VLAN is jumbo (plans/networking.md); a VXLAN over it loses 50
# bytes to the outer Ethernet, IP, UDP and VXLAN headers.
our $TRANSIT_MTU  = 9000;
our $VXLAN_HEADER = 50;

# vxlan_mtu(\%entry): the MTU of a vxlan layout network, its mtu or the
# transit MTU less the VXLAN header (8950).
sub vxlan_mtu ($n) { return defined $n->{mtu} ? $n->{mtu} + 0 : $TRANSIT_MTU - $VXLAN_HEADER }

# A vxlan entry {kind: "vxlan", vni, over, bridge, purpose: "workload", mtu?}.
# Returns an error or undef; `over` is checked against the whole layout after.
sub _validate_vxlan ($name, $n, $vnis) {
    for my $f (qw(cidr vlan nic uplink)) {
        return "network '$name': a vxlan network takes no $f (it is carried by its transit network)" if defined $n->{$f};
    }
    return "network '$name': a vxlan network has purpose \"workload\""
        unless defined $n->{purpose} && !ref $n->{purpose} && $n->{purpose} eq 'workload';
    return "network '$name': vni must be 1 to 16777215"
        unless defined $n->{vni} && !ref $n->{vni} && $n->{vni} =~ /^[1-9][0-9]{0,7}\z/ && $n->{vni} <= 16777215;
    return "network '$name': vni $n->{vni} is also used by '$vnis->{ $n->{vni} + 0 }'" if $vnis->{ $n->{vni} + 0 };
    $vnis->{ $n->{vni} + 0 } = $name;
    return "network '$name': over (the name of a purpose transit network) is required"
        unless defined $n->{over} && !ref $n->{over} && length $n->{over};
    my $max = $TRANSIT_MTU - $VXLAN_HEADER;
    if (defined $n->{mtu}) {
        return "network '$name': mtu must be 576 to $max (the transit MTU $TRANSIT_MTU less $VXLAN_HEADER)"
            unless !ref $n->{mtu} && $n->{mtu} =~ /^[1-9][0-9]{2,3}\z/ && $n->{mtu} >= 576 && $n->{mtu} <= $max;
    }
    return undef;
}

# network_layout (the shape net-bridge-ensure and net-vxlan-ensure read).
# Returns an error or undef.
sub validate_layout ($text) {
    my $data = eval { JSON::PP->new->decode($text) };
    return 'not valid JSON' unless defined $data;
    return 'must be a JSON object of networks' unless ref $data eq 'HASH';
    my (%vlans, %bridges, %vnis);
    for my $name (sort keys %$data) {
        my $n = $data->{$name};
        return "network name '$name' must match ^[a-z][a-z0-9-]{0,15}\$" unless $name =~ /^[a-z][a-z0-9-]{0,15}\z/;
        return "network '$name' must be an object" unless ref $n eq 'HASH';
        my %ok = map { $_ => 1 } qw(cidr vlan bridge purpose nic uplink kind mtu vni over);
        my ($extra) = grep { !$ok{$_} } sort keys %$n;
        return "network '$name': unknown field '$extra'" if defined $extra;
        my $vxlan = defined $n->{kind} && !ref $n->{kind} && $n->{kind} eq 'vxlan';
        if (!$vxlan) {
            for my $f (qw(vni over)) {
                return "network '$name': $f is only for a vxlan network" if defined $n->{$f};
            }
        }
        my $fabric = defined $n->{kind} && !$vxlan;
        if ($vxlan) {
            my $e = _validate_vxlan($name, $n, \%vnis);
            return $e if defined $e;
        }
        elsif ($fabric) {
            return "network '$name': kind must be \"fabric\" or \"vxlan\"" unless !ref $n->{kind} && $n->{kind} eq 'fabric';
            return "network '$name': a fabric network has purpose \"emulated-switch\""
                unless defined $n->{purpose} && !ref $n->{purpose} && $n->{purpose} eq 'emulated-switch';
            for my $f (qw(cidr vlan nic uplink)) {
                return "network '$name': a fabric network (an emulated switch) takes no $f" if defined $n->{$f};
            }
            return "network '$name': bridge is required" unless defined $n->{bridge} && !ref $n->{bridge} && length $n->{bridge};
            if (defined $n->{mtu}) {
                return "network '$name': mtu must be 576 to 9216"
                    unless !ref $n->{mtu} && $n->{mtu} =~ /^[1-9][0-9]{2,3}\z/ && $n->{mtu} >= 576 && $n->{mtu} <= 9216;
            }
        }
        else {
            return "network '$name': mtu is only for a fabric or vxlan network" if defined $n->{mtu};
            return "network '$name': purpose emulated-switch needs kind \"fabric\""
                if defined $n->{purpose} && !ref $n->{purpose} && $n->{purpose} eq 'emulated-switch';
        }
        my $bare = $fabric || $vxlan;    # no cidr of its own
        for my $req ($bare ? qw(bridge purpose) : qw(cidr bridge purpose)) {
            return "network '$name': $req is required" unless defined $n->{$req} && !ref $n->{$req} && length $n->{$req};
        }
        return "network '$name': cidr must be IPv4/prefix" if !$bare && defined validate_value({ rule => 'cidr', required => 1 }, $n->{cidr});
        return "network '$name': bridge must match ^br-[a-z0-9-]{1,12}\$" unless $n->{bridge} =~ /^br-[a-z0-9-]{1,12}\z/;
        return "network '$name': purpose must be a short word" unless $n->{purpose} =~ /^[a-z][a-z0-9-]{0,15}\z/;
        if (defined $n->{uplink}) {
            return "network '$name': uplink must be \"boot\"" unless !ref $n->{uplink} && $n->{uplink} eq 'boot';
            return "network '$name': uplink boot is only for purpose provisioning" unless $n->{purpose} eq 'provisioning';
            return "network '$name': uplink boot (a bridge hps-net builds on the boot NIC) takes no vlan and no nic"
                if defined $n->{vlan} || defined $n->{nic};
        }
        if (defined $n->{vlan}) {
            return "network '$name': vlan must be 1 to 4094"
                unless !ref $n->{vlan} && $n->{vlan} =~ /^[1-9][0-9]{0,3}\z/ && $n->{vlan} <= 4094;
            return "network '$name': vlan $n->{vlan} is also used by '$vlans{$n->{vlan}}'" if $vlans{ $n->{vlan} };
            $vlans{ $n->{vlan} } = $name;
        }
        if (defined $n->{nic}) {
            return "network '$name': nic must be a MAC address"
                unless !ref $n->{nic} && $n->{nic} =~ /^(?:[0-9A-Fa-f]{2}([:-]?)){5}[0-9A-Fa-f]{2}\z/;
        }
        return "network '$name': bridge '$n->{bridge}' is also used by another network" if $bridges{ $n->{bridge} }++;
    }
    for my $name (sort keys %$data) {
        my $n = $data->{$name};
        next unless defined $n->{kind} && $n->{kind} eq 'vxlan';
        my $t = $data->{ $n->{over} };
        return "network '$name': over '$n->{over}' is not a network of the layout" unless ref $t eq 'HASH';
        return "network '$name': over '$n->{over}' is not a purpose transit network"
            unless !defined $t->{kind} && defined $t->{purpose} && $t->{purpose} eq 'transit';
    }
    return undef;
}

# The stored form compared and shown: layout as canonical one-line JSON.
sub normalise_value ($key, $value) {
    return $value unless $key eq 'network_layout' && defined $value;
    my $data = eval { JSON::PP->new->decode($value) };
    return $value unless ref $data eq 'HASH';
    return JSON::PP->new->canonical->encode($data);
}

#--- derived keys (the arithmetic of 050-set-storage-network.sh) ----------------------

# network_dhcp_ip and network_cidr from network_dhcp_cidr "IP/PREFIX".
sub derive_dhcp ($cidr) {
    my ($ip, $p) = $cidr =~ m{^([0-9.]+)/([0-9]+)\z};
    my $mask = $p == 0 ? 0 : (0xFFFFFFFF << (32 - $p)) & 0xFFFFFFFF;
    my $net  = _ip_to_int($ip) & $mask;
    return { network_dhcp_ip => $ip, network_cidr => _int_to_ip($net) . "/$p" };
}

# network_calculate_subnet: base "A.B", index, prefix -> "A.B.C.D/prefix", or
# undef when the prefix is not supported by the shell function.
sub storage_subnet ($base, $index, $prefix) {
    my ($o1, $o2) = split /\./, $base;
    return "$o1.$o2.$index.0/$prefix" if $prefix == 24;
    return "$base.0.0/$prefix"        if $prefix == 16;
    if ($prefix >= 25 && $prefix <= 28) {
        my $off = $index * (2**(32 - $prefix));
        return "$o1.$o2." . int($off / 256) . '.' . ($off % 256) . "/$prefix";
    }
    return undef;
}

# Per-VLAN keys for count/base_vlan/subnet_base/subnet_cidr/dns_domain, as
# { key => value } (allocated excluded: it is runtime state, see plan()).
# Returns (\%keys, $error).
sub derive_storage ($count, $base_vlan, $subnet_base, $prefix, $dns_domain) {
    my %out;
    return (\%out, undef) if $count == 0;
    my $max = $base_vlan + $count - 1;
    return (undef, "VLAN range would exceed 4094 (max would be $max)") if $max > 4094;
    for my $i (0 .. $count - 1) {
        my $vlan   = $base_vlan + $i;
        my $subnet = storage_subnet($subnet_base, $i, $prefix);
        return (undef, "Unsupported CIDR: /$prefix (storage subnets support /16 and /24 to /28)")
            unless defined $subnet;
        (my $net = $subnet) =~ s{/.*}{};
        (my $gw  = $net)    =~ s{\.[^.]*\z}{.1};
        $out{"network_storage_vlan${vlan}_subnet"}  = $subnet;
        $out{"network_storage_vlan${vlan}_gateway"} = $gw;
        $out{"network_storage_vlan${vlan}_netmask"} = _netmask($prefix);
        $out{"network_storage_vlan${vlan}_domain"}  = 'storage' . ($i + 1) . ".$dns_domain";
    }
    return (\%out, undef);
}

#--- host addresses on storage and transit networks ---------------------------------------

# vlan_host_address($ip, $prefix, $target_cidr, gateway => IP): a host's address
# on a storage or transit network, with no new state: the host part of its
# provisioning address $ip/$prefix, modulo the size of the target subnet, inside
# that subnet. For a /24 into a /24 the last octet is kept (10.11.0.153/24 into
# 10.113.0.0/24 gives 10.113.0.153). Returns ($address, undef), or (undef, $why)
# when an input is malformed or the result is the target's network or broadcast
# address or the given gateway.
sub vlan_host_address ($ip, $prefix, $target, %o) {
    return (undef, "provisioning address '" . ($ip // '') . "' is not an IPv4 address")
        unless defined $ip && _valid_ip($ip);
    return (undef, "provisioning prefix '" . ($prefix // '') . "' is not 1-32")
        unless defined $prefix && $prefix =~ /^[0-9]{1,2}\z/ && $prefix >= 1 && $prefix <= 32;
    my ($tip, $tp) = defined $target ? $target =~ m{^([0-9.]+)/([0-9]{1,2})\z} : ();
    return (undef, "target subnet '" . ($target // '') . "' is not IPv4/prefix")
        unless defined $tip && _valid_ip($tip);
    return (undef, "target subnet $target: prefix must be 8 to 30") unless $tp >= 8 && $tp <= 30;
    my $host  = _ip_to_int($ip) & ~_ip_to_int(_netmask($prefix)) & 0xFFFFFFFF;
    my $size  = 2**(32 - $tp);
    my $net   = _ip_to_int($tip) & _ip_to_int(_netmask($tp));
    my $off   = $host % $size;
    my $addr  = _int_to_ip($net + $off);
    my $short = _int_to_ip($net) . "/$tp";
    return (undef, "$ip/$prefix maps to $addr, the network address of $short") if $off == 0;
    return (undef, "$ip/$prefix maps to $addr, the broadcast address of $short") if $off == $size - 1;
    return (undef, "$ip/$prefix maps to $addr, the gateway of $short")
        if defined $o{gateway} && length $o{gateway} && $addr eq $o{gateway};
    return ($addr, undef);
}

# prefix_of_netmask('255.255.255.0') -> 24; undef when not a contiguous mask.
sub prefix_of_netmask ($mask) {
    return undef unless defined $mask && _valid_ip($mask);
    my $n = _ip_to_int($mask);
    my $p = 0;
    $p++ while $p < 32 && ($n & (0x80000000 >> $p));
    return _netmask($p) eq $mask ? $p : undef;
}

#--- the object ----------------------------------------------------------------------------

sub _default_logger ($level, $msg) {
    return if $ENV{HPS_CLUSTER_CONFIG_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-cluster-config: $msg");
    };
    return;
}

# new(registry => HPS::Registry, cluster => NAME, logger => sub($level, $msg))
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    return bless { registry => $reg, cluster => $opt{cluster}, logger => $opt{logger} // \&_default_logger }, $class;
}

sub registry ($self) { return $self->{registry} }

sub cluster ($self) {
    return $self->{cluster} if defined $self->{cluster};
    my $name = eval { $self->{registry}->active_cluster };
    _fail('notfound', 'No cluster named and no ACTIVE_CLUSTER (use --cluster NAME)') unless defined $name;
    $self->{cluster} = $name;
    return $name;
}

sub _checked_cluster ($self) {
    my $c = $self->cluster;
    my $ok = eval { $self->{registry}->cluster_exists($c) };
    _fail('refused', "Invalid cluster name: $c") if $@;
    _fail('notfound', "Cluster not found: $c") unless $ok;
    return $c;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

# Value as stored, or undef when unset.
sub get ($self, $key) {
    my $c = $self->_checked_cluster;
    return $self->{registry}->cluster_get($c, $key);
}

#--- files ---------------------------------------------------------------------------------

# Parse a declarative file. Returns (\@entries, \@errors); an entry is
# { key, value, line } (line is 0 for JSON). Nothing is validated against the
# catalogue here beyond the syntax.
sub parse_file ($text) {
    my (@entries, @errors, %seen);
    my $add = sub ($key, $value, $line) {
        if ($seen{$key}) {
            push @errors, { line => $line, key => $key, message => "duplicate key (first on line $seen{$key})" };
            return;
        }
        $seen{$key} = $line;
        push @entries, { key => $key, value => $value, line => $line };
    };
    if ($text =~ /^\s*\{/) {
        my $data = eval { JSON::PP->new->utf8(0)->decode($text) };
        return ([], [ { line => 0, key => undef, message => 'invalid JSON: ' . ($@ =~ s/ at .*//sr) } ]) unless ref $data eq 'HASH';
        for my $k (sort keys %$data) {
            my $v = $data->{$k};
            $v = JSON::PP->new->canonical->encode($v) if $k eq 'network_layout' && ref $v eq 'HASH';
            if (!defined $v || ref $v && !JSON::PP::is_bool($v)) {
                push @errors, { line => 0, key => $k, message => 'value must be a string, number or boolean' };
                next;
            }
            $v = $v ? 'true' : 'false' if JSON::PP::is_bool($v);
            $add->($k, "$v", 0);
        }
        return (\@entries, \@errors);
    }
    my $n = 0;
    for my $raw (split /\r?\n/, $text, -1) {
        $n++;
        next if $raw =~ /^\s*(?:#.*)?\z/;
        if ($raw =~ /^\s*([A-Za-z0-9_-]+)\s*=\s*(.*?)\s*\z/) {
            $add->($1, $2, $n);
        }
        else {
            push @errors, { line => $n, key => undef, message => 'not a "key = value" line' };
        }
    }
    return (\@entries, \@errors);
}

#--- planning ---------------------------------------------------------------------------------

# plan(\@entries): validate everything, change nothing. Returns
# { errors => [{line,key,message}], changes => [{key,old,new,derived}],
#   unchanged => [keys], missing_required => [keys] }.
sub plan ($self, $entries) {
    my $c = $self->_checked_cluster;
    my $reg = $self->{registry};
    my (@errors, %given, %line);
    my $err = sub ($key, $msg) { push @errors, { line => $line{$key} // 0, key => $key, message => $msg } };

    for my $e (@$entries) {
        my ($k, $v) = ($e->{key}, $e->{value});
        $v //= '';
        $v =~ s/^\s+|\s+\z//g;
        $v = normalise_value($k, $v) if $BY_KEY{$k} && !defined validate_value($BY_KEY{$k}, $v);
        $line{$k} = $e->{line};
        $given{$k} = $v;
        if (my $q = $BY_KEY{$k}) {
            if (defined(my $m = validate_value($q, $v))) { $err->($k, $m) }
        }
        elsif (is_derived_key($k)) {
            if ($k =~ /_allocated\z/ && $v ne 'true' && $v ne 'false') { $err->($k, 'must be true or false') }
        }
        else {
            $err->($k, $k =~ $SECRET_NAME_RE ? 'unknown key (secrets are never part of this format)' : 'unknown key');
        }
    }

    # The effective value: given, else stored, else the literal default.
    my %stored;
    my $stored = sub ($k) { return $stored{$k} //= { v => normalise_value($k, scalar $reg->cluster_get($c, $k)) } };
    my $eff = sub ($k) {
        return $given{$k} if exists $given{$k};
        my $s = $stored->($k)->{v};
        return $s if defined $s;
        return $BY_KEY{$k} ? $BY_KEY{$k}{default} : undef;
    };
    my $firstline = sub (@keys) { my ($k) = grep { exists $given{$_} } @keys; return $k };

    # Cross-field rules, only when one of the keys involved was given.
    if (grep { exists $given{$_} } qw(osvc_hb_interval osvc_hb_timeout)) {
        my ($i, $t) = ($eff->('osvc_hb_interval'), $eff->('osvc_hb_timeout'));
        $err->($firstline->(qw(osvc_hb_timeout osvc_hb_interval)), "heartbeat timeout ($t) must be greater than interval ($i)")
            if $i =~ /^\d+\z/ && $t =~ /^\d+\z/ && $t <= $i;
    }
    if (grep { exists $given{$_} } qw(osvc_web_ui osvc_web_port osvc_listener_port)) {
        my ($ui, $w, $l) = ($eff->('osvc_web_ui'), $eff->('osvc_web_port'), $eff->('osvc_listener_port'));
        $err->($firstline->(qw(osvc_web_port osvc_listener_port osvc_web_ui)), 'web port cannot be the same as the listener port')
            if $ui eq 'yes' && $w eq $l;
    }

    # Derived keys: DHCP.
    my %derived;
    my @dhcp_given = grep { exists $given{$_} } qw(network_dhcp_cidr network_dhcp_ip network_cidr);
    if (@dhcp_given) {
        my $cidr = $eff->('network_dhcp_cidr');
        if (!defined $cidr || $cidr eq '' || validate_value($BY_KEY{network_dhcp_cidr}, $cidr)) {
            $err->($dhcp_given[0], 'derived from network_dhcp_cidr, which is not set to a valid value')
                unless exists $given{network_dhcp_cidr};
        }
        else {
            %derived = %{ derive_dhcp($cidr) };
            for my $k (qw(network_dhcp_ip network_cidr)) {
                $err->($k, "derived from network_dhcp_cidr: expected $derived{$k}, got $given{$k}")
                    if exists $given{$k} && $given{$k} ne $derived{$k};
            }
        }
    }

    # Static range and reserved addresses lie inside the DHCP network.
    if (grep { exists $given{$_} } qw(network_static_start network_static_end network_reserved network_dhcp_cidr)) {
        my $net = $derived{network_cidr} // $eff->('network_cidr');
        if (defined $net && $net =~ m{^([0-9.]+)/([0-9]+)\z} && _valid_ip($1)) {
            my ($nip, $p) = ($1, $2);
            my $mask = $p == 0 ? 0 : (0xFFFFFFFF << (32 - $p)) & 0xFFFFFFFF;
            my $nint = _ip_to_int($nip) & $mask;
            my $inside = sub ($ip) { return _valid_ip($ip) && (_ip_to_int($ip) & $mask) == $nint };
            for my $k (qw(network_static_start network_static_end)) {
                $err->($k, "$given{$k} is not inside $net")
                    if exists $given{$k} && length $given{$k} && !$inside->($given{$k});
            }
            if (exists $given{network_reserved}) {
                my @out = grep { !$inside->($_) } split /[,\s]+/, $given{network_reserved};
                $err->('network_reserved', "not inside $net: " . join(', ', @out)) if @out;
            }
        }
        my ($s, $en) = ($eff->('network_static_start'), $eff->('network_static_end'));
        $err->($firstline->(qw(network_static_start network_static_end)), "static range start $s is after end $en")
            if defined $s && defined $en && _valid_ip($s) && _valid_ip($en) && _ip_to_int($s) > _ip_to_int($en);
    }

    # Derived keys: storage networks.
    my @stor_given = grep { exists $given{$_} } (@STORAGE_INPUTS, grep { /^network_storage_vlan/ } keys %given);
    if (@stor_given) {
        my $count  = $eff->('network_storage_count');
        my $base   = $eff->('network_storage_base_vlan');
        my $prefix = $eff->('network_storage_subnet_cidr');
        my $sbase  = $eff->('network_storage_subnet_base');
        $sbase = "10.$base" if (!defined $sbase || $sbase eq '') && defined $base;
        my $dom    = $eff->('network_dns_domain');
        my $at     = $stor_given[0];
        my $ok = 1;
        for my $in (qw(network_storage_count network_storage_base_vlan network_storage_subnet_cidr)) {
            my $v = $eff->($in);
            $ok = 0 if !defined $v || validate_value($BY_KEY{$in}, $v);
        }
        if ($ok && defined $base && $base =~ /\A\d+\z/ && $base > 255 && (!defined $eff->('network_storage_subnet_base') || $eff->('network_storage_subnet_base') eq '')) {
            $err->($at, "network_storage_subnet_base must be set: the default 10.<base VLAN> needs a base VLAN of 255 or less (got $base)");
            $ok = 0;
        }
        $ok = 0 if !defined $sbase || validate_value($BY_KEY{network_storage_subnet_base}, $sbase);
        if ($ok && $count > 0 && (!defined $dom || $dom eq '')) {
            $err->($at, 'storage networks need network_dns_domain to be set');
            $ok = 0;
        }
        if ($ok) {
            my ($d, $e) = derive_storage($count, $base, $sbase, $prefix, $dom // '');
            if (defined $e) { $err->($firstline->(qw(network_storage_count network_storage_base_vlan network_storage_subnet_cidr)) // $at, $e) }
            else {
                %derived = (%derived, %$d);
                for my $k (grep { /^network_storage_vlan/ && !/_allocated\z/ } keys %given) {
                    if (!exists $d->{$k}) { $err->($k, 'outside the configured storage VLAN range') }
                    elsif ($given{$k} ne $d->{$k}) { $err->($k, "derived value is $d->{$k}, got $given{$k}") }
                }
                for my $k (grep { /^network_storage_vlan\d+_allocated\z/ } keys %given) {
                    (my $probe = $k) =~ s/_allocated\z/_subnet/;
                    $err->($k, 'outside the configured storage VLAN range') unless exists $d->{$probe};
                }
                # allocated is runtime state: initialised to false, never reset.
                for my $probe (grep { /_subnet\z/ } keys %$d) {
                    (my $a = $probe) =~ s/_subnet\z/_allocated/;
                    $derived{$a} = 'false';
                }
            }
        }
    }

    # The write set: given catalogued keys, then derived keys.
    my (@changes, @unchanged);
    my %want;
    $want{$_} = { new => $given{$_}, derived => 0 } for grep { $BY_KEY{$_} } keys %given;
    for my $k (keys %derived) {
        if ($k =~ /_allocated\z/) {
            my $cur = $stored->($k)->{v};
            my $new = exists $given{$k} ? $given{$k} : defined $cur ? $cur : $derived{$k};
            $want{$k} = { new => $new, derived => 1 };
        }
        else { $want{$k} = { new => $derived{$k}, derived => 1 } }
    }
    for my $k (sort { _key_order($a) <=> _key_order($b) || $a cmp $b } keys %want) {
        my $old = $stored->($k)->{v};
        my $new = $want{$k}{new};
        if (defined $old && $old eq $new) { push @unchanged, $k }
        else { push @changes, { key => $k, old => $old, new => $new, derived => $want{$k}{derived} ? JSON::PP::true : JSON::PP::false } }
    }

    # Required keys with no value once this would be applied.
    my @missing;
    for my $q (grep { $_->{required} } @CATALOGUE) {
        my $v = exists $given{ $q->{key} } ? $given{ $q->{key} } : $stored->( $q->{key} )->{v};
        push @missing, $q->{key} unless defined $v && length $v;
    }

    @errors = sort { $a->{line} <=> $b->{line} || ($a->{key} // '') cmp ($b->{key} // '') } @errors;
    return { errors => \@errors, changes => \@changes, unchanged => \@unchanged, missing_required => \@missing };
}

my %ORDER;
@ORDER{ map { $_->{key} } @CATALOGUE } = (1 .. @CATALOGUE);
sub _key_order ($k) { return $ORDER{$k} // 1000 }

# apply(\@entries, dry_run => 0|1): plan, and unless the plan has errors or
# this is a dry run, write each changed key once. Returns the plan plus
# { ok, dry_run, cluster }.
sub apply ($self, $entries, %opt) {
    my $plan = $self->plan($entries);
    my $c    = $self->cluster;
    $plan->{cluster} = $c;
    $plan->{dry_run} = $opt{dry_run} ? JSON::PP::true : JSON::PP::false;
    $plan->{ok}      = @{ $plan->{errors} } ? JSON::PP::false : JSON::PP::true;
    return $plan if @{ $plan->{errors} } || $opt{dry_run};
    for my $ch (@{ $plan->{changes} }) {
        $self->{registry}->cluster_set($c, $ch->{key}, $ch->{new});
        $self->_log('info', "cluster $c: Set: $ch->{key}=$ch->{new}" . ($ch->{derived} ? ' (derived)' : ''));
    }
    $self->_log('info', "cluster $c: applied " . scalar(@{ $plan->{changes} }) . ' change(s), '
        . scalar(@{ $plan->{unchanged} }) . ' unchanged');
    return $plan;
}

sub set ($self, $key, $value, %opt) {
    return $self->apply([ { key => $key, value => $value, line => 0 } ], %opt);
}

#--- show / export ---------------------------------------------------------------------

# Current values: { cluster, keys => [{key,group,value,set,missing_required}],
#   derived => [{key,value}], other => [{key,value}] }.
sub show ($self) {
    my $c   = $self->_checked_cluster;
    my $reg = $self->{registry};
    my %have = map { $_ => 1 } $reg->cluster_list($c);
    my (@keys, @derived, @other);
    for my $q (@CATALOGUE) {
        my $v = $have{ $q->{key} } ? normalise_value($q->{key}, scalar $reg->cluster_get($c, $q->{key})) : undef;
        push @keys, {
            key => $q->{key}, group => $q->{group}, value => $v, set => defined $v ? JSON::PP::true : JSON::PP::false,
            missing_required => ($q->{required} && !(defined $v && length $v)) ? JSON::PP::true : JSON::PP::false,
        };
        delete $have{ $q->{key} };
    }
    for my $k (sort { $a cmp $b } keys %have) {
        my $row = { key => $k, value => scalar $reg->cluster_get($c, $k) };
        if (is_derived_key($k)) { push @derived, $row } else { push @other, $row }
    }
    return { cluster => $c, keys => \@keys, derived => \@derived, other => \@other };
}

# The configuration in the apply format, a prompt comment above each key.
# Unset keys appear commented out with their default. Derived keys are left
# out: apply recomputes them.
sub export_text ($self) {
    my $s = $self->show;
    my %row = map { $_->{key} => $_ } @{ $s->{keys} };
    my $out = "# Cluster configuration for $s->{cluster}: key = value, no quoting.\n"
        . "# Apply with: hps-cluster-config apply FILE\n";
    my $group = '';
    for my $q (@CATALOGUE) {
        my $r = $row{ $q->{key} };
        if ($q->{group} ne $group) { $group = $q->{group}; $out .= "\n# [$group]\n" }
        $out .= "# $q->{prompt}" . ($q->{required} ? ' (required)' : '') . "\n";
        if ($r->{set}) { $out .= "$q->{key} = $r->{value}\n" }
        else {
            my $d = $q->{default} // '';
            $out .= "# $q->{key} = $d\n";
        }
    }
    return $out;
}

sub export_data ($self) {
    my $s = $self->show;
    return { map {
        my $v = $_->{value};
        if ($_->{key} eq 'network_layout') {
            my $d = eval { JSON::PP->new->decode($v) };
            $v = $d if ref $d eq 'HASH';
        }
        ($_->{key} => $v);
    } grep { $_->{set} } @{ $s->{keys} } };
}

1;
