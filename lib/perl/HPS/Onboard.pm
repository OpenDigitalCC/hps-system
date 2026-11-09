package HPS::Onboard;
# Onboarding of held hosts: list, show the stored audit, assign a role.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

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
    return bless { registry => $reg }, $class;
}

sub registry ($self) { return $self->{registry} }

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

# {mac, identity => {key => raw value, audit excluded}, audit => decoded|undef, audit_at}
sub show ($self, $mac) {
    my $reg = $self->{registry};
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', "Invalid MAC address: $mac") unless defined $m;
    _fail('notfound', "No such host: $mac") unless $reg->host_exists($m);
    my %identity;
    for my $key ($reg->host_list($m)) {
        next if $key eq 'audit';
        $identity{$key} = $reg->host_get($m, $key);
    }
    return {
        mac      => $m,
        state    => $identity{STATE},
        identity => \%identity,
        audit    => $reg->host_get_json($m, 'audit'),
        audit_at => $identity{audit_at},
    };
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

sub _audit_controllers ($a) {
    my $sc = ref $a->{storage_controllers} eq 'HASH' ? $a->{storage_controllers} : {};
    my $out = "Storage controllers\n";
    $out .= "  PCI: $_\n" for _pci_storage($a);
    my @hosts = ref $sc->{scsi_hosts} eq 'ARRAY' ? @{ $sc->{scsi_hosts} } : ();
    my $raid = 0;
    for my $h (@hosts) {
        next unless ref $h eq 'HASH';
        my $m = $h->{hba_mode_enabled};
        my $word = !defined $m ? 'mode not reported'
                 : $m eq '1'   ? 'HBA mode'
                 : $m eq '0'   ? 'RAID mode - NOT acceptable, see brief'
                 :               "mode value '$m'";
        $raid = 1 if defined $m && $m eq '0';
        $out .= '  ' . _unk($h->{host}) . ' (' . _unk($h->{driver}) . "): $word\n";
    }
    $out .= "  No controller reported hba_mode_enabled.\n" unless @hosts;
    if ($sc->{raid_mode_indicator}) {
        $raid = 1;
        $out .= "  A LOGICAL VOLUME disk is present: controller in RAID mode - NOT acceptable, see brief\n";
    }
    $out .= $raid ? "  Verdict: RAID mode detected\n" : "  Verdict: no RAID-mode indicator\n";
    return $out;
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
    return join "\n", _audit_dmi($audit), _audit_cpu_mem($audit),
        _audit_controllers($audit), _audit_disks($audit), _audit_nics($audit);
}

1;
