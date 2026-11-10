package HPS::Onboard;
# Onboarding of held hosts: list, show the stored audit, assign a role, repin.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use HPS::Registry;

package HPS::Onboard::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my %TYPES = map { $_ => 1 } qw(SCH TCH DRH);

sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    return bless { registry => $reg, resources => $opt{resources} }, $class;
}

sub registry ($self) { return $self->{registry} }

# Directory of the NixOS pins: <resources>/nixos. Resources default as
# lib/hps-system.sh: HPS_RESOURCES, else ${HPS_BASE:-/srv}/hps-resources.
sub nixos_dir ($self) {
    my $res = $self->{resources} // $ENV{HPS_RESOURCES}
        // (($ENV{HPS_BASE} // '/srv') . '/hps-resources');
    return "$res/nixos";
}

sub _fail ($kind, $msg) { die HPS::Onboard::Error->new($kind, $msg) }

# Hosts whose STATE is HELD, as [{mac, audit_at, ...}], sorted by MAC.
sub list_held ($self) {
    my $reg = $self->{registry};
    my @held;
    for my $mac ($reg->host_list_all) {
        my $state = $reg->host_get($mac, 'STATE');
        next unless defined $state && $state eq 'HELD';
        my $at = $reg->host_get($mac, 'audit_at');
        push @held, { mac => $mac, state => $state, audit_at => $at, has_audit => $reg->host_exists($mac, 'audit') ? 1 : 0 };
    }
    return @held;
}

# Every host, as [{mac, state, init_ok, init_at}], sorted by MAC. init_ok is
# 'true', 'false' or undef (no init result reported); init_at is the finished_at
# of the last reported init.
sub list_all ($self) {
    my $reg = $self->{registry};
    my @all;
    for my $mac ($reg->host_list_all) {
        my $res = $reg->host_get_json($mac, 'init_result');
        my $ok  = $reg->host_get($mac, 'init_ok');
        push @all, {
            mac     => $mac,
            state   => $reg->host_get($mac, 'STATE'),
            init_ok => $ok,
            init_at => (ref $res eq 'HASH' ? ($res->{finished_at} || $res->{received_at}) : undef),
        };
    }
    return @all;
}

# {mac, identity => {key => raw value, audit excluded}, audit => decoded|undef, audit_at}
sub show ($self, $mac) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my %identity;
    for my $key ($reg->host_list($m)) {
        next if $key eq 'audit' || $key eq 'nets' || $key eq 'init_result' || $key eq 'init_result_prev';
        $identity{$key} = $reg->host_get($m, $key);
    }
    return {
        mac      => $m,
        state    => $identity{STATE},
        identity => \%identity,
        audit    => $reg->host_get_json($m, 'audit'),
        audit_at => $identity{audit_at},
        nets     => $reg->host_get_json($m, 'nets'),
        init      => $reg->host_get_json($m, 'init_result'),
        init_prev => $reg->host_get_json($m, 'init_result_prev'),
        init_ok   => $identity{init_ok},
    };
}

#--- network attachment --------------------------------------------------------
# The network layout is the cluster key network_layout (cluster-bootstrap
# --network-add): {"<name>": {cidr, vlan, bridge, purpose, nic?}}. The implicit
# 'provisioning' network is not in it and is not attachable. A host's attached
# networks are the host key nets, a JSON list of layout names; the node reads
# both and builds the bridges (net-bridge-ensure).

# The layout hash of the active cluster, or undef when none was defined.
sub network_layout ($self) {
    my $reg = $self->{registry};
    return $reg->cluster_get_json($reg->active_cluster, 'network_layout');
}

# attach_nets($mac, \@names): REPLACE the host's attached networks with @names
# (an empty list clears the key). Every name must be in the layout. Returns
# {mac, nets => [names]}. Nothing is written when any name is refused.
sub attach_nets ($self, $mac, $names) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my @names = @{ $names // [] };
    my %seen;
    for my $n (@names) {
        _fail('usage', "network name '$n' must match ^[a-z][a-z0-9-]*\$") unless $n =~ /^[a-z][a-z0-9-]*$/;
        _fail('usage', "'provisioning' is the implicit network; it is not attached") if $n eq 'provisioning';
        _fail('usage', "network '$n' given twice") if $seen{$n}++;
    }
    if (@names) {
        my $layout = $self->network_layout;
        _fail('notfound', 'The cluster has no network layout (cluster-bootstrap --network-add)')
            unless ref $layout eq 'HASH';
        for my $n (@names) {
            _fail('notfound', "Network '$n' is not in the network layout (" . join(', ', sort keys %$layout) . ')')
                unless exists $layout->{$n};
        }
        $reg->host_set($m, 'nets', [@names]);
    }
    elsif ($reg->host_exists($m, 'nets')) {
        $reg->host_unset($m, 'nets');
    }
    return { mac => $m, nets => [@names] };
}

# nets($mac): [{name, cidr, vlan, bridge, purpose}] for the attached networks
# (layout fields; a name no longer in the layout shows with undef fields).
sub nets ($self, $mac) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my $attached = $reg->host_get_json($m, 'nets');
    return [] unless ref $attached eq 'ARRAY';
    my $layout = $self->network_layout;
    $layout = {} unless ref $layout eq 'HASH';
    return [ map { { name => $_, %{ $layout->{$_} // {} } } } @$attached ];
}

sub _validate_args ($self, $a) {
    my $type = $a->{type};
    _fail('usage', 'type is required') unless defined $type && length $type;
    my @t = split /,/, $type, -1;
    my %seen;
    for my $t (@t) {
        _fail('usage', "type '$type' must be a comma list of SCH, TCH, DRH")
            unless $TYPES{$t} && !$seen{$t}++;
    }
    my $profile = $a->{profile};
    _fail('usage', "profile '" . ($profile // '') . "' must match ^[A-Z][A-Z0-9_]*\$")
        unless defined $profile && $profile =~ /^[A-Z][A-Z0-9_]*$/;
    my $os = $a->{os};
    _fail('usage', 'os is required (arch:name:version)')
        unless defined $os && $os =~ /^[^:\s\/]+:[^:\s\/]+:[^:\s\/]+$/;
    my $pin = $a->{pin};
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$")
        unless defined $pin && $pin =~ /^[a-z0-9][a-z0-9.-]+$/;
    return 1;
}

sub assign ($self, $mac, $a) {
    my $reg = $self->{registry};
    $self->_validate_args($a);
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my $state = $reg->host_get($m, 'STATE');
    $state = '(none)' unless defined $state;
    _fail('refused', "Host $m is in state $state; only HELD hosts can be assigned")
        unless $state eq 'HELD';
    _fail('notfound', "OS $a->{os} is not in the OS registry") unless $reg->os_exists($a->{os});

    $reg->host_set($m, 'TYPE',         $a->{type});
    $reg->host_set($m, 'HOST_PROFILE', $a->{profile});
    $reg->host_set($m, 'PROFILE',      $a->{profile});
    $reg->host_set($m, 'os_id',        $a->{os});
    $reg->host_set($m, 'system_pin',   $a->{pin});
    $reg->host_set($m, 'storage_note', $a->{storage_note})
        if defined $a->{storage_note} && length $a->{storage_note};
    $reg->host_set($m, 'assigned_at',  $reg->timestamp);

    # IP/hostname allocation stays in Bash (host_network_configure). The hook
    # is a program path run as: $HPS_ONBOARD_NETCONF_CMD <mac>. It runs before
    # STATE is written because host_network_configure sets STATE=CONFIGURED.
    my $cmd = $ENV{HPS_ONBOARD_NETCONF_CMD};
    if (defined $cmd && length $cmd) {
        system($cmd, $m) == 0
            or _fail('failed', "Network configuration hook failed for $m (exit " . ($? >> 8) . ')');
    }
    $reg->host_set($m, 'STATE', 'NETWORK_BOOT');
    return { mac => $m, state => 'NETWORK_BOOT' };
}

# The pin named by <nixos>/latest; fails (notfound) when it is missing or empty.
sub _latest_pin ($self) {
    my $file = $self->nixos_dir . '/latest';
    open my $fh, '<', $file or _fail('notfound', "No latest pin: cannot read $file");
    my $pin = <$fh> // '';
    close $fh;
    $pin =~ s/\s+//g;
    _fail('notfound', "No latest pin: $file is empty") unless length $pin;
    return $pin;
}

# A pin is usable when its directory holds at least one profile directory and
# every profile directory has a boot.json that parses.
sub _check_pin_artefacts ($self, $pin) {
    my $dir = $self->nixos_dir . "/$pin";
    _fail('notfound', "Pin $pin does not exist under " . $self->nixos_dir) unless -d $dir;
    opendir my $dh, $dir or _fail('failed', "Cannot read $dir: $!");
    my @profiles = sort grep { !/^\./ && -d "$dir/$_" } readdir $dh;
    closedir $dh;
    _fail('notfound', "Pin $pin has no profile directories") unless @profiles;
    for my $prof (@profiles) {
        my $file = "$dir/$prof/boot.json";
        _fail('notfound', "Pin $pin is incomplete: $prof has no boot.json") unless -f $file;
        open my $fh, '<', $file or _fail('failed', "Cannot read $file: $!");
        my $text = do { local $/; <$fh> };
        close $fh;
        my $ok = eval { JSON::PP::decode_json($text); 1 };
        _fail('notfound', "Pin $pin is incomplete: $prof/boot.json is not valid JSON") unless $ok;
    }
    return 1;
}

# repin($mac, {pin => P} | {to_latest => 1}): change an assigned host's
# system_pin. Rollout and rollback are this registry change. The previous pin
# is kept as system_pin_previous. Returns {mac, from, to}.
sub repin ($self, $mac, $a) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    my $pin = $a->{pin};
    _fail('usage', 'give exactly one of pin and to_latest')
        if ($a->{to_latest} && defined $pin) || (!$a->{to_latest} && !defined $pin);
    $pin = $self->_latest_pin if $a->{to_latest};
    _fail('usage', "pin '$pin' must match ^[a-z0-9][a-z0-9.-]+\$") unless $pin =~ /^[a-z0-9][a-z0-9.-]+$/;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my $state = $reg->host_get($m, 'STATE');
    _fail('refused', "Host $m has no STATE; only assigned hosts can be repinned") unless defined $state && length $state;
    _fail('refused', "Host $m is HELD; assign it first") if $state eq 'HELD';
    my $old = $reg->host_get($m, 'system_pin');
    _fail('refused', "Host $m is already pinned to $pin") if defined $old && $old eq $pin;
    $self->_check_pin_artefacts($pin);

    if (defined $old && length $old) { $reg->host_set($m, 'system_pin_previous', $old) }
    else                             { $reg->host_unset($m, 'system_pin_previous') if $reg->host_exists($m, 'system_pin_previous') }
    $reg->host_set($m, 'system_pin',  $pin);
    $reg->host_set($m, 'repinned_at', $reg->timestamp);
    return { mac => $m, from => $old, to => $pin };
}

#--- audit presentation -------------------------------------------------------
# render_audit($audit): the hps-audit/1 document as text for a sysadmin.
# Pure function (no registry); missing parts print as "unknown".

sub _unk ($v) { return (defined $v && length $v) ? $v : 'unknown' }

sub _lscpu_field ($cpu, $name) {
    return undef unless ref $cpu eq 'HASH' && ref $cpu->{lscpu} eq 'ARRAY';
    for my $e (@{ $cpu->{lscpu} }) {
        next unless ref $e eq 'HASH' && defined $e->{field};
        (my $f = $e->{field}) =~ s/:\s*$//;
        return $e->{data} if $f eq $name;
    }
    return undef;
}

sub _audit_dmi ($a) {
    my $d = ref $a->{dmi} eq 'HASH' ? $a->{dmi} : {};
    return "Machine\n"
        . "  Vendor:  " . _unk($d->{sys_vendor}) . "\n"
        . "  Product: " . _unk($d->{product_name}) . "\n"
        . "  Serial:  " . _unk($d->{product_serial}) . "\n";
}

sub _audit_cpu_mem ($a) {
    my $model   = _lscpu_field($a->{cpu}, 'Model name');
    my $sockets = _lscpu_field($a->{cpu}, 'Socket(s)');
    my $cpus    = _lscpu_field($a->{cpu}, 'CPU(s)');
    my $kb = ref $a->{memory} eq 'HASH' ? $a->{memory}{MemTotal} : undef;
    my $gib = (defined $kb && $kb =~ /^\d+$/) ? sprintf('%.1f GiB', $kb / 1048576) : 'unknown';
    return "CPU and memory\n"
        . "  CPU:    " . _unk($model) . ", sockets " . _unk($sockets) . ", logical CPUs " . _unk($cpus) . "\n"
        . "  Memory: $gib\n";
}

# PCI storage controllers named from `lspci -k -mm` lines.
sub _pci_storage ($a) {
    my @names;
    for my $line (split /\n/, (defined $a->{pci} && !ref $a->{pci} ? $a->{pci} : '')) {
        my ($slot, @q) = $line =~ /^(\S+)\s+"([^"]*)"\s+"([^"]*)"\s+"([^"]*)"/ or next;
        next unless $q[0] =~ /RAID|SAS|SATA|Serial Attached|Non-Volatile|Mass storage|SCSI/i;
        push @names, "$slot $q[1] $q[2] ($q[0])";
    }
    return @names;
}

my $PCI_ADDR_RE = qr/^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/i;
my %SMART_ARRAY_DRIVER = (hpsa => 1, smartpqi => 1);

# Disks (lsblk type disk) as [{name, model}].
sub _lsblk_disks ($a) {
    my $bd = ref $a->{block} eq 'HASH' && ref $a->{block}{blockdevices} eq 'ARRAY' ? $a->{block}{blockdevices} : [];
    return grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'disk' } @$bd;
}

# The Smart Array driver (hpsa/smartpqi) bound to a PCI device, or undef:
# a PCI address in /sys/bus/pci/drivers/<drv>/, else a SCSI host whose
# proc_name is that driver.
sub _smart_array_driver ($a) {
    my $sc = ref $a->{storage_controllers} eq 'HASH' ? $a->{storage_controllers} : {};
    my $drv = ref $sc->{pci_drivers} eq 'HASH' ? $sc->{pci_drivers} : {};
    for my $name (sort keys %SMART_ARRAY_DRIVER) {
        my $list = $drv->{$name};
        next unless ref $list eq 'ARRAY';
        my @bound = grep { defined && /$PCI_ADDR_RE/ } @$list;
        return "$name bound to " . join(', ', @bound) if @bound;
    }
    for my $h (ref $sc->{scsi_hosts} eq 'ARRAY' ? @{ $sc->{scsi_hosts} } : ()) {
        next unless ref $h eq 'HASH' && defined $h->{driver} && $SMART_ARRAY_DRIVER{ $h->{driver} };
        return "$h->{driver} SCSI host " . ($h->{host} // '?');
    }
    return undef;
}

# Controller mode from the evidence available. Returns {verdict, evidence[]}.
#   RAID    any LOGICAL VOLUME disk, or a host reporting hba_mode_enabled=0
#   HBA     a host reports hba_mode_enabled=1, or (Smart Array driver bound,
#           no LOGICAL VOLUME, at least one disk with a native vendor model)
#   UNKNOWN otherwise
# hpsa on some firmware reports no hba_mode_enabled file at all, so the second
# HBA rule is what identifies the common case.
sub controller_verdict ($a) {
    my $sc = ref $a->{storage_controllers} eq 'HASH' ? $a->{storage_controllers} : {};
    my @hosts = grep { ref $_ eq 'HASH' } (ref $sc->{scsi_hosts} eq 'ARRAY' ? @{ $sc->{scsi_hosts} } : ());
    my @hba1 = grep { defined $_->{hba_mode_enabled} && $_->{hba_mode_enabled} eq '1' } @hosts;
    my @hba0 = grep { defined $_->{hba_mode_enabled} && $_->{hba_mode_enabled} eq '0' } @hosts;
    my @disks = _lsblk_disks($a);
    my @lv = grep { ($_->{model} // '') =~ /LOGICAL VOLUME/i } @disks;
    my $lv = (@lv || $sc->{raid_mode_indicator}) ? 1 : 0;
    my @native = grep { defined $_->{model} && length $_->{model} && $_->{model} !~ /LOGICAL VOLUME/i } @disks;
    my $driver = _smart_array_driver($a);

    my @ev;
    push @ev, 'hba_mode_enabled=1 on ' . join(', ', map { $_->{host} // '?' } @hba1) if @hba1;
    push @ev, 'hba_mode_enabled=0 on ' . join(', ', map { $_->{host} // '?' } @hba0) if @hba0;
    push @ev, 'a LOGICAL VOLUME disk is present' if $lv;

    if ($lv || @hba0) {
        push @ev, 'hba_mode_enabled=1 is also reported: conflicting evidence, treated as RAID' if @hba1;
        return { verdict => 'RAID', evidence => \@ev };
    }
    return { verdict => 'HBA', evidence => \@ev } if @hba1;
    if ($driver && @native) {
        my %seen;
        my @models = grep { !$seen{$_}++ } map { $_->{model} } @native;
        push @ev, "driver $driver; no LOGICAL VOLUME disk; native disk model(s): " . join(', ', @models)
                . ' (inferred: no hba_mode_enabled attribute was reported)';
        return { verdict => 'HBA', evidence => \@ev };
    }
    push @ev, $driver ? "driver $driver but no disk with a native model is visible" : 'no Smart Array driver binding found';
    return { verdict => 'UNKNOWN', evidence => \@ev };
}

sub _audit_controllers ($a) {
    my $sc = ref $a->{storage_controllers} eq 'HASH' ? $a->{storage_controllers} : {};
    my $out = "Storage controllers\n";
    $out .= "  PCI: $_\n" for _pci_storage($a);
    my @hosts = ref $sc->{scsi_hosts} eq 'ARRAY' ? @{ $sc->{scsi_hosts} } : ();
    my $reported = 0;
    for my $h (@hosts) {
        next unless ref $h eq 'HASH';
        my $m = $h->{hba_mode_enabled};
        $reported = 1 if defined $m;
        my $word = !defined $m ? 'mode not reported'
                 : $m eq '1'   ? 'HBA mode'
                 : $m eq '0'   ? 'RAID mode - NOT acceptable, see brief'
                 :               "mode value '$m'";
        my @extra = map { "$_ $h->{$_}" } grep { defined $h->{$_} && length $h->{$_} } qw(transport_mode firmware_revision);
        $out .= '  ' . _unk($h->{host}) . ' (' . _unk($h->{driver}) . "): $word" . (@extra ? ' [' . join(', ', @extra) . ']' : '') . "\n";
    }
    $out .= "  No controller reported hba_mode_enabled.\n" unless $reported;
    $out .= "  A LOGICAL VOLUME disk is present: controller in RAID mode - NOT acceptable, see brief\n"
        if $sc->{raid_mode_indicator};
    my $v = controller_verdict($a);
    my $text = $v->{verdict} eq 'RAID' ? 'RAID mode detected'
             : $v->{verdict} eq 'HBA'  ? 'HBA mode'
             :                           'unknown (no RAID indicator, no HBA evidence)';
    $out .= "  Verdict: $text\n";
    $out .= "    evidence: $_\n" for @{ $v->{evidence} };
    return $out;
}

# Kernel messages from hpsa about devices it added, removed, masked or skipped:
# the usual reason a drive the iLO reports healthy is absent from the OS.
sub _audit_hidden_drives ($a) {
    my $dm = ref $a->{dmesg} eq 'ARRAY' ? $a->{dmesg} : [];
    my @hit = grep { defined && !ref && /hpsa.*(?:scsi|dev|added|removed|masked|unknown|skip)/i } @$dm;
    return '' unless @hit;
    @hit = @hit[ ($#hit >= 11 ? $#hit - 11 : 0) .. $#hit ];
    return "Drives the OS cannot see (last " . scalar(@hit) . " hpsa kernel messages about devices)\n"
         . join('', map { "  $_\n" } @hit);
}

# by-id names per kernel device name, from `ls -l /dev/disk/by-id` text.
sub _by_id_map ($text) {
    my %map;
    for my $line (split /\n/, (defined $text && !ref $text ? $text : '')) {
        next unless $line =~ /\s(\S+)\s+->\s+\.\.\/\.\.\/(\S+)\s*$/;
        push @{ $map{$2} }, $1;
    }
    return \%map;
}

sub _best_by_id ($names) {
    my @n = grep { !/-part\d+$/ } @{ $names // [] };
    my ($pref) = grep { /^(?:ata|scsi|nvme|usb|virtio)-/ } @n;
    return $pref // $n[0] // '(none)';
}

# What an audit shows already on a disk: blkid signatures and zpool labels.
sub _disk_content ($name, $names, $a) {
    my @found;
    for my $line (split /\n/, (defined $a->{blkid} && !ref $a->{blkid} ? $a->{blkid} : '')) {
        next unless $line =~ m{^(/dev/\Q$name\E(?:p?\d+)?):\s*(.*)$};
        my ($dev, $rest) = ($1, $2);
        my ($type)  = $rest =~ /\bTYPE="([^"]*)"/;
        my ($label) = $rest =~ /\bLABEL="([^"]*)"/;
        push @found, "$dev " . ($type // 'signature') . (defined $label ? " label=$label" : '');
    }
    my $zp = defined $a->{zpool_import} && !ref $a->{zpool_import} ? $a->{zpool_import} : '';
    for my $block (split /(?=^\s*pool:\s)/m, $zp) {
        my ($pool) = $block =~ /^\s*pool:\s*(\S+)/m or next;
        my $hit = $block =~ m{\b\Q$name\E(?:p?\d+)?\b};
        $hit ||= grep { index($block, $_) >= 0 } @{ $names // [] };
        push @found, "zpool label: $pool" if $hit;
    }
    return @found;
}

sub _audit_disks ($a) {
    my $bd = ref $a->{block} eq 'HASH' && ref $a->{block}{blockdevices} eq 'ARRAY' ? $a->{block}{blockdevices} : [];
    my @disks = grep { ref $_ eq 'HASH' && ($_->{type} // '') eq 'disk' } @$bd;
    my $map = _by_id_map($a->{disk_by_id});
    my $out = "Disks\n";
    $out .= "  No disks reported.\n" unless @disks;
    for my $d (@disks) {
        my $name = $d->{name} // '';
        my $names = $map->{$name};
        $out .= "  /dev/disk/by-id/" . _best_by_id($names) . "\n";
        $out .= "    size " . _unk($d->{size}) . ", model " . _unk($d->{model}) . "\n";
        my @c = _disk_content($name, $names, $a);
        $out .= @c ? join('', map { "    content: $_\n" } @c) : "    content: none seen (no blkid or zpool signature)\n";
    }
    return $out;
}

sub _audit_nics ($a) {
    my $links = ref $a->{net} eq 'HASH' && ref $a->{net}{link} eq 'ARRAY' ? $a->{net}{link} : [];
    my $out = "Network interfaces\n";
    my $n = 0;
    for my $l (@$links) {
        next unless ref $l eq 'HASH';
        next if ($l->{link_type} // '') eq 'loopback' || ($l->{ifname} // '') eq 'lo';
        my $state = $l->{operstate} // 'UNKNOWN';
        my $flags = ref $l->{flags} eq 'ARRAY' ? $l->{flags} : [];
        $state .= ', link up' if grep { $_ eq 'LOWER_UP' } @$flags;
        $out .= '  ' . _unk($l->{ifname}) . '  ' . _unk($l->{address}) . "  $state\n";
        $n++;
    }
    $out .= "  None reported.\n" unless $n;
    return $out;
}

sub render_audit ($audit) {
    return "No audit data.\n" unless ref $audit eq 'HASH';
    return join "\n", grep { length } _audit_dmi($audit), _audit_cpu_mem($audit),
        _audit_controllers($audit), _audit_disks($audit), _audit_hidden_drives($audit),
        _audit_nics($audit);
}

1;
