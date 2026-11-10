package HPS::Workload;
# IPS-side driver of a workload: a named set of VMs, each with disks that are
# mirrors of two legs (a local zvol and/or a remote iSCSI LUN). Every node
# action is a ctrl-exec script (node-manager/nixos-26/scripts/) called through
# scripts/hps-run.sh; this module decides which scripts run on which host, in
# which order, and records the outcome in the cluster registry key
# workload_<name>. Zvols are created and destroyed through HPS::Storage (its
# zvol-create / zvol-destroy), never by a second implementation.
#
# validate($def, layout => $layout) checks a definition and dies with
# HPS::Keysafe::Error (kind 'refused') naming the first problem.
# plan($op, $name, %a) returns the node calls; run(...) executes them.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP;
use POSIX qw(strftime);
use HPS::Registry;
use HPS::Keysafe;
use HPS::Approval;
use HPS::Storage;

my $NAME_RE  = qr/^[a-z][a-z0-9-]{0,31}\z/;
my $IMAGE_RE = qr/^[a-z0-9][a-z0-9._-]{0,63}\z/;
my $SIZE_RE  = qr/^[1-9][0-9]*[MGT]\z/;
my $POOL_RE  = qr/^[a-z][a-z0-9_.-]*\z/;
my $IQN_RE   = qr/^iqn\.[A-Za-z0-9._:-]+\z/;
my $ADDR_RE  = qr/^[0-9]{1,3}(?:\.[0-9]{1,3}){3}\z/;
my $HOST_RE  = qr/^[A-Za-z0-9][A-Za-z0-9_.:-]*\z/;     # MAC or registry HOSTNAME
my $KEY_RE   = qr/^ssh-[a-z0-9-]+ [A-Za-z0-9+\/=]+(?: \S.*)?\z|^(?:ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+\/=]+(?: \S.*)?\z/;

# vm-define keeps one --disk (the last): a VM has exactly one disk until the
# script takes several.
my $MAX_DISKS = 1;

my %OPS = map { $_ => 1 } qw(create start stop destroy status);
my %TOP = map { $_ => 1 } qw(name project access vms);
my %VMK = map { $_ => 1 } qw(name memory_mib vcpus image disks nets priority compute_host boot);
my %DSK = map { $_ => 1 } qw(name size legs);
my %LEG = map { $_ => 1 } qw(host pool iqn portal);

sub _fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

sub ops { return sort keys %OPS }

#=== definition ==================================================================

sub _bad ($where, $msg) { _fail('refused', "$where: $msg") }

sub _plain ($v) { return defined $v && !ref $v }

sub _int_in ($v, $lo, $hi) { return _plain($v) && $v =~ /^[0-9]+\z/ && $v >= $lo && $v <= $hi }

sub _only ($where, $h, $allowed) {
    for my $k (sort keys %$h) { _bad($where, "unknown field '$k'") unless $allowed->{$k} }
    return;
}

sub _validate_leg ($where, $leg) {
    _bad($where, 'a leg must be an object') unless ref $leg eq 'HASH';
    _only($where, $leg, \%LEG);
    _bad($where, "host must match $HOST_RE") unless _plain($leg->{host}) && $leg->{host} =~ $HOST_RE;
    my ($has_pool, $has_iqn) = (exists $leg->{pool}, exists $leg->{iqn});
    _bad($where, 'a leg is {host,pool} (local zvol) or {host,iqn} (remote LUN), not both and not neither')
        unless $has_pool xor $has_iqn;
    if ($has_pool) {
        _bad($where, "pool must match $POOL_RE") unless _plain($leg->{pool}) && $leg->{pool} =~ $POOL_RE;
        _bad($where, 'portal is only for an iqn leg') if exists $leg->{portal};
        return { host => "$leg->{host}", pool => "$leg->{pool}" };
    }
    _bad($where, "iqn must match $IQN_RE") unless _plain($leg->{iqn}) && $leg->{iqn} =~ $IQN_RE;
    _bad($where, 'portal must be an IPv4 address')
        if exists $leg->{portal} && !(_plain($leg->{portal}) && $leg->{portal} =~ $ADDR_RE);
    return { host => "$leg->{host}", iqn => "$leg->{iqn}", (exists $leg->{portal} ? (portal => "$leg->{portal}") : ()) };
}

sub _validate_disk ($where, $disk) {
    _bad($where, 'a disk must be an object') unless ref $disk eq 'HASH';
    _only($where, $disk, \%DSK);
    _bad($where, "name must match $NAME_RE") unless _plain($disk->{name}) && $disk->{name} =~ $NAME_RE;
    $where .= " disk '$disk->{name}'";
    _bad($where, "size must match $SIZE_RE (like 20G)") unless _plain($disk->{size}) && $disk->{size} =~ $SIZE_RE;
    my $legs = $disk->{legs};
    _bad($where, 'legs must be a list of 1 or 2 legs') unless ref $legs eq 'ARRAY' && @$legs >= 1 && @$legs <= 2;
    my @l = map { _validate_leg("$where leg " . ($_ + 1), $legs->[$_]) } 0 .. $#$legs;
    my @local = grep { exists $_->{pool} } @l;
    _bad($where, 'a disk has at most one local leg (one zvol)') if @local > 1;
    _bad($where, 'a disk with one leg needs a local {host,pool} leg') if @l == 1 && !@local;
    return { name => "$disk->{name}", size => "$disk->{size}", legs => \@l };
}

sub _validate_vm ($where, $vm, $layout_given, $layout) {
    _bad($where, 'a VM must be an object') unless ref $vm eq 'HASH';
    _only($where, $vm, \%VMK);
    _bad($where, "name must match $NAME_RE") unless _plain($vm->{name}) && $vm->{name} =~ $NAME_RE;
    $where = "vm '$vm->{name}'";
    _bad($where, 'memory_mib must be 256-262144') unless _int_in($vm->{memory_mib}, 256, 262144);
    _bad($where, 'vcpus must be 1-64') unless _int_in($vm->{vcpus}, 1, 64);
    my $boot = exists $vm->{boot} ? $vm->{boot} : 'disk';
    _bad($where, 'boot must be "disk" or "network"') unless _plain($boot) && ($boot eq 'disk' || $boot eq 'network');
    my $net_boot = $boot eq 'network';
    if ($net_boot) {
        _bad($where, 'a network-boot VM has no image (it boots from the network)') if exists $vm->{image};
    }
    else {
        _bad($where, "image must match $IMAGE_RE") unless _plain($vm->{image}) && $vm->{image} =~ $IMAGE_RE;
    }
    my $prio = exists $vm->{priority} ? $vm->{priority} : 3;
    _bad($where, 'priority must be 1-5') unless _int_in($prio, 1, 5);
    my $disks = $net_boot ? ($vm->{disks} // []) : $vm->{disks};
    _bad($where, $net_boot ? 'disks must be a list' : 'disks must be a non-empty list')
        unless ref $disks eq 'ARRAY' && ($net_boot || @$disks);
    _bad($where, "at most $MAX_DISKS disk per VM (vm-define takes one --disk)") if @$disks > $MAX_DISKS;
    my (%seen, @d);
    for my $d (@$disks) {
        my $nd = _validate_disk($where, $d);
        _bad($where, "disk name '$nd->{name}' is used twice") if $seen{ $nd->{name} }++;
        push @d, $nd;
    }
    my $nets = $vm->{nets};
    _bad($where, 'nets must be a non-empty list of network names') unless ref $nets eq 'ARRAY' && @$nets;
    my %ns;
    for my $n (@$nets) {
        _bad($where, "net names must match $NAME_RE") unless _plain($n) && $n =~ $NAME_RE;
        _bad($where, "net '$n' is listed twice") if $ns{$n}++;
        if ($layout_given) {
            _bad($where, "net '$n' is not in the cluster's network_layout")
                unless ref $layout eq 'HASH' && ref $layout->{$n} eq 'HASH' && _plain($layout->{$n}{bridge});
        }
    }
    # The compute host: the host of the local legs, else compute_host.
    my %local_hosts = map { $_->{host} => 1 } grep { exists $_->{pool} } map { @{ $_->{legs} } } @d;
    my @lh = sort keys %local_hosts;
    _bad($where, "local legs are on more than one host (@lh); a VM's zvols are all on its compute host") if @lh > 1;
    my $compute;
    if (exists $vm->{compute_host}) {
        _bad($where, "compute_host must match $HOST_RE") unless _plain($vm->{compute_host}) && $vm->{compute_host} =~ $HOST_RE;
        _bad($where, "compute_host '$vm->{compute_host}' differs from the host of its local legs ($lh[0])")
            if @lh && $lh[0] ne $vm->{compute_host};
        $compute = "$vm->{compute_host}";
    }
    elsif (@lh) { $compute = $lh[0] }
    else { _bad($where, 'no local {host,pool} leg and no compute_host: the compute host is unknown') }
    return { name => "$vm->{name}", memory_mib => $vm->{memory_mib} + 0, vcpus => $vm->{vcpus} + 0,
        boot => $boot, (defined $vm->{image} ? (image => "$vm->{image}") : ()), disks => \@d, nets => [ map {"$_"} @$nets ],
        priority => $prio + 0, compute => $compute };
}

sub _validate_access ($access) {
    return {} unless defined $access;
    _bad('access', 'must be an object') unless ref $access eq 'HASH';
    _only('access', $access, { ssh_keys => 1, console => 1 });
    if (exists $access->{ssh_keys}) {
        _bad('access', 'ssh_keys must be a list of public keys') unless ref $access->{ssh_keys} eq 'ARRAY';
        for my $k (@{ $access->{ssh_keys} }) {
            _bad('access', 'ssh_keys holds a value that is not a public key line')
                unless _plain($k) && $k =~ $KEY_RE;
        }
    }
    if (exists $access->{console}) {
        _bad('access', 'console must be true or false') unless JSON::PP::is_bool($access->{console});
    }
    return $access;
}

# validate(\%def, layout => \%network_layout): the checked definition. The
# nets are compared with the layout only when a layout option is passed (even
# undef: then every net is refused as missing).
sub validate ($def, %o) {
    _bad('workload', 'the definition must be a JSON object') unless ref $def eq 'HASH';
    _only('workload', $def, \%TOP);
    _bad('workload', "name must match $NAME_RE") unless _plain($def->{name}) && $def->{name} =~ $NAME_RE;
    _bad('workload', 'project must be a non-empty string') unless _plain($def->{project}) && length $def->{project};
    my $access = _validate_access($def->{access});
    _bad('workload', 'vms must be a non-empty list') unless ref $def->{vms} eq 'ARRAY' && @{ $def->{vms} };
    my (%seen, @vms);
    for my $v (@{ $def->{vms} }) {
        my $nv = _validate_vm('vm', $v, exists $o{layout}, $o{layout});
        _bad('workload', "vm name '$nv->{name}' is used twice") if $seen{ $nv->{name} }++;
        push @vms, $nv;
    }
    return { name => "$def->{name}", project => "$def->{project}", access => $access, vms => \@vms };
}

#=== construction ====================================================================

# new(registry, keysafe, approval, storage => sub ($host) -> HPS::Storage-like,
#     runner => obj with call(mac, script, args, input), logger => sub ($level, $msg),
#     now => sub, images_dir => DIR, ips_url => URL, allow_any_pool_name => 0|1, by => NAME)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $ks  = $opt{keysafe}  // HPS::Keysafe->new(registry => $reg);
    my $ap  = $opt{approval} // HPS::Approval->new(registry => $reg, keysafe => $ks);
    my $runner = $opt{runner} // HPS::Storage::Runner::HpsRun->new;
    my $logger = $opt{logger} // \&_default_logger;
    my $now    = $opt{now} // sub { time };
    my $any    = $opt{allow_any_pool_name} ? 1 : 0;
    my $storage = $opt{storage} // sub ($host) {
        return HPS::Storage->new(host => $host, registry => $reg, keysafe => $ks, approval => $ap,
            runner => $runner, logger => sub ($l, $m) { $logger->($l, "storage: $m") }, now => $now,
            allow_any_pool_name => $any);
    };
    _fail('usage', 'storage must be a code ref returning a storage object for a host') unless ref $storage eq 'CODE';
    my $res = $ENV{HPS_RESOURCES} // (($ENV{HPS_BASE} // '/srv') . '/hps-resources');
    return bless {
        registry => $reg, keysafe => $ks, approval => $ap, storage => $storage, runner => $runner,
        logger => $logger, now => $now, any => $any, st_cache => {},
        images_dir => $opt{images_dir} // "$res/images", ips_url => $opt{ips_url},
        by => $opt{by} // $ENV{SUDO_USER} // $ENV{USER} // 'operator',
    }, $class;
}

sub _default_logger ($level, $msg) {
    print STDERR "hps-workload: $msg\n";
    return if $ENV{HPS_WORKLOAD_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-workload: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub _stamp ($self) { return strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($self->{now}->())) }

sub _cluster ($self) { return $self->{cluster} //= $self->{registry}->active_cluster }

# The storage object of a host (MAC or HOSTNAME), one per host string.
sub _st ($self, $host) { return $self->{st_cache}{$host} //= $self->{storage}->($host) }

sub _mac ($self, $host) { return $self->_st($host)->mac }

#=== definitions on disk and records =================================================

sub definition_path ($self, $name) {
    _fail('usage', "workload name must match $NAME_RE") unless defined $name && $name =~ $NAME_RE;
    return $self->{registry}->workload_dir($self->_cluster) . "/$name.json";
}

sub layout ($self) {
    my $reg = $self->{registry};
    return $reg->cluster_exists($self->_cluster, 'network_layout') ? $reg->cluster_get_json($self->_cluster, 'network_layout') : undef;
}

# load($name): the checked definition from workloads/<name>.json.
sub load ($self, $name) {
    my $path = $self->definition_path($name);
    _fail('notfound', "no workload definition: $path") unless -f $path;
    open(my $fh, '<:raw', $path) or _fail('failed', "cannot read $path: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    my $def = eval { JSON::PP->new->utf8->decode($text) };
    _fail('refused', "$path is not valid JSON") unless defined $def;
    my $ok = validate($def, layout => $self->layout);
    _fail('refused', "workload: name '$ok->{name}' differs from the file name '$name'") unless $ok->{name} eq $name;
    return $ok;
}

sub _rec_key ($name) { return "workload_$name" }

# The audit record a destroy leaves (when, by whom); the next create removes it.
sub _destroyed_key ($name) { return "workload_${name}_destroyed" }

sub destroyed_record ($self, $name) {
    my $reg = $self->{registry};
    return $reg->cluster_exists($self->_cluster, _destroyed_key($name)) ? $reg->cluster_get_json($self->_cluster, _destroyed_key($name)) : undef;
}

sub record ($self, $name) {
    my $reg = $self->{registry};
    return $reg->cluster_exists($self->_cluster, _rec_key($name)) ? $reg->cluster_get_json($self->_cluster, _rec_key($name)) : undef;
}

sub _rec_set ($self, $name, $rec) { $self->{registry}->cluster_set($self->_cluster, _rec_key($name), $rec); return }

sub _rec_update ($self, $name, $cb) {
    my $rec = $self->record($name) // return;
    $cb->($rec);
    $self->_rec_set($name, $rec);
    return;
}

# The workload's state from its VMs: one shared state, else 'partial'.
sub _state_of ($rec) {
    my %s = map { $_->{state} => 1 } values %{ $rec->{vms} };
    my @s = sort keys %s;
    return 'partial' unless @s == 1;
    return $s[0] eq 'defined' ? 'created' : $s[0];
}

#=== per-VM facts ======================================================================

sub _dataset ($wl, $vm, $disk, $pool) { return "$pool/enc/vm/$wl-$vm-$disk" }

# The portal of a remote leg: the leg's own, else the one the leg host exports
# that iqn on, else the leg host's registry IP.
sub _portal ($self, $leg) {
    return $leg->{portal} if defined $leg->{portal};
    my $st = eval { $self->_st($leg->{host}) }
        or _fail('refused', "leg host '$leg->{host}' is not in the registry and the leg has no portal");
    if ($st->can('exports')) {
        for my $e ($st->exports) { return $e->{portal} if $e->{iqn} eq $leg->{iqn} }
    }
    my $reg = $self->{registry};
    return $reg->host_get($st->mac, 'IP') if $reg->host_exists($st->mac, 'IP');
    _fail('refused', "no portal for iqn $leg->{iqn}: the leg has none and host '$leg->{host}' has no export or IP in the registry");
}

# The facts a VM's steps need: compute host, pool, and per disk the mirror
# name, the dataset of the local leg, the leg specs and the device.
sub _vm_info ($self, $def, $vm) {
    my $mac = $self->_mac($vm->{compute});
    my ($first_local) = grep { exists $_->{pool} } map { @{ $_->{legs} } } @{ $vm->{disks} };
    my $reg = $self->{registry};
    my $pool = $first_local ? $first_local->{pool}
        : $reg->host_exists($mac, 'storage_pool') ? $reg->host_get($mac, 'storage_pool') : $self->_cluster;
    my @disks;
    for my $d (@{ $vm->{disks} }) {
        my $mirror = "$vm->{name}-$d->{name}";
        my ($local) = grep { exists $_->{pool} } @{ $d->{legs} };
        my $ds = $local ? _dataset($def->{name}, $vm->{name}, $d->{name}, $local->{pool}) : undef;
        my @specs = map { exists $_->{pool} ? "local:$ds" : 'iscsi:' . $self->_portal($_) . ":$_->{iqn}" } @{ $d->{legs} };
        push @disks, { name => $d->{name}, size => $d->{size}, mirror => $mirror, dataset => $ds,
            specs => \@specs, mirrored => (@specs == 2 ? 1 : 0),
            device => (@specs == 2 ? "/dev/md/$mirror" : "/dev/zvol/$ds") };
    }
    return { vm => $vm, name => $vm->{name}, host => $vm->{compute}, mac => $mac, pool => $pool, disks => \@disks,
        image_dir => "/$pool/enc/images" };
}

# VMs in start order (priority 1 first, then definition order); the selected
# --vm only, else all.
sub _ordered ($self, $def, %a) {
    my $i = 0;
    my @vms = map { $_->[1] } sort { $a->[0] <=> $b->[0] || $a->[2] <=> $b->[2] }
        map { [ $_->{priority}, $_, $i++ ] } @{ $def->{vms} };
    if (defined $a{vm}) {
        @vms = grep { $_->{name} eq $a{vm} } @vms;
        _fail('notfound', "workload '$def->{name}' has no VM '$a{vm}'") unless @vms;
    }
    return @vms;
}

#=== steps ============================================================================

# A step: {host (MAC), script, args, key, ok_rc, before, after, undo (on failure), finally,
# storage => [op, %args] (run through HPS::Storage), show => {script,args,input}}.
sub _step ($mac, $script, $args, %x) { return { host => $mac, script => $script, args => $args, %x } }

sub _image_files ($self, $image) {
    my $dir = $self->{images_dir};
    my ($img, $sum) = ("$dir/$image.qcow2", "$dir/$image.sha256");
    _fail('refused', "image '$image' is not on the IPS: $img is missing") unless -f $img;
    _fail('refused', "image '$image' has no checksum file on the IPS: $sum is missing") unless -f $sum;
    open(my $fh, '<', $sum) or _fail('failed', "cannot read $sum: $!");
    my $line = <$fh> // '';
    close $fh;
    my ($hex) = $line =~ /^([0-9a-fA-F]{64})(?:\s|\z)/;
    _fail('refused', "$sum does not start with a 64-hex sha256") unless defined $hex;
    return lc $hex;
}

sub _ips_url ($self) {
    return $self->{ips_url} if defined $self->{ips_url};
    my $reg = $self->{registry};
    _fail('refused', 'the cluster has no network_dhcp_ip: the IPS address for image-fetch is unknown')
        unless $reg->cluster_exists($self->_cluster, 'network_dhcp_ip');
    return 'http://' . $reg->cluster_get($self->_cluster, 'network_dhcp_ip');
}

sub _attached ($self, $mac) {
    my $reg = $self->{registry};
    my $n = $reg->host_exists($mac, 'nets') ? $reg->host_get_json($mac, 'nets') : [];
    return ref $n eq 'ARRAY' ? [@$n] : [];
}

sub _steps_create ($self, $def, %a) {
    my $name = $def->{name};
    my $rec = $self->record($name);
    _fail('refused', "workload '$name' already exists (state $rec->{state})"
        . ($rec->{state} eq 'creating' ? '; --resume continues the unfinished create' : ''))
        if $rec && !$a{resume};
    _fail('refused', "workload '$name' is already created (state $rec->{state}); nothing to resume")
        if $rec && $rec->{state} ne 'creating';
    my $layout = $self->layout;
    my (@s, %fetched, %attached);
    for my $vm (@{ $def->{vms} }) {
        my $in = $self->_vm_info($def, $vm);
        my $mac = $in->{mac};
        for my $d (grep { defined $_->{dataset} } @{ $in->{disks} }) {
            my $stor = $self->_st($vm->{compute});
            my $shown = $stor->plan('zvol-create', dataset => $d->{dataset}, size => $d->{size})->[0];
            push @s, _step($mac, $shown->{script}, $shown->{args}, key => "zvol:$d->{dataset}",
                storage => [ 'zvol-create', dataset => $d->{dataset}, size => $d->{size} ]);
        }
        my $net_boot = $vm->{boot} eq 'network';
        my $image = $vm->{image};
        my $path = $net_boot ? undef : "$in->{image_dir}/$image.qcow2";
        unless ($net_boot || $fetched{"$mac $image"}++) {
            my $sum = $self->_image_files($image);
            push @s, _step($mac, 'image-fetch', [ $image, '--from', $self->_ips_url . "/images/$image.qcow2",
                '--sha256', $sum, '--dest', $in->{image_dir} ], key => "image:$mac:$image");
        }
        for my $d (grep { $_->{mirrored} } @{ $in->{disks} }) {
            push @s, _step($mac, 'mirror-create', [ $d->{mirror}, map { ('--leg', $_) } @{ $d->{specs} } ],
                key => "mirror:$d->{mirror}");
        }
        push @s, _step($mac, 'vm-image-write', [ $vm->{name}, '--disk', $in->{disks}[0]{device}, '--image', $path ],
            key => "write:$vm->{name}") unless $net_boot;
        my $have = $attached{$mac} //= $self->_attached($mac);
        my @missing = grep { my $n = $_; !grep { $_ eq $n } @$have } @{ $vm->{nets} };
        if (@missing) {
            push @$have, @missing;
            my @new = @$have;
            my $prev;    # the node reads host key nets: set it for the call, put it back if the call fails
            my $reg = $self->{registry};
            push @s, _step($mac, 'net-bridge-ensure', [], key => "nets:$mac:" . join(',', @missing),
                before => sub {
                    $prev = $reg->host_exists($mac, 'nets') ? $reg->host_get_json($mac, 'nets') : undef;
                    $reg->host_set($mac, 'nets', [@new]);
                },
                undo => sub { defined $prev ? $reg->host_set($mac, 'nets', $prev) : $reg->host_unset($mac, 'nets') });
        }
        my ($wl, $vmname) = ($name, $vm->{name});
        push @s, _step($mac, 'vm-define', [ $vm->{name}, '--memory', $vm->{memory_mib}, '--vcpus', $vm->{vcpus},
            ($net_boot ? ('--boot', 'network') : ()),
            (map { ('--disk', $_->{device}) } @{ $in->{disks} }),
            (map { ('--net', $layout->{$_}{bridge}) } @{ $vm->{nets} }), ($net_boot ? () : ('--image', $path)) ],
            key => "define:$vm->{name}",
            ($net_boot ? (after => sub ($r) { $self->_record_macs($wl, $vmname, $r) }) : ()));
    }
    return @s;
}

sub _steps_start ($self, $def, %a) {
    my $rec = $self->_need_record($def->{name}, 'start');
    my @s;
    for my $vm ($self->_ordered($def, %a)) {
        my $in = $self->_vm_info($def, $vm);
        for my $d (grep { $_->{mirrored} } @{ $in->{disks} }) {
            push @s, _step($in->{mac}, 'mirror-assemble', [ $d->{mirror}, map { ('--leg', $_) } @{ $d->{specs} } ]);
        }
        my ($n, $host) = ($def->{name}, $vm->{compute});
        push @s, _step($in->{mac}, 'vm-start', [ $vm->{name} ], after => sub {
            $self->_rec_update($n, sub ($r) {
                @{ $r->{vms}{ $vm->{name} } }{qw(state last_owner started_at)} = ('running', $host, $self->_stamp);
                $r->{state} = _state_of($r);
            });
        });
    }
    return @s;
}

sub _steps_stop ($self, $def, %a) {
    $self->_need_record($def->{name}, 'stop');
    my @s;
    for my $vm (reverse $self->_ordered($def, %a)) {
        my $in = $self->_vm_info($def, $vm);
        my @group = (_step($in->{mac}, 'vm-stop', [ $vm->{name} ]),
            map { _step($in->{mac}, 'mirror-stop', [ $_->{mirror} ]) } grep { $_->{mirrored} } @{ $in->{disks} });
        my $n = $def->{name};
        $group[-1]{after} = sub {
            $self->_rec_update($n, sub ($r) {
                $r->{vms}{ $vm->{name} }{state} = 'stopped';
                $r->{state} = _state_of($r);
            });
        };
        push @s, @group;
    }
    return @s;
}

sub _steps_status ($self, $def, %a) {
    $self->_need_record($def->{name}, 'status');
    my @s;
    for my $vm ($self->_ordered($def, %a)) {
        my $in = $self->_vm_info($def, $vm);
        push @s, _step($in->{mac}, 'vm-status', [ $vm->{name} ], soft => 1, vm => $vm->{name}),
            map { _step($in->{mac}, 'mirror-status', [ $_->{mirror} ], soft => 1, vm => $vm->{name}, mirror => $_->{mirror}) }
            grep { $_->{mirrored} } @{ $in->{disks} };
    }
    return @s;
}

# The MACs vm-define reports ("VM <vm> defined mac=<mac>", one line per NIC),
# kept in the workload record so the operator can find the node.
sub _record_macs ($self, $name, $vm, $r) {
    my @macs = ($r->{stdout} // '') =~ /^VM \S+ defined mac=([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$/mg;
    $self->_rec_update($name, sub ($rec) { $rec->{vms}{$vm}{macs} = [@macs] });
    return;
}

sub _need_record ($self, $name, $op) {
    my $rec = $self->record($name) // _fail('notfound', "workload '$name' has not been created (no registry record)");
    _fail('refused', "workload '$name' is not fully created (state $rec->{state}); finish it with create --resume, or remove it with destroy")
        if $rec->{state} eq 'creating' && $op ne 'status' && $op ne 'destroy';
    return $rec;
}

# The workload-destroy approval: it sits on the compute host of the first VM.
sub _destroy_approval ($self, $def) {
    my $name = $def->{name};
    my $mac = $self->_mac($def->{vms}[0]{compute});
    my $json = $self->{approval}->get($mac, 'workload-destroy', $name)
        // _fail('refused', "no workload-destroy approval for workload '$name' on host $mac "
            . "(a human runs: hps-approve workload-destroy $mac --workload $name)");
    my $secret = $self->{keysafe}->cluster_secret('approval');
    my $f = $self->{approval}->verify($json, $secret);    # dies: expired, tampered, malformed
    _fail('refused', 'the approval is for another host') unless $f->{mac} eq $mac;
    _fail('refused', "the approval is for workload '$f->{pool}', not '$name'") unless $f->{pool} eq $name;
    _fail('refused', "the approval is for $f->{action}, not workload-destroy") unless $f->{action} eq 'workload-destroy';
    return $f;
}

# The workload approval covers the zvols of its local legs: for each one a
# zvol-destroy approval is issued (same host, same human, at most ten minutes)
# just before HPS::Storage destroys it and revoked straight after.
sub _steps_destroy ($self, $def, %a) {
    $self->_need_record($def->{name}, 'destroy');
    my $rec = $self->record($def->{name});
    my $f = $self->_destroy_approval($def);
    # An unfinished create: only what it attempted exists (finished steps plus the
    # one that was running when it stopped); the rest is skipped with a note.
    my $partial = $rec->{state} eq 'creating';
    my %tried = map { $_ => 1 } @{ $rec->{done} // [] }, (defined $rec->{attempting} ? $rec->{attempting} : ());
    my @notes;
    my $want = sub ($key, $what) {
        return 1 if !$partial || $tried{$key};
        push @notes, "skipped $what: never created (the create stopped before it)";
        return 0;
    };
    my (@s, @zvols);
    for my $vm (reverse $self->_ordered($def)) {
        my $in = $self->_vm_info($def, $vm);
        if ($want->("define:$vm->{name}", "vm-stop and vm-undefine of $vm->{name}")) {
            push @s, _step($in->{mac}, 'vm-stop', [ $vm->{name} ], ok_rc => [4]),
                _step($in->{mac}, 'vm-undefine', [ $vm->{name} ]);
        }
        push @s, map { _step($in->{mac}, 'mirror-stop', [ $_->{mirror} ]) }
            grep { $_->{mirrored} && $want->("mirror:$_->{mirror}", "mirror-stop of $_->{mirror}") } @{ $in->{disks} };
        push @zvols, map { [ $in->{mac}, $_->{dataset} ] }
            grep { defined $_->{dataset} && $want->("zvol:$_->{dataset}", "zvol destroy of $_->{dataset}") } @{ $in->{disks} };
    }
    $self->{notes} = \@notes;
    for my $z (@zvols) {
        my ($mac, $ds) = @$z;
        my $ap = $self->{approval};
        push @s, _step($mac, 'storage-zvol-destroy', [ $ds, '--approval-file', '-' ], key => "zvol:$ds",
            show => { script => 'storage-zvol-destroy', args => [ $ds, '--approval-file', '-' ],
                      input => '{"approval":"<zvol-destroy approval issued from the workload-destroy approval>","secret":"<redacted>"}' },
            storage => [ 'zvol-destroy', dataset => $ds ],
            before => sub {
                my $until = $self->{now}->() + 600;
                $until = $f->{expires} - 1 if $f->{expires} - 1 < $until;
                $ap->issue({ action => 'zvol-destroy', mac => $mac, pool => $ds, disks => [], wipe => 0,
                    issued_by => $f->{issued_by}, expires => $until });
            },
            finally => sub { eval { $ap->revoke($mac, 'zvol-destroy', $ds) } });
    }
    $self->{destroy_approval} = $f;
    return @s;
}

my %STEPS = (create => '_steps_create', start => '_steps_start', stop => '_steps_stop',
    destroy => '_steps_destroy', status => '_steps_status');

sub _prepare ($self, $op, $name, %a) {
    my $m = $STEPS{ $op // '' } // _fail('usage', 'unknown operation; one of: ' . join(', ', ops()));
    _fail('usage', '--vm is not for ' . $op) if defined $a{vm} && ($op eq 'create' || $op eq 'destroy');
    _fail('usage', '--resume is only for create') if $a{resume} && $op ne 'create';
    _fail('usage', '--forget is only for destroy') if $a{forget} && $op ne 'destroy';
    my $def = $self->load($name);
    return ($def, $self->$m($def, %a));
}

# plan($op, $name, %a): the node calls, [{n, host, script, args, input}].
# Nothing is sent or changed.
sub plan ($self, $op, $name, %a) {
    my ($def, @steps) = $self->_prepare($op, $name, %a);
    my $n = 0;
    return [ map {
        $n++;
        my $s = $_->{show} // $_;
        { n => $n, host => $_->{host}, script => $s->{script}, args => [ @{ $s->{args} } ], input => $s->{input} }
    } @steps ];
}

#=== run ==================================================================================

sub _run_step ($self, $st, $n, $total, $op) {
    $st->{before}->() if $st->{before};
    my $r;
    if ($st->{storage}) {
        my ($sop, %sa) = @{ $st->{storage} };
        my $res = eval { $self->_st($st->{host})->run($sop, %sa) };
        my $e = $@;
        $st->{finally}->() if $st->{finally};
        if ($e) {
            my ($kind, $msg) = ref $e && $e->isa('HPS::Keysafe::Error') ? ($e->kind, $e->message) : ('failed', "$e");
            $self->_log('err', "$op: step $n/$total $st->{script} failed: $msg");
            _fail($kind, "$op: step $n/$total $st->{script}: $msg");
        }
        $r = { rc => 0, stdout => join('', map { $_->{stdout} // '' } @{ $res->{steps} }), stderr => '' };
        $self->_log('info', "$st->{script} ok (via storage $sop)");
    }
    else {
        $self->_log('info', "call $st->{script} " . join(' ', @{ $st->{args} }) . " on $st->{host}");
        $r = $self->{runner}->call(mac => $st->{host}, script => $st->{script}, args => [ @{ $st->{args} } ], input => undef);
        $self->_log('info', "$st->{script} exit $r->{rc}");
    }
    return $r;
}

# run($op, $name, %a): executes the plan; dies with HPS::Keysafe::Error at the
# first failing call. Returns {op, name, ok, steps => [{n, host, script, args,
# rc, stdout, stderr, skipped}], ...}. With dry_run => 1 only {dry_run, plan}.
sub run ($self, $op, $name, %a) {
    if ($a{dry_run}) {
        my $plan = eval { $self->plan($op, $name, %a) };
        if (my $e = $@) { $self->_log('warning', "$op $name refused: " . (ref $e ? $e->message : $e)); die $e }
        return { dry_run => 1, op => $op, name => $name, plan => $plan, ($op eq 'destroy' ? (notes => $self->{notes} // []) : ()) };
    }
    my ($def, @steps) = eval { $self->_prepare($op, $name, %a) };
    if (my $e = $@) {
        $self->_log('warning', "$op $name refused: " . (ref $e ? $e->message : $e));
        die $e;
    }
    $self->_log('info', "$op $name: " . scalar(@steps) . ' step(s)');
    my %done;
    if ($op eq 'create') {
        my $rec = $self->record($name);
        if ($rec) { %done = map { $_ => 1 } @{ $rec->{done} // [] } }
        else { $self->_rec_set($name, $self->_new_record($def)) }
        $self->{registry}->cluster_unset($self->_cluster, _destroyed_key($name));
    }
    my (@results, $n);
    $n = 0;
    for my $st (@steps) {
        $n++;
        if ($st->{key} && $op eq 'create' && $done{ $st->{key} }) {
            $self->_log('info', "step $n skipped (already done): $st->{key}");
            push @results, { n => $n, host => $st->{host}, script => $st->{script}, args => $st->{args}, rc => 0,
                stdout => '', stderr => '', skipped => 1 };
            next;
        }
        $self->_rec_update($name, sub ($rec) { $rec->{attempting} = $st->{key} }) if $op eq 'create' && $st->{key};
        my $r = $self->_run_step($st, $n, scalar(@steps), $op);
        push @results, { n => $n, host => $st->{host}, script => $st->{script}, args => $st->{args}, rc => $r->{rc},
            stdout => $r->{stdout} // '', stderr => $r->{stderr} // '',
            (defined $st->{vm} ? (vm => $st->{vm}) : ()), (defined $st->{mirror} ? (mirror => $st->{mirror}) : ()) };
        if ($r->{rc} != 0 && !$st->{soft} && !grep { $_ == $r->{rc} } @{ $st->{ok_rc} // [] }) {
            my $last = (grep { length } split /\n/, ($r->{stderr} // ''))[-1] // '';
            my $kind = $r->{rc} == 3 ? 'refused' : $r->{rc} == 4 ? 'notfound' : 'failed';
            $st->{undo}->() if $st->{undo};
            $self->_log('err', "$op $name: step $n/" . scalar(@steps) . " $st->{script} exited $r->{rc}");
            _fail($kind, "$op: step $n/" . scalar(@steps) . " $st->{script} exited $r->{rc}" . (length $last ? ": $last" : ''));
        }
        $st->{after}->($r) if $st->{after} && $r->{rc} == 0;
        if ($op eq 'create' && $st->{key}) {
            $done{ $st->{key} } = 1;
            $self->_rec_update($name, sub ($rec) { push @{ $rec->{done} }, $st->{key}; delete $rec->{attempting} });
        }
    }
    my $out = { op => $op, name => $name, ok => 1, steps => \@results, ($op eq 'destroy' ? (notes => $self->{notes} // []) : ()) };
    $self->_post($op, $def, $out, %a);
    $self->_log('info', "$op $name ok");
    return $out;
}

sub _new_record ($self, $def) {
    my %vms;
    for my $vm (@{ $def->{vms} }) {
        my $in = $self->_vm_info($def, $vm);
        $vms{ $vm->{name} } = { host => $vm->{compute}, state => 'creating',
            disks => { map { $_->{name} => { md => $_->{device}, legs => $_->{specs} } } @{ $in->{disks} } } };
    }
    return { state => 'creating', vms => \%vms, created_at => $self->_stamp, by => $self->{by}, done => [] };
}

sub _post ($self, $op, $def, $out, %a) {
    my $name = $def->{name};
    if ($op eq 'create') {
        $self->_rec_update($name, sub ($r) {
            $_->{state} = 'defined' for values %{ $r->{vms} };
            $r->{state} = 'created';
            delete $r->{done};
            delete $r->{attempting};
        });
    }
    elsif ($op eq 'destroy') {
        my $f = $self->{destroy_approval};
        my $mac = $self->_mac($def->{vms}[0]{compute});
        $self->{registry}->cluster_unset($self->_cluster, _rec_key($name));
        $self->{registry}->cluster_set($self->_cluster, _destroyed_key($name),
            { at => $self->_stamp, by => $self->{by}, approved_by => $f->{issued_by}, forgotten => $a{forget} ? JSON::PP::true : JSON::PP::false });
        # The definition is the operator's intent: it stays unless --forget.
        if ($a{forget}) {
            unlink $self->definition_path($name);
            $out->{forgotten} = 1;
        }
        eval { $self->{approval}->revoke($mac, 'workload-destroy', $name) };
        $out->{approval} = { map { $_ => $f->{$_} } qw(action pool expires issued_by mac) } if $f;
    }
    elsif ($op eq 'status') {
        $self->_post_status($def, $out);
    }
    return;
}

# Status: the recorded and the node-reported state per VM and mirror.
sub _post_status ($self, $def, $out) {
    my $rec = $self->record($def->{name});
    my %vms;
    for my $r (@{ $out->{steps} }) {
        my $v = $vms{ $r->{vm} } //= { vm => $r->{vm}, host => $rec->{vms}{ $r->{vm} }{host},
            recorded_state => $rec->{vms}{ $r->{vm} }{state}, state => 'unknown', mirrors => [], ok => 1 };
        my @lines = grep { length } map { s/\s+\z//r } split /\n/, $r->{stdout};
        if ($r->{script} eq 'vm-status') {
            my ($l) = reverse grep { /^VM \S+ / } @lines;
            $v->{state} = $l =~ s/^VM \S+ //r if defined $l;
        }
        else {
            my ($l) = reverse grep { /^MIRROR \S+ / } @lines;
            push @{ $v->{mirrors} }, { name => $r->{mirror}, state => (defined $l ? $l =~ s/^MIRROR \S+ //r : 'unknown'), rc => $r->{rc} };
        }
        if ($r->{rc} != 0) { $v->{ok} = 0; $out->{ok} = 0 }
    }
    $out->{state} = $rec->{state};
    $out->{vms} = [ map { $vms{ $_->{name} } } grep { $vms{ $_->{name} } } @{ $def->{vms} } ];
    return;
}

1;

__END__

=head1 NAME

HPS::Workload - drive a workload (VMs on mirrored disks) over ctrl-exec

=head1 OPERATIONS

See F<docs/WORKLOADS.md>.

=cut
