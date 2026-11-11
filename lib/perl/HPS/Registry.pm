package HPS::Registry;
# Perl access to the HPS JSON registry. Same on-disk layout and lock
# protocol as lib/hps-registry.sh (the Bash code stays a writer too):
#   <db>/<KEY>.json            one JSON document per key
#   <db>/.lock/<KEY>.lock      "ts:/pid:/op:/host:" lines; stale if pid is gone
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use JSON::PP;
use Sys::Hostname qw(hostname);
use Time::HiRes qw(sleep);
use POSIX qw(strftime);
use HPS::Registry::Keys;

my $KEY_RE = qr/^[A-Za-z0-9_-]+$/;

# new(%opt): config_base, system_registry (db dir), lock_timeout (seconds).
# Defaults come from HPS_CONFIG_BASE / HPS_SYSTEM_REGISTRY like
# hps_get_config; HPS_CONFIG_BASE defaults to /srv/hps-config (as in Bash) and
# HPS_SYSTEM_REGISTRY to /srv/hps-config/system.db.
sub new ($class, %opt) {
    my $self = {
        config_base     => $opt{config_base}     // $ENV{HPS_CONFIG_BASE} // '/srv/hps-config',
        system_registry => $opt{system_registry} // $ENV{HPS_SYSTEM_REGISTRY}
                           // '/srv/hps-config/system.db',
        lock_timeout    => $opt{lock_timeout} // 5,
    };
    # One group (hps) owns IPS state: files group-writable, see lib/hps-state.sh.
    umask 002;
    return bless $self, $class;
}

sub config_base ($self) {
    my $b = $self->{config_base};
    die "HPS_CONFIG_BASE is not set\n" unless defined $b && length $b;
    return $b;
}

sub timestamp ($self) { return strftime('%Y-%m-%d %H:%M:%S UTC', gmtime) }

#--- generic key store (one directory, one file per key) --------------------

sub _check_key ($key) {
    die "Invalid key format: " . ($key // '') . "\n"
        unless defined $key && $key =~ $KEY_RE;
    return $key;
}

sub _slurp ($file) {
    open(my $fh, '<:raw', $file) or die "Cannot read $file: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub _lock_pid ($lock) {
    open(my $fh, '<', $lock) or return;
    local $/;
    my $info = <$fh>;
    close $fh;
    return unless defined $info && $info =~ /pid:(\d+)/;
    return $1;
}

sub _pid_alive ($pid) {
    return 1 if kill(0, $pid);
    return $!{EPERM} ? 1 : 0;
}

# Same protocol as acquire_lock: wait while the lock file exists, remove it
# if its pid is dead, then write ts/pid/op/host. Creation uses O_EXCL so two
# Perl writers cannot both win (the Bash check-then-create has a race).
sub _acquire ($self, $lock, $op) {
    my $polls    = int($self->{lock_timeout} * 10);
    for (my $n = 0 ; $n <= $polls ; $n++) {
        if (-e $lock) {
            my $pid = _lock_pid($lock);
            if (defined $pid && !_pid_alive($pid)) {
                unlink $lock;
                next;
            }
        }
        elsif (sysopen(my $fh, $lock, O_WRONLY | O_CREAT | O_EXCL)) {
            printf {$fh} "ts:%d\npid:%d\nop:%s\nhost:%s\n", time, $$, $op, hostname();
            close $fh;
            return 1;
        }
        sleep 0.1;
    }
    return 0;
}

sub _release ($lock) { unlink $lock; return 1 }

sub _db_get ($db, $key) {
    _check_key($key);
    my $file = "$db/$key.json";
    return undef unless -f $file;
    my $text = _slurp($file);
    my $data = eval { JSON::PP->new->utf8->allow_nonref->decode($text) };
    die "Corrupted JSON in $file\n" if $@;
    # Raw mode like jq -r: strings lose their quotes, the rest is as stored.
    return $data if !ref $data && $text =~ /^\s*"/;
    $text =~ s/\s+\z//;
    return $text;
}

sub _db_get_json ($db, $key) {
    _check_key($key);
    my $file = "$db/$key.json";
    return undef unless -f $file;
    my $data = eval { JSON::PP->new->utf8->allow_nonref->decode(_slurp($file)) };
    die "Corrupted JSON in $file\n" if $@;
    return $data;
}

# Like the Bash wrappers: a value that is valid JSON is stored as JSON,
# anything else is stored as a JSON string. A reference is encoded as JSON.
sub _encode_value ($value) {
    my $pretty = JSON::PP->new->utf8->canonical->pretty->indent_length(2)->allow_nonref;
    return $pretty->encode($value) if ref $value;
    $value //= '';
    my $data = eval { JSON::PP->new->allow_nonref->decode($value) };
    if (!$@) {
        return $pretty->encode($data) if ref $data;
        (my $t = $value) =~ s/^\s+|\s+\z//g;
        utf8::encode($t);
        return "$t\n";
    }
    return $pretty->encode("$value");
}

sub _db_set ($self, $db, $key, $value) {
    _check_key($key);
    my $body = _encode_value($value);
    mkdir_p("$db/.lock");
    my $lock = "$db/.lock/$key.lock";
    $self->_acquire($lock, 'write') or die "Cannot acquire lock for $key\n";
    my $file = "$db/$key.json";
    my $tmp  = "$file.$$.tmp";
    my $ok   = eval {
        open(my $fh, '>:raw', $tmp) or die "Cannot write $tmp: $!\n";
        print {$fh} $body;
        close $fh or die "Cannot close $tmp: $!\n";
        rename $tmp, $file or die "Cannot rename $tmp: $!\n";
        1;
    };
    my $err = $@;
    unlink $tmp if !$ok;
    _release($lock);
    die $err unless $ok;
    return 1;
}

sub _db_unset ($self, $db, $key) {
    _check_key($key);
    my $file = "$db/$key.json";
    return 1 unless -f $file;
    mkdir_p("$db/.lock");
    my $lock = "$db/.lock/$key.lock";
    $self->_acquire($lock, 'write') or die "Cannot acquire lock for $key\n";
    unlink $file;
    _release($lock);
    return 1;
}

sub _db_exists ($db, $key) {
    _check_key($key);
    return -f "$db/$key.json" ? 1 : 0;
}

sub _db_list ($db) {
    opendir(my $dh, $db) or return ();
    my @keys = sort map { /^(.+)\.json\z/ ? $1 : () } grep { -f "$db/$_" } readdir $dh;
    closedir $dh;
    return @keys;
}

sub _subdirs ($dir, $suffix) {
    opendir(my $dh, $dir) or return ();
    my @names = sort map { /^(.+)\Q$suffix\E\z/ ? $1 : () } grep { -d "$dir/$_" } readdir $dh;
    closedir $dh;
    return @names;
}

# Every directory created gets g+s, and group hps when running as root and the
# group exists (best effort, never fatal). keysafe/ is not created here: it is
# root-only and outside the shared group.
sub mkdir_p ($dir) {
    require File::Path;
    my @made = File::Path::make_path($dir);
    my $gid = ($> == 0) ? getgrnam('hps') : undef;
    for my $d (@made) {
        chmod((stat $d)[2] & 07777 | 02000, $d);
        chown(-1, $gid, $d) if defined $gid;
    }
    return 1;
}

#--- system ------------------------------------------------------------------

sub system_base ($self) { return $self->{system_registry} }
sub system_get ($self, $key)    { return _db_get($self->{system_registry}, $key) }
sub system_get_json ($self, $key) { return _db_get_json($self->{system_registry}, $key) }
sub system_set ($self, $key, $v) { return $self->_db_set($self->{system_registry}, $key, $v) }
sub system_exists ($self, $key) { return _db_exists($self->{system_registry}, $key) }
sub system_unset ($self, $key)  { return $self->_db_unset($self->{system_registry}, $key) }
sub system_list ($self)         { return _db_list($self->{system_registry}) }

sub active_cluster ($self) {
    my $c = $self->system_get('ACTIVE_CLUSTER');
    die "No ACTIVE_CLUSTER in the system registry\n" unless defined $c && length $c;
    return $c;
}

#--- cluster -----------------------------------------------------------------

sub _check_cluster ($name) {
    die "Invalid cluster name format: " . ($name // '') . "\n"
        unless defined $name && $name =~ $KEY_RE;
    return $name;
}

sub cluster_dir ($self, $name) {
    return $self->config_base . '/clusters/' . _check_cluster($name);
}

sub _cluster_db ($self, $name) { return $self->cluster_dir($name) . '/cluster.db' }

sub cluster_exists ($self, $name, $key = undef) {
    my $db = $self->_cluster_db($name);
    return defined $key && length $key ? _db_exists($db, $key) : (-d $db ? 1 : 0);
}

sub _cluster_checked ($self, $name) {
    die "Cluster not found: $name\n" unless -d $self->cluster_dir($name);
    return $self->_cluster_db($name);
}

sub cluster_get ($self, $name, $key)  { return _db_get($self->_cluster_checked($name), $key) }
sub cluster_get_json ($self, $name, $key) { return _db_get_json($self->_cluster_checked($name), $key) }
sub cluster_set ($self, $name, $key, $v) { return $self->_db_set($self->_cluster_checked($name), $key, $v) }
sub cluster_unset ($self, $name, $key) { return $self->_db_unset($self->_cluster_checked($name), $key) }
sub cluster_list ($self, $name)       { return _db_list($self->_cluster_checked($name)) }

# workload_dir($cluster): <cluster dir>/workloads, one <name>.json definition per
# workload (HPS::Workload); the active cluster when no name is given.
sub workload_dir ($self, $cluster = undef) {
    return $self->cluster_dir($cluster // $self->active_cluster) . '/workloads';
}

sub cluster_list_all ($self) {
    my $dir = $self->config_base . '/clusters';
    return grep { -d "$dir/$_/cluster.db" } _subdirs($dir, '');
}

#--- host (active cluster) -----------------------------------------------------

# Same rules as normalise_mac: strip : - . and spaces, lower-case, 12 hex.
sub normalise_mac ($mac) {
    my $m = lc($mac // '');
    $m =~ tr/:.\- //d;
    die "Invalid MAC address format: " . ($mac // '') . "\n" unless $m =~ /^[0-9a-f]{12}$/;
    return $m;
}

sub hosts_dir ($self) {
    return $self->cluster_dir($self->active_cluster) . '/hosts';
}

sub _host_db ($self, $mac) { return $self->hosts_dir . '/' . normalise_mac($mac) . '.db' }

sub host_exists ($self, $mac, $key = undef) {
    my $db = $self->_host_db($mac);
    return defined $key && length $key ? _db_exists($db, $key) : (-d $db ? 1 : 0);
}

sub host_get ($self, $mac, $key)      { return _db_get($self->_host_db($mac), $key) }
sub host_get_json ($self, $mac, $key) { return _db_get_json($self->_host_db($mac), $key) }
sub host_unset ($self, $mac, $key)    { return $self->_db_unset($self->_host_db($mac), $key) }
sub host_list ($self, $mac)           { return _db_list($self->_host_db($mac)) }

# Also stamps UPDATED, as host_registry set does (a timestamp string such as
# "2026-11-09 10:00:00 UTC", not an epoch number).
sub host_set ($self, $mac, $key, $v) {
    my $db = $self->_host_db($mac);
    $self->_db_set($db, $key, $v);
    $self->_db_set($db, 'UPDATED', $self->timestamp);
    return 1;
}

#--- typed host accessors ----------------------------------------------------------
# Refuse, naming the key, a value that is not of the type asked for, and a key the
# catalogue (HPS::Registry::Keys) declares as another type. undef when unset.

sub _typed ($self, $mac, $key, $type) {
    my $declared = HPS::Registry::Keys::type_of('host', $key);
    die "Registry key '$key' is declared $declared, not $type\n"
        if defined $declared && $declared ne $type;
    my $v = $self->host_get($mac, $key);
    return undef unless defined $v;
    (my $t = $v) =~ s/\A"|"\z//g;
    die "Registry key '$key' holds '$v', which is not $type\n"
        unless HPS::Registry::Keys::valid($type, $t);
    return $t;
}

# 1 or 0 from true/false/1/0.
sub host_get_bool ($self, $mac, $key) {
    my $v = $self->_typed($mac, $key, 'bool');
    return undef unless defined $v;
    return $v eq 'true' || $v eq '1' ? 1 : 0;
}

# Unix time in seconds, as an integer.
sub host_get_epoch ($self, $mac, $key) {
    my $v = $self->_typed($mac, $key, 'epoch');
    return defined $v ? $v + 0 : undef;
}

sub host_list_all ($self) { return _subdirs($self->hosts_dir, '.db') }

#--- the MAC index (IPS-15) ------------------------------------------------------------
# A host is stored under the MAC it first booted from (hosts/<mac>.db, the host
# key). The host key `macs` lists every physical NIC MAC the audit found:
# [{mac, ifname, driver, speed}]. The MAC index maps each of those MACs, and each
# host key, to its host. It is computed from the registry on every call (a scan of
# the hosts, a few dozen at most) and never stored, so forgetting a host frees its
# MACs and nothing can go stale. No caller reads hosts/<mac>.db from a raw MAC:
# resolve_mac turns any known MAC into its host key first.

# host_macs($key): the MACs of one host as 12-hex strings, the host key first,
# then its recorded `macs` in order, no repeats. Empty list when no such host.
sub host_macs ($self, $key) {
    my $k = normalise_mac($key);
    return () unless -d $self->_host_db($k);
    my @out = ($k);
    my $macs = $self->host_exists($k, 'macs') ? $self->host_get_json($k, 'macs') : undef;
    if (ref $macs eq 'ARRAY') {
        for my $e (@$macs) {
            my $m = ref $e eq 'HASH' ? $e->{mac} : $e;
            $m = eval { normalise_mac($m) };
            push @out, $m if defined $m && !grep { $_ eq $m } @out;
        }
    }
    return @out;
}

# mac_index: {mac12 => host key} over every host. A host key always maps to itself;
# when two hosts claim the same other MAC the first host (sorted by key) keeps it
# (mac_conflicts reports the clash, intake refuses it).
sub mac_index ($self) {
    my %idx;
    my @hosts = sort $self->host_list_all;
    $idx{$_} = $_ for @hosts;
    for my $h (@hosts) {
        for my $m ($self->host_macs($h)) { $idx{$m} //= $h }
    }
    return \%idx;
}

# mac_conflicts($key, @macs): [[mac, owner key]...] for each of @macs that another
# host than $key already holds, as its key or among its recorded MACs.
sub mac_conflicts ($self, $key, @macs) {
    my $k = normalise_mac($key);
    my $idx = $self->mac_index;
    my @bad;
    for my $m (map { normalise_mac($_) } @macs) {
        my $o = $idx->{$m};
        push @bad, [ $m, $o ] if defined $o && $o ne $k;
    }
    return @bad;
}

# resolve_mac($mac): the host key to use for $mac. A MAC that is a host key is
# its own answer (the common case, no scan); a MAC recorded under another host
# gives that host's key; an unknown MAC gives itself, normalised, so it still
# becomes a new host. Dies on a string that is not a MAC.
sub resolve_mac ($self, $mac) {
    my $m = normalise_mac($mac);
    return $m if -d $self->_host_db($m);
    return $self->mac_index->{$m} // $m;
}

# host_remove($mac): delete the host's whole registry entry (its directory of
# keys, locks included). Returns 1 when it was there, 0 when it was not. The
# only deletion of a host; hps-onboard forget is its caller.
sub host_remove ($self, $mac) {
    my $db = $self->_host_db($mac);
    return 0 unless -d $db;
    require File::Path;
    File::Path::remove_tree($db);
    die "Cannot remove $db\n" if -d $db;
    return 1;
}

#--- names: the one hostname rule (docs/NAMING.md) --------------------------------
# A host's identity everywhere is the FQDN <label>.<cluster dns domain>; the
# registry keeps the label (HOSTNAME). These are the only places Perl joins or
# splits names; the Bash twins are fqdn_join / host_fqdn (host-functions.sh).

use constant FQDN_MAX => 63;     # om3's node-name cap

# short_name($name): the first label, lower case.
sub short_name ($name) {
    my $l = lc($name // '');
    $l =~ s/\..*//s;
    return $l;
}

# fqdn_of($label, $domain): <first label>.<domain> (the label alone when the
# domain is empty); dies when the label or domain is unusable or the result is
# longer than 63 characters.
sub fqdn_of ($name, $domain = '') {
    my $label = short_name($name);
    $domain = lc($domain // '');
    die "'" . ($name // '') . "' has no usable host label\n"
        unless $label =~ /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/;
    die "'$domain' is not a usable DNS domain\n"
        if length $domain && $domain !~ /^[a-z0-9][a-z0-9.-]*\z/;
    my $fqdn = length $domain ? "$label.$domain" : $label;
    die "$fqdn is " . length($fqdn) . " characters; the limit is " . FQDN_MAX . " (om3 node names). Use a shorter cluster DNS domain.\n"
        if length $fqdn > FQDN_MAX;
    return $fqdn;
}

# cluster_dns_domain($cluster): network_dns_domain, lower case; '' when unset or
# not a usable domain. The active cluster when none is named.
sub cluster_dns_domain ($self, $cluster = undef) {
    $cluster //= $self->active_cluster;
    return '' unless $self->cluster_exists($cluster, 'network_dns_domain');
    my $d = $self->cluster_get($cluster, 'network_dns_domain');
    $d = lc($d // '');
    $d =~ s/\A"|"\z//g;
    return $d =~ /^[a-z0-9][a-z0-9.-]*\z/ ? $d : '';
}

# fqdn($mac): the host's FQDN, or undef when it has no HOSTNAME yet.
sub fqdn ($self, $mac) {
    my $name = $self->host_get($mac, 'HOSTNAME');
    return undef unless defined $name && length $name;
    return fqdn_of($name, $self->cluster_dns_domain);
}

# initiator_iqn($mac): the iSCSI initiator name the node writes at boot
# (hps-iscsi-name): iqn.2026-11.hps.<cluster>:<fqdn>. The second dot after the
# date is what LIO requires of an IQN (rtslib-fb).
sub initiator_iqn ($self, $mac) {
    my $f = $self->fqdn($mac);
    return undef unless defined $f;
    return 'iqn.2026-11.hps.' . lc($self->active_cluster) . ":$f";
}

#--- os --------------------------------------------------------------------------

sub os_base ($self) { return $self->config_base . '/os.db' }

sub _os_db ($self, $os_id) {
    die "Invalid OS id: " . ($os_id // '') . "\n"
        unless defined $os_id && $os_id =~ m{^[^:\s/]+:[^:\s/]+:[^:\s/]+$};
    (my $safe = $os_id) =~ tr/:/_/;
    return $self->os_base . "/$safe.os";
}

sub os_exists ($self, $os_id, $key = undef) {
    my $db = $self->_os_db($os_id);
    return defined $key && length $key ? _db_exists($db, $key) : (-d $db ? 1 : 0);
}

sub os_get ($self, $os_id, $key)      { return _db_get($self->_os_db($os_id), $key) }
sub os_get_json ($self, $os_id, $key) { return _db_get_json($self->_os_db($os_id), $key) }
sub os_unset ($self, $os_id, $key)    { return $self->_db_unset($self->_os_db($os_id), $key) }
sub os_keys ($self, $os_id)           { return _db_list($self->_os_db($os_id)) }

sub os_set ($self, $os_id, $key, $v) {
    my $db = $self->_os_db($os_id);
    my $id_file = "$db/.os_id";
    if (!-f $id_file) {
        mkdir_p($db);
        open(my $fh, '>', $id_file) or die "Cannot write $id_file: $!\n";
        print {$fh} "$os_id\n";
        close $fh;
    }
    return $self->_db_set($db, $key, $v);
}

# OS ids: from .os_id, else rebuilt from the directory name (legacy rule).
sub os_list ($self) {
    my $base = $self->os_base;
    my @ids;
    for my $name (_subdirs($base, '.os')) {
        my $dir = "$base/$name.os";
        if (-f "$dir/.os_id") {
            my $id = _slurp("$dir/.os_id");
            $id =~ s/\s+\z//;
            push @ids, $id;
        }
        elsif ($name =~ /^([^_]+)_(.+)_(\d[^_]*)$/) {
            push @ids, "$1:$2:$3";
        }
    }
    return sort @ids;
}

1;
