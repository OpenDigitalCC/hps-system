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
#   bool            true or false
#   ip              dotted-quad IPv4 address
#   cidr            IPv4 address with /prefix
#   host            IPv4 address or host name
#   dnsdomain       DNS domain, labels of at most 63 characters
#   subnet_base     X.Y, the first two octets of the storage subnets
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

    _q(key => 'network_storage_count', group => 'storage-networks',
        prompt => 'Number of storage networks to configure (1-10)', rule => 'int:0..10', default => '2',
        derives => ['network_storage_vlanN_*']),
    _q(key => 'network_storage_base_vlan', group => 'storage-networks',
        prompt => 'Storage network base VLAN ID (31-99)', rule => 'int:31..99', default => '31',
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
        return (grep { length($_) > 63 } split /\./, $v) ? 'a label is longer than 63 characters' : undef;
    }
    if ($kind eq 'subnet_base') {
        my ($a, $b) = $v =~ /^([0-9]{1,3})\.([0-9]{1,3})\z/;
        return 'must be X.Y, such as 10.31' unless defined $a && $a <= 255 && $b <= 255;
        return undef;
    }
    die "Unknown rule '$q->{rule}' for $q->{key}\n";
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
    return (undef, "VLAN range would exceed 99 (max would be $max)") if $max > 99;
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
    my $stored = sub ($k) { return $stored{$k} //= { v => scalar $reg->cluster_get($c, $k) } };
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
        $self->_log('info', "cluster $c: set $ch->{key} (" . ($ch->{derived} ? 'derived' : 'given') . ')');
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
        my $v = $have{ $q->{key} } ? $reg->cluster_get($c, $q->{key}) : undef;
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
    return { map { $_->{key} => $_->{value} } grep { $_->{set} } @{ $s->{keys} } };
}

1;
