package HPS::Registry::Keys;
# The registry key catalogue: one table, one row per key (or key pattern) the
# code writes. docs/REGISTRY-KEYS.md is generated from it (bin/hps-registry-keys
# --markdown); t/83-registry-keys.t fails when code writes a key that is not
# here, or the document is out of date.
#
# A name with <placeholders> is a pattern: every <...> stands for one or more
# characters of the key (<n> a number, <name> a workload name, ...).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

# type => what a value of that type is (the registry file is plain JSON; a
# boolean-looking name never holds anything but these forms).
my @TYPES = (
    [ bool    => 'true or false (JSON booleans or the strings true/false), or 1/0' ],
    [ epoch   => 'Unix time in whole seconds, digits only (e.g. 1794321826)' ],
    [ iso8601 => 'ISO 8601 date-time with offset (date -Iseconds)' ],
    [ stamp   => 'UTC date-time text, "YYYY-MM-DD HH:MM:SS UTC"' ],
    [ string  => 'free text; the meaning column lists the values where they are a fixed set' ],
    [ json    => 'a JSON object or array' ],
    [ pin     => 'a NixOS system pin: a store path or name chosen by hps-onboard, never empty' ],
    [ mac     => 'a MAC address, 12 lower-case hex digits' ],
    [ int     => 'a whole number' ],
    [ ip      => 'an IPv4 address' ],
    [ cidr    => 'IPv4 address or network with prefix length, a.b.c.d/n' ],
);

# [ name, scope, type, writer, meaning ] (a sixth element, when present, marks
# the key as kept for compatibility and says what replaces it)
my @KEYS = (
    # --- system
    [ 'ACTIVE_CLUSTER', 'system', 'string', 'set_active_cluster (cluster-bootstrap, cluster-configure)', 'Name of the cluster every host and cluster command acts on.' ],

    # --- host
    [ 'STATE', 'host', 'string', 'boot_manager, ipxe menu, host initialisation, hps-onboard', 'Provisioning state: UNCONFIGURED, CONFIGURED, INSTALLING, NETWORK_BOOT, REINSTALL, UNMANAGED, HELD.' ],
    [ 'UPDATED', 'host', 'stamp', 'every host write (host_registry, HPS::Registry::host_set)', 'When any key of this host last changed.' ],
    [ 'TYPE', 'host', 'string', 'host initialisation, ipxe menu, hps-onboard', 'Node type (for example TCH, SCH, NIXOS).' ],
    [ 'HOST_PROFILE', 'host', 'string', 'ipxe menu, hps-onboard', 'Profile chosen for the node.' ],
    [ 'PROFILE', 'host', 'string', 'hps-onboard', 'Same profile name as HOST_PROFILE, written alongside it.' ],
    [ 'os_id', 'host', 'string', 'ipxe menu, hps-onboard', 'Operating system id arch:name:version the node boots.' ],
    [ 'FORCE_INSTALL', 'host', 'string', 'ipxe menu', 'YES or NO: reinstall at next boot. Upper-case words, not a bool.' ],
    [ 'HOSTNAME', 'host', 'string', 'host initialisation', 'Host name allocated to the node.' ],
    [ 'IP', 'host', 'ip', 'host initialisation', 'Address allocated to the node.' ],
    [ 'NETMASK', 'host', 'ip', 'host initialisation', 'Netmask allocated to the node.' ],
    [ 'arch', 'host', 'string', 'host initialisation', 'CPU architecture the node reported at first boot.' ],
    [ 'initialised_at', 'host', 'iso8601', 'host initialisation', 'When the host registry entry was created.' ],
    [ 'assigned_at', 'host', 'stamp', 'hps-onboard', 'When the node was assigned its profile and pin.' ],
    [ 'last_boot_at', 'host', 'epoch', 'ipxe menu', 'When the node was last issued a boot script (ADR 0002 check 3).' ],
    [ 'ctrl_exec_paired_at', 'host', 'epoch', 'ce_approve_pair_request (ctrl-exec pairing approver)', 'When the node paired with ctrl-exec. Present means paired; removed when the pairing window is reopened for a boot.' ],
    [ 'ctrl_exec_paired', 'host', 'epoch', 'ce_approve_pair_request', 'Compatibility copy of ctrl_exec_paired_at (same epoch value; the name reads as a boolean, it is not one). Kept one release; read ctrl_exec_paired_at.', 'ctrl_exec_paired_at' ],
    [ 'system_pin', 'host', 'pin', 'hps-onboard (assign, repin)', 'The NixOS system the node boots.' ],
    [ 'system_pin_previous', 'host', 'pin', 'hps-onboard repin', 'The pin before the last repin, for rollback.' ],
    [ 'repinned_at', 'host', 'stamp', 'hps-onboard repin', 'When the pin last changed.' ],
    [ 'nets', 'host', 'json', 'hps-onboard, HPS::Workload', 'Array of network names the node attaches to.' ],
    [ 'audit', 'host', 'json', 'node_audit CGI (host_audit_store)', 'The hps-audit/1 document the node uploaded.' ],
    [ 'init_result', 'host', 'json', 'host_init_intake (boot_manager cmd=host_init_result)', 'The node\'s last init sequence: boot_id, pin, times, steps with rc, seconds and message (IPS-02).' ],
    [ 'init_result_prev', 'host', 'json', 'host_init_intake', 'The init result of the boot before the last one.' ],
    [ 'init_ok', 'host', 'bool', 'host_init_intake', 'True when every step of the last init sequence exited 0.' ],
    [ 'audit_at', 'host', 'stamp', 'node_audit CGI', 'When the audit was stored.' ],
    [ 'storage_note', 'host', 'string', 'hps-onboard', 'Operator note about the node storage plan.' ],
    [ 'poweroff_last', 'host', 'json', 'HPS::Node', 'Outcome of the last hps-node power-off: result (off, forced, no-bmc, failed), at, detail.' ],
    [ 'storage_last', 'host', 'json', 'HPS::Storage', 'Outcome of the last storage operation: op, ok, at.' ],
    [ 'storage_pool', 'host', 'string', 'HPS::Storage', 'Name of the pool created on the node.' ],
    [ 'storage_created_at', 'host', 'stamp', 'HPS::Storage', 'When the pool was created.' ],
    [ 'storage_exports', 'host', 'json', 'HPS::Storage', 'Array of iSCSI exports: zvol, iqn, initiator, portal.' ],
    [ 'storage_state', 'host', 'string', 'HPS::Storage', 'up or down.' ],
    [ 'storage_up_at', 'host', 'stamp', 'HPS::Storage', 'When storage last came up.' ],
    [ 'storage_down_at', 'host', 'stamp', 'HPS::Storage', 'When storage last went down.' ],
    [ 'storage_trim_at', 'host', 'stamp', 'HPS::Storage', 'When the TRIM check last ran.' ],
    [ 'storage_trim_verdict', 'host', 'string', 'HPS::Storage', 'Text verdict of the TRIM check (TRIM OK or the failure).' ],
    [ 'storage_trim_ok', 'host', 'bool', 'HPS::Storage', '1 when the TRIM check passed, else 0.' ],
    [ 'storage<n>_vlan', 'host', 'int', 'network-functions (storage address allocation)', 'VLAN id of storage network n on this node.' ],
    [ 'storage<n>_ip', 'host', 'ip', 'network-functions', 'Address of the node on storage network n.' ],
    [ 'approval_<action>_<pool>', 'host', 'json', 'HPS::Approval (hps-approve)', 'A signed human approval for one destructive action on one pool or workload; pool slashes appear as __.' ],
    [ '<prefix>_timestamp', 'host', 'epoch', 'process_host_audit (host data collection)', 'When the data collection named by the prefix last ran.' ],
    [ '<prefix>_count', 'host', 'int', 'process_host_audit', 'Number of fields that collection stored.' ],

    # --- cluster
    [ 'CLUSTER_NAME', 'cluster', 'string', 'cluster initialisation', 'The cluster name.' ],
    [ 'CREATED', 'cluster', 'iso8601', 'cluster initialisation', 'When the cluster was created.' ],
    [ 'STATUS', 'cluster', 'string', 'cluster initialisation', 'Cluster status (initialized).' ],
    [ 'DESCRIPTION', 'cluster', 'string', 'hps-cluster-config', 'Descriptive name of the cluster.' ],
    [ 'network_dns_domain', 'cluster', 'string', 'hps-cluster-config', 'DNS domain of the cluster.' ],
    [ 'network_dhcp_enabled', 'cluster', 'bool', 'hps-cluster-config', 'Whether the IPS serves DHCP.' ],
    [ 'network_dhcp_iface', 'cluster', 'string', 'hps-cluster-config', 'Interface the IPS listens on for boot requests.' ],
    [ 'network_dhcp_cidr', 'cluster', 'cidr', 'hps-cluster-config', 'Address of the DHCP interface with prefix; network_dhcp_ip and network_cidr derive from it.' ],
    [ 'network_dhcp_ip', 'cluster', 'ip', 'hps-cluster-config (derived)', 'The IPS address.' ],
    [ 'network_cidr', 'cluster', 'cidr', 'hps-cluster-config (derived)', 'The network of the DHCP interface.' ],
    [ 'network_dhcp_rangesize', 'cluster', 'int', 'hps-cluster-config', 'Number of addresses in the DHCP range.' ],
    [ 'network_dhcp_range_start', 'cluster', 'ip', 'hps-cluster-config', 'First DHCP address; empty means derived from the range size.' ],
    [ 'network_dhcp_range_end', 'cluster', 'ip', 'hps-cluster-config', 'Last DHCP address; empty means derived from the range size.' ],
    [ 'network_static_start', 'cluster', 'ip', 'hps-cluster-config', 'First address of the static range.' ],
    [ 'network_static_end', 'cluster', 'ip', 'hps-cluster-config', 'Last address of the static range.' ],
    [ 'network_reserved', 'cluster', 'string', 'hps-cluster-config', 'Reserved IPv4 addresses, comma or space separated; may be empty.' ],
    [ 'network_storage_count', 'cluster', 'int', 'hps-cluster-config, cluster-interactive-functions', 'Number of storage networks (0 to 10).' ],
    [ 'network_storage_base_vlan', 'cluster', 'int', 'hps-cluster-config, cluster-interactive-functions', 'VLAN id of the first storage network.' ],
    [ 'network_storage_subnet_base', 'cluster', 'string', 'hps-cluster-config, cluster-interactive-functions', 'Subnet base (leading octets) the storage subnets are cut from.' ],
    [ 'network_storage_subnet_cidr', 'cluster', 'int', 'hps-cluster-config, cluster-interactive-functions', 'Prefix length of each storage subnet.' ],
    [ 'network_storage_mtu', 'cluster', 'int', 'hps-cluster-config, cluster-interactive-functions', 'MTU of the storage networks: 1500 or 9000.' ],
    [ 'network_storage_vlan<n>_subnet', 'cluster', 'string', 'hps-cluster-config, cluster-interactive-functions', 'Subnet of storage network n.' ],
    [ 'network_storage_vlan<n>_gateway', 'cluster', 'ip', 'hps-cluster-config, cluster-interactive-functions', 'Gateway of storage network n.' ],
    [ 'network_storage_vlan<n>_netmask', 'cluster', 'ip', 'hps-cluster-config, cluster-interactive-functions', 'Netmask of storage network n.' ],
    [ 'network_storage_vlan<n>_domain', 'cluster', 'string', 'hps-cluster-config, cluster-interactive-functions', 'DNS domain of storage network n.' ],
    [ 'network_storage_vlan<n>_allocated', 'cluster', 'bool', 'hps-cluster-config, cluster-interactive-functions, host storage allocation', 'Whether storage network n has been handed out.' ],
    [ 'network_syslog_server', 'cluster', 'ip', 'hps-cluster-config', 'Syslog server address.' ],
    [ 'network_name_server', 'cluster', 'ip', 'hps-cluster-config', 'DNS server address.' ],
    [ 'network_time_server', 'cluster', 'string', 'hps-cluster-config', 'NTP server address or name the nodes use.' ],
    [ 'network_time_upstream', 'cluster', 'string', 'hps-cluster-config', 'Upstream time servers for the IPS, comma or space separated; may be empty.' ],
    [ 'network_layout', 'cluster', 'json', 'hps-cluster-config, cluster-bootstrap', 'Workload network layout, one JSON object.' ],
    [ 'osvc_log_level', 'cluster', 'string', 'hps-cluster-config', 'OpenSVC log level: debug, info, warn, error.' ],
    [ 'osvc_listener_port', 'cluster', 'int', 'hps-cluster-config', 'OpenSVC listener port.' ],
    [ 'osvc_web_ui', 'cluster', 'string', 'hps-cluster-config', 'yes or no: enable the OpenSVC web UI. Words, not a bool.' ],
    [ 'osvc_web_port', 'cluster', 'int', 'hps-cluster-config', 'OpenSVC web UI port.' ],
    [ 'osvc_hb_interval', 'cluster', 'int', 'hps-cluster-config', 'Heartbeat interval in seconds.' ],
    [ 'osvc_hb_timeout', 'cluster', 'int', 'hps-cluster-config', 'Heartbeat timeout in seconds.' ],
    [ 'osvc_templates_url', 'cluster', 'string', 'hps-cluster-config', 'OpenSVC templates URL; may be empty.' ],
    [ 'osvc_packages_url', 'cluster', 'string', 'hps-cluster-config', 'OpenSVC packages URL; may be empty.' ],
    [ 'osvc_hb_type', 'cluster', 'string', 'hps-cluster-config', 'Heartbeat type: multicast or unicast.' ],
    [ 'OPENSVC_AGENT_KEY', 'cluster', 'string', 'opensvc-function-helpers', 'Secret: the OpenSVC agent key. Never logged or put in an image.' ],
    [ 'OPENSVC_CLUSTER_SECRET', 'cluster', 'string', 'opensvc-function-helpers', 'Secret: the OpenSVC cluster secret. Never logged or put in an image.' ],
    [ 'nixos_default_pin', 'cluster', 'pin', 'operator (hps-cluster-config or the API); read by the iPXE menu', 'The pin a NixOS node boots when it has no pin of its own.' ],
    [ 'workload_<name>', 'cluster', 'json', 'HPS::Workload (create, start, stop; removed by destroy)', 'Instance record of a workload: state, VMs, disks, macs, created_at, by.' ],
    [ 'workload_<name>_destroyed', 'cluster', 'json', 'HPS::Workload destroy (removed by the next create)', 'Audit record of a destroyed workload: at (when), by (who). The definition file workloads/<name>.json is kept.' ],
);

# Writers whose key is chosen at run time by the caller, so no row can name it.
# They carry the keys above; a key written only through one of these is not
# catalogued and must not be relied on.
my @FREE_FORM = (
    [ 'http/api/api.sh', 'host and cluster registry set and unset through the API: the caller names the key.' ],
    [ 'http/cgi-bin/boot_manager.sh', 'host_variable set and unset (refused with 403 over CGI; kept for the legacy node-manager protocol).' ],
    [ 'lib/functions.d/host-functions.sh', 'host data collection: <prefix>_<field> for each field of the collection.' ],
    [ 'lib/functions.d/os-functions.sh', 'OS registry keys (os.db) are configured by the OS tooling, not catalogued here.' ],
);

sub types () { return map { { name => $_->[0], meaning => $_->[1] } } @TYPES }

sub keys_table () {
    return map {
        { name => $_->[0], scope => $_->[1], type => $_->[2], writer => $_->[3],
          meaning => $_->[4], (defined $_->[5] ? (replaced_by => $_->[5]) : ()) }
    } @KEYS;
}

sub free_form () { return map { { file => $_->[0], meaning => $_->[1] } } @FREE_FORM }

# Shape of a name for matching: every <placeholder> becomes <>.
sub shape ($name) { (my $s = $name) =~ s/<[^<>]*>/<>/g; return $s }

# lookup($scope, $key): the row for a concrete key name (or a pattern as
# written in code), or undef. An exact name wins over a pattern.
sub lookup ($scope, $key) {
    my @rows = grep { $_->{scope} eq $scope } keys_table();
    for my $r (@rows) { return $r if $r->{name} eq $key }
    my $shape = shape($key);
    for my $r (@rows) { return $r if shape($r->{name}) eq $shape }
    for my $r (grep { $_->{name} =~ /</ } @rows) {
        (my $re = quotemeta($r->{name})) =~ s/\\<[^>]*?\\>/.+/g;
        return $r if $key =~ /\A$re\z/;
    }
    return undef;
}

sub type_of ($scope, $key) {
    my $r = lookup($scope, $key);
    return $r ? $r->{type} : undef;
}

# The type check shared by the typed accessors: value ok for type?
my %CHECK = (
    bool  => sub { $_[0] =~ /\A(?:true|false|1|0)\z/ },
    epoch => sub { $_[0] =~ /\A[0-9]{1,12}\z/ },
    int   => sub { $_[0] =~ /\A-?[0-9]+\z/ },
    mac   => sub { $_[0] =~ /\A[0-9a-f]{12}\z/ },
);

sub valid ($type, $value) {
    my $c = $CHECK{$type} or return 1;
    return defined $value && $c->($value) ? 1 : 0;
}

sub render_markdown () {
    my @t = types();
    my $o = "# Registry keys\n\n"
        . "Generated from `lib/perl/HPS/Registry/Keys.pm` by `bin/hps-registry-keys --markdown`; do not edit by hand.\n"
        . "A name in angle brackets is a pattern: `<n>` stands for a number, `<name>` for a workload name.\n\n"
        . "## Types\n\n| Type | A value of this type is |\n|---|---|\n"
        . join('', map { "| `$_->{name}` | $_->{meaning} |\n" } @t) . "\n";
    for my $scope (qw(system host cluster)) {
        $o .= "## " . ucfirst($scope) . " keys\n\n| Key | Type | Written by | Meaning |\n|---|---|---|---|\n";
        for my $r (grep { $_->{scope} eq $scope } keys_table()) {
            my $m = $r->{meaning};
            $m = "Deprecated, replaced by `$r->{replaced_by}`. $m" if $r->{replaced_by};
            $o .= "| `$r->{name}` | `$r->{type}` | $r->{writer} | $m |\n";
        }
        $o .= "\n";
    }
    $o .= "## Free-form writers\n\nThese write keys chosen by the caller at run time, so no row above can name them.\n\n"
        . "| File | What it writes |\n|---|---|\n"
        . join('', map { "| `$_->{file}` | $_->{meaning} |\n" } free_form()) . "\n";
    $o .= "## Rules\n\n"
        . "- A key holds one type, the one in this table. A boolean-looking name never holds a timestamp.\n"
        . "- Readers use the typed accessors (`host_get_bool`, `host_get_epoch`), which refuse a value of the wrong type and name the key.\n"
        . "- A key is renamed only with a compatibility window: the old key keeps being written for one release and is marked deprecated here.\n"
        . "- Adding a key means adding its row; `t/83-registry-keys.t` fails when code writes a key that has none.\n";
    return $o;
}

1;
