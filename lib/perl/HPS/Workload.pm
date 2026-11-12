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
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
use POSIX qw(strftime);
use HPS::Registry;
use HPS::Keysafe;
use HPS::Vxlan ();
use HPS::Storage;

my $NAME_RE  = qr/^[a-z][a-z0-9-]{0,31}\z/;
my $IMAGE_RE = qr/^[a-z0-9][a-z0-9._-]{0,63}\z/;
my $SIZE_RE  = qr/^[1-9][0-9]*[MGT]\z/;
my $POOL_RE  = qr/^[a-z][a-z0-9_.-]*\z/;
my $IQN_RE   = qr/^iqn\.[A-Za-z0-9._:-]+\z/;
my $ADDR_RE  = qr/^[0-9]{1,3}(?:\.[0-9]{1,3}){3}\z/;
my $HOST_RE  = qr/^[A-Za-z0-9][A-Za-z0-9_.:-]*\z/;     # MAC or registry HOSTNAME
my $KEY_RE   = qr/^ssh-[a-z0-9-]+ [A-Za-z0-9+\/=]+(?: \S.*)?\z|^(?:ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+\/=]+(?: \S.*)?\z/;

# vm-define takes --disk 1..8 times.
my $MAX_DISKS = 8;

my %OPS = map { $_ => 1 } qw(create start stop destroy status grow-disk);
my %TOP = map { $_ => 1 } qw(name project access vms);
my %VMK = map { $_ => 1 } qw(name memory_mib vcpus image disks nets priority compute_host boot hardware);
my %NICK = map { $_ => 1 } qw(net pvid tagged model);
my %HWK  = map { $_ => 1 } qw(disk_bus smbios);
my %SMK  = map { $_ => 1 } qw(vendor product serial);
my %NIC_MODELS = map { $_ => 1 } qw(virtio e1000e rtl8139);
my %DISK_BUSES = map { $_ => 1 } qw(virtio scsi sata);
my $SMBIOS_RE = qr/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}\z/;
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
    my $prio = exists $vm->{priority} ? $vm->{priority} : undef;
    _bad($where, 'priority must be 1-5') if defined $prio && !_int_in($prio, 1, 5);
    my $disks = $net_boot ? ($vm->{disks} // []) : $vm->{disks};
    _bad($where, $net_boot ? 'disks must be a list' : 'disks must be a non-empty list')
        unless ref $disks eq 'ARRAY' && ($net_boot || @$disks);
    _bad($where, "at most $MAX_DISKS disks per VM") if @$disks > $MAX_DISKS;
    my (%seen, @d);
    for my $d (@$disks) {
        my $nd = _validate_disk($where, $d);
        _bad($where, "disk name '$nd->{name}' is used twice") if $seen{ $nd->{name} }++;
        push @d, $nd;
    }
    my $nets = $vm->{nets};
    _bad($where, 'nets must be a non-empty list of network names') unless ref $nets eq 'ARRAY' && @$nets;
    # A net may be listed more than once: one NIC per entry, so a VM can have
    # two ports on one network like a machine cabled twice (IPS-15 test, lab
    # 2026-11-11).
    # An entry is a name, or an object {net, pvid?, tagged?, model?}: the
    # port's VLANs on a fabric (emulated switch) net and its NIC model.
    my (@names, @nics, $has_obj);
    for my $e (@$nets) {
        my ($n, %nic);
        if (ref $e eq 'HASH') {
            $has_obj = 1;
            _only($where, $e, \%NICK);
            $n = $e->{net};
            if (exists $e->{pvid}) {
                _bad($where, 'pvid must be 1-4094') unless _int_in($e->{pvid}, 1, 4094);
                $nic{pvid} = $e->{pvid} + 0;
            }
            if (exists $e->{tagged}) {
                _bad($where, 'tagged must be a list of VLAN ids 1-4094') unless ref $e->{tagged} eq 'ARRAY';
                my %tseen;
                for my $t (@{ $e->{tagged} }) {
                    _bad($where, 'tagged must be a list of VLAN ids 1-4094') unless _int_in($t, 1, 4094);
                    _bad($where, "tagged VLAN $t is listed twice or is also the pvid")
                        if $tseen{ $t + 0 }++ || (exists $nic{pvid} && $nic{pvid} == $t);
                }
                $nic{tagged} = [ map { $_ + 0 } @{ $e->{tagged} } ];
            }
            if (exists $e->{model}) {
                _bad($where, 'model must be virtio, e1000e or rtl8139') unless _plain($e->{model}) && $NIC_MODELS{ $e->{model} };
                $nic{model} = "$e->{model}";
            }
        }
        else { $n = $e }
        _bad($where, "net names must match $NAME_RE") unless _plain($n) && $n =~ $NAME_RE;
        if ($layout_given) {
            _bad($where, "net '$n' is not in the cluster's network_layout")
                unless ref $layout eq 'HASH' && ref $layout->{$n} eq 'HASH' && _plain($layout->{$n}{bridge});
            my $fabric = defined $layout->{$n}{kind} && $layout->{$n}{kind} eq 'fabric';
            _bad($where, "net '$n' is a fabric (emulated switch): its NIC needs a pvid") if $fabric && !exists $nic{pvid};
            _bad($where, "net '$n' is not a fabric: pvid and tagged apply only to a fabric port")
                if !$fabric && (exists $nic{pvid} || exists $nic{tagged});
        }
        push @names, "$n";
        push @nics, { net => "$n", %nic };
    }
    my %hw;
    if (exists $vm->{hardware}) {
        my $h = $vm->{hardware};
        _bad($where, 'hardware must be an object') unless ref $h eq 'HASH';
        _only("$where hardware", $h, \%HWK);
        if (exists $h->{disk_bus}) {
            _bad($where, 'hardware disk_bus must be virtio, scsi or sata') unless _plain($h->{disk_bus}) && $DISK_BUSES{ $h->{disk_bus} };
            _bad($where, 'hardware disk_bus scsi/sata needs a disk') if $h->{disk_bus} ne 'virtio' && !@d;
            $hw{disk_bus} = "$h->{disk_bus}";
        }
        if (exists $h->{smbios}) {
            my $sm = $h->{smbios};
            _bad($where, 'hardware smbios must be an object') unless ref $sm eq 'HASH';
            _only("$where hardware smbios", $sm, \%SMK);
            for my $k (qw(vendor product)) {
                _bad($where, "hardware smbios $k is required") unless exists $sm->{$k};
            }
            for my $k (sort keys %$sm) {
                _bad($where, "hardware smbios $k must match $SMBIOS_RE (letters, digits, space, . _ -)")
                    unless _plain($sm->{$k}) && $sm->{$k} =~ $SMBIOS_RE;
            }
            $hw{smbios} = { map { $_ => "$sm->{$_}" } keys %$sm };
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
    # A storage provider: a network-boot VM with disks of its own (a nested
    # node that builds its pool on them: a nested SCH, or a nested IPS). It
    # starts first and stops last by default (priority 1, else 3), and at one
    # priority it starts before and stops after the consumers (_ordered;
    # vm-start --provides-storage for the node's shutdown order).
    my $provides = ($net_boot && @d) ? 1 : 0;
    $prio //= $provides ? 1 : 3;
    return { name => "$vm->{name}", memory_mib => $vm->{memory_mib} + 0, vcpus => $vm->{vcpus} + 0,
        boot => $boot, (defined $vm->{image} ? (image => "$vm->{image}") : ()), disks => \@d, nets => \@names,
        ($has_obj ? (nics => \@nics) : ()), (%hw ? (hardware => \%hw) : ()),
        priority => $prio + 0, provides_storage => $provides, compute => $compute };
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

# new(registry, keysafe, storage => sub ($host) -> HPS::Storage-like,
#     runner => obj with call(mac, script, args, input), logger => sub ($level, $msg),
#     now => sub, images_dir => DIR, ips_url => URL, allow_any_pool_name => 0|1, by => NAME)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $ks  = $opt{keysafe}  // HPS::Keysafe->new(registry => $reg);
    my $runner = $opt{runner} // HPS::Storage::Runner::HpsRun->new;
    my $logger = $opt{logger} // \&_default_logger;
    my $now    = $opt{now} // sub { time };
    my $any    = $opt{allow_any_pool_name} ? 1 : 0;
    my $storage = $opt{storage} // sub ($host) {
        return HPS::Storage->new(host => $host, registry => $reg, keysafe => $ks,
            runner => $runner, logger => sub ($l, $m) { $logger->($l, "storage: $m") }, now => $now,
            allow_any_pool_name => $any);
    };
    _fail('usage', 'storage must be a code ref returning a storage object for a host') unless ref $storage eq 'CODE';
    my $res = $ENV{HPS_RESOURCES} // (($ENV{HPS_BASE} // '/srv') . '/hps-resources');
    return bless {
        registry => $reg, keysafe => $ks, storage => $storage, runner => $runner,
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

# _checked($name, $text, $what): the checked definition of workload <name> from
# its JSON text. The one check of a definition: load() (create and every other
# operation) and define() both use it.
sub _checked ($self, $name, $text, $what) {
    my $def = eval { JSON::PP->new->utf8->decode($text) };
    _fail('refused', "$what is not valid JSON") unless defined $def;
    my $ok = validate($def, layout => $self->layout);
    _fail('refused', "workload: name '$ok->{name}' differs from the file name '$name'") unless $ok->{name} eq $name;
    return $ok;
}

sub _read_definition ($self, $name) {
    my $path = $self->definition_path($name);
    _fail('notfound', "no workload definition: $path") unless -f $path;
    open(my $fh, '<:raw', $path) or _fail('failed', "cannot read $path: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    return ($path, $text // '');
}

# load($name): the checked definition from workloads/<name>.json.
sub load ($self, $name) {
    my ($path, $text) = $self->_read_definition($name);
    return $self->_checked($name, $text, $path);
}

# show_definition($name): the stored JSON text of workloads/<name>.json, as it is.
sub show_definition ($self, $name) {
    my (undef, $text) = $self->_read_definition($name);
    return $text;
}

# The largest definition define() takes, in bytes.
our $MAX_DEFINITION_BYTES = 1024 * 1024;

# define($name, $text, replace => 0|1, dry_run => 0|1): check the JSON text as
# create checks a definition (_checked), then write it to workloads/<name>.json
# through a temporary file and a rename. An existing definition is replaced
# only with replace, and never while the workload exists (a registry record:
# created, creating or partial; destroy removes it). A new file is mode 0664
# with the directory's group (the shared hps group, HPS::Registry::mkdir_p); a
# replaced file keeps its own mode, owner and group. dry_run checks everything
# and writes nothing. Returns {name, path, replaced, written, dry_run, vms}.
sub define ($self, $name, $text, %a) {
    my $path = $self->definition_path($name);
    _fail('refused', 'no definition: the JSON definition is the input') unless defined $text && length $text;
    _fail('refused', "the definition is larger than $MAX_DEFINITION_BYTES bytes") if length $text > $MAX_DEFINITION_BYTES;
    my $def = $self->_checked($name, $text, 'the definition');
    my $exists = -e $path || -l $path;
    _fail('refused', "workload '$name' is already defined ($path); give --replace to overwrite it")
        if $exists && !$a{replace};
    if ($a{replace}) {
        my $rec = $self->record($name);
        _fail('refused', "workload '$name' exists (state $rec->{state}); destroy it before replacing its definition")
            if defined $rec;
    }
    _fail('refused', "$path is not a regular file") if $exists && (-l $path || !-f $path);
    my $out = { name => $name, path => $path, replaced => $exists ? 1 : 0, dry_run => $a{dry_run} ? 1 : 0,
        written => 0, vms => [ map { $_->{name} } @{ $def->{vms} } ] };
    return $out if $a{dry_run};

    $text .= "\n" unless $text =~ /\n\z/;
    my $dir = $self->{registry}->workload_dir($self->_cluster);
    HPS::Registry::mkdir_p($dir);
    my @old = $exists ? stat $path : ();
    my $tmp = "$dir/.$name.json.$$.tmp";
    my $ok = eval {
        sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or die "cannot create $tmp: $!\n";
        binmode $fh;
        print {$fh} $text or die "cannot write $tmp: $!\n";
        close $fh or die "cannot close $tmp: $!\n";
        if (@old) {
            chown($old[4], $old[5], $tmp) if $> == 0;
            chmod($old[2] & 07777, $tmp) or die "cannot chmod $tmp: $!\n";
        }
        else {
            my $gid = (stat $dir)[5];
            chown(-1, $gid, $tmp);    # best effort: a member of the group, or root
            chmod(0664, $tmp) or die "cannot chmod $tmp: $!\n";
        }
        rename($tmp, $path) or die "cannot rename $tmp to $path: $!\n";
        1;
    };
    my $err = $@;
    if (!$ok) {
        unlink $tmp;
        $err =~ s/\s+\z//;
        _fail('failed', $err);
    }
    $out->{written} = 1;
    $self->_log('info', ($exists ? 'replaced' : 'defined') . " workload $name: $path");
    return $out;
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
    my $has_pool = $first_local || $reg->host_exists($mac, 'storage_pool');
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
        # A thin compute host (every leg remote, no pool of its own) caches the
        # base image in RAM: it is read once, by vm-image-write (scale test
        # probes, 2026-11-12: "cannot create 's1/enc/images': no such pool").
        image_dir => ($has_pool ? "/$pool/enc/images" : '/run/hps/images') };
}

# VMs in start order (priority 1 first; at one priority the storage providers
# first; then definition order); the selected --vm only, else all. Stop is the
# reverse.
sub _ordered ($self, $def, %a) {
    my $i = 0;
    my @vms = map { $_->[1] } sort { $a->[0] <=> $b->[0] || $a->[3] <=> $b->[3] || $a->[2] <=> $b->[2] }
        map { [ $_->{priority}, $_, $i++, ($_->{provides_storage} ? 0 : 1) ] } @{ $def->{vms} };
    if (defined $a{vm}) {
        @vms = grep { $_->{name} eq $a{vm} } @vms;
        _fail('notfound', "workload '$def->{name}' has no VM '$a{vm}'") unless @vms;
    }
    return @vms;
}

#=== steps ============================================================================

# A step: {host (MAC), script, args, key, ok_rc, before, after, undo (on failure),
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

# The vm-define arguments of NIC $i: --net <bridge>, its --mac when given (a
# re-define keeps the recorded MAC), then its per-NIC options.
sub _net_args ($self, $layout, $vm, $i, $mac = undef) {
    my $nic = $vm->{nics} ? $vm->{nics}[$i] : {};
    return ('--net', $layout->{ $vm->{nets}[$i] }{bridge}, (defined $mac ? ('--mac', $mac) : ()),
        (defined $nic->{model} ? ('--nic-model', $nic->{model}) : ()),
        (defined $nic->{pvid} ? ('--vlan-pvid', $nic->{pvid}) : ()),
        ($nic->{tagged} && @{ $nic->{tagged} } ? ('--vlan-tagged', join(',', @{ $nic->{tagged} })) : ()));
}

# The VM-level hardware options of vm-define.
sub _hardware_args ($vm) {
    my $hw = $vm->{hardware} or return ();
    my $sm = $hw->{smbios};
    return ((defined $hw->{disk_bus} ? ('--disk-bus', $hw->{disk_bus}) : ()),
        ($sm ? ('--smbios', join(',', map { "$_=$sm->{$_}" } grep { defined $sm->{$_} } qw(vendor product serial))) : ()));
}

# The vm-define arguments of a VM: create's, and a re-define's (start after the
# compute host lost its libvirt definitions), from the one builder. $macs: the
# recorded MAC per NIC, in nets order (a re-define), else none (libvirt makes them).
sub _define_args ($self, $layout, $vm, $in, $macs = undef) {
    my $net_boot = $vm->{boot} eq 'network';
    return [ $vm->{name}, '--memory', $vm->{memory_mib}, '--vcpus', $vm->{vcpus},
        ($net_boot ? ('--boot', 'network') : ()),
        (map { ('--disk', $_->{device}) } @{ $in->{disks} }),
        (map { $self->_net_args($layout, $vm, $_, $macs ? $macs->[$_] : undef) } 0 .. $#{ $vm->{nets} }),
        ($net_boot ? () : ('--image', "$in->{image_dir}/$vm->{image}.qcow2")), _hardware_args($vm) ];
}

# The net-vxlan-ensure calls for the vxlan nets of a VM on its compute host
# (HPS::Vxlan::host_plan: local and peers from the transit addresses), once per
# host and net (%$seen). A compute host that cannot carry one refuses the plan.
sub _vxlan_calls ($self, $vm, $mac, $seen) {
    my $layout = $self->layout;
    my @want = grep { HPS::Vxlan::is_vxlan($layout, $_) && !$seen->{"$mac $_"}++ } @{ $vm->{nets} };
    return () unless @want;
    my %u;
    @want = grep { !$u{$_}++ } @want;
    my @plan = HPS::Vxlan::host_plan($self->{registry}, $mac, layout => $layout, only => \@want, cluster => $self->_cluster);
    for my $x (grep { $_->{refused} } @plan) {
        _fail('refused', "vm '$vm->{name}': net '$x->{name}' (vxlan $x->{vni}) cannot be built on compute host '$vm->{compute}': $x->{refused}");
    }
    return @plan;
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
    my (@s, %fetched, %attached, %vx);
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
        # vxlan nets are not host nets: net-vxlan-ensure builds them (below).
        my @missing = grep { my $n = $_; !HPS::Vxlan::is_vxlan($layout, $n) && !grep { $_ eq $n } @$have } @{ $vm->{nets} };
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
        push @s, map { _step($mac, $_->{script}, $_->{args}, key => "vxlan:$mac:$_->{name}") } $self->_vxlan_calls($vm, $mac, \%vx);
        my ($wl, $vmname) = ($name, $vm->{name});
        my $args = $self->_define_args($layout, $vm, $in);
        push @s, _step($mac, 'vm-define', $args, key => "define:$vm->{name}",
            after => sub ($r) {
                # Kept: a re-define (start) checks the definition against them.
                $self->_rec_update($wl, sub ($rec) { $rec->{vms}{$vmname}{define} = [ map {"$_"} @$args ] });
                $self->_record_macs($wl, $vmname, $r) if $net_boot;
            });
    }
    return @s;
}

# Why the recorded VM cannot be re-defined from this definition (the definition
# was edited since create, or the record lacks the VM), else undef. Compared:
# compute host, disk names, devices and leg specs, the MAC count, and, for
# records whose create stored them, the whole vm-define argument list.
sub _redefine_mismatch ($self, $rv, $vm, $in, $args) {
    return 'the workload record has no entry for it' unless ref $rv eq 'HASH';
    return "the record has compute host '" . ($rv->{host} // '') . "', the definition '$vm->{compute}'"
        if ($rv->{host} // '') ne $vm->{compute};
    my %rd = %{ $rv->{disks} // {} };
    my $have = join(',', sort keys %rd);
    my $want = join(',', sort map { $_->{name} } @{ $in->{disks} });
    return "the record has disks [$have], the definition [$want]" if $have ne $want;
    for my $d (@{ $in->{disks} }) {
        my $r = $rd{ $d->{name} };
        return "disk '$d->{name}': the record has device " . ($r->{md} // '-') . ", the definition $d->{device}"
            if ($r->{md} // '') ne $d->{device};
        my ($rl, $dl) = (join(' ', @{ $r->{legs} // [] }), join(' ', @{ $d->{specs} }));
        return "disk '$d->{name}': the record has legs $rl, the definition $dl" if $rl ne $dl;
    }
    my $macs = $rv->{macs};
    return 'the record has ' . scalar(@$macs) . ' MAC(s), the definition ' . scalar(@{ $vm->{nets} }) . ' NIC(s)'
        if ref $macs eq 'ARRAY' && @$macs && @$macs != @{ $vm->{nets} };
    if (ref $rv->{define} eq 'ARRAY') {
        my ($was, $now) = (join(' ', @{ $rv->{define} }), join(' ', @$args));
        return "its vm-define arguments differ from the ones create used (create: $was; now: $now)" if $was ne $now;
    }
    return undef;
}

# The MACs of a VM from vm-status's NIC lines (NIC <vm> <index> <tap> <bridge> <mac> ...), in index order.
sub _status_macs ($stdout, $vm) {
    my %m = ($stdout // '') =~ /^NIC \Q$vm\E ([0-9]+) \S+ \S+ ([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b/mg;
    return map { $m{$_} } sort { $a <=> $b } keys %m;
}

# start: per VM, mirror-assemble (mirrored disks only), then vm-status
# (read-only). A VM its compute host does not have defined (vm-status exit 4:
# the node runs from RAM and lost libvirt's definitions in a reboot; the zvols
# and legs are still there) is re-defined with vm-define from the definition
# and the record: create's arguments (_define_args), the recorded MACs (--mac
# per NIC), no zvol create and no image write. Then vm-start. A definition that
# no longer matches the record refuses the re-define, and only then. A defined
# VM is started as before; when the record has no MACs for it (a disk-boot VM),
# vm-status's are recorded so a later re-define keeps them.
sub _steps_start ($self, $def, %a) {
    my $rec = $self->_need_record($def->{name}, 'start');
    my $layout = $self->layout;
    my (@s, %vx);
    for my $vm ($self->_ordered($def, %a)) {
        my $in = $self->_vm_info($def, $vm);
        # The compute host runs from RAM: a reboot lost its VXLAN links, and the
        # peers may have changed. Idempotent, so every start runs it.
        push @s, map { _step($in->{mac}, $_->{script}, $_->{args}) } $self->_vxlan_calls($vm, $in->{mac}, \%vx);
        for my $d (grep { $_->{mirrored} } @{ $in->{disks} }) {
            push @s, _step($in->{mac}, 'mirror-assemble', [ $d->{mirror}, map { ('--leg', $_) } @{ $d->{specs} } ]);
        }
        my ($n, $host) = ($def->{name}, $vm->{compute});
        my $vname = $vm->{name};
        my $rv = $rec->{vms}{$vname};
        my $macs = ref $rv eq 'HASH' && ref $rv->{macs} eq 'ARRAY' && @{ $rv->{macs} } ? [ @{ $rv->{macs} } ] : undef;
        my $why = $self->_redefine_mismatch($rv, $vm, $in, $self->_define_args($layout, $vm, $in));
        my $missing = 0;
        my $keep_macs = sub ($r) {
            my @m = _status_macs($r->{stdout}, $vname);
            $self->_rec_update($n, sub ($x) { $x->{vms}{$vname}{macs} = [@m] }) if @m && $r->{rc} == 0;
        };
        push @s, _step($in->{mac}, 'vm-status', [$vname], ok_rc => [4], seen => sub ($r) {
            $missing = $r->{rc} == 4 ? 1 : 0;
            $keep_macs->($r) unless $missing || $macs;
        });
        my $only = "only if vm-status reports $vname not defined (its compute host rebooted)";
        push @s, _step($in->{mac}, 'vm-define', $self->_define_args($layout, $vm, $in, $macs),
            when => sub { $missing },
            only => $only . ($macs ? '; with the recorded MACs' : '; no MACs recorded: libvirt makes new ones')
                . (defined $why ? "; refused then: $why" : ''),
            (defined $why ? (refuse => "start: VM $vname is not defined on its compute host and cannot be re-defined: $why. "
                . 'Put back the definition it was created with, or destroy and create the workload') : ()),
            before => sub { $self->_log('notice', "start $n: VM $vname is not defined on $host; re-defining it from the definition and the record") });
        push @s, _step($in->{mac}, 'vm-status', [$vname], when => sub { $missing }, seen => $keep_macs,
            only => "$only, and no MACs were recorded: records the new ones") unless $macs;
        # The priority and role go to the node: hps-shutdown-storage stops its
        # guests in that order (docs/WORKLOADS.md "Stop order on a node").
        push @s, _step($in->{mac}, 'vm-start', [ $vm->{name}, '--priority', $vm->{priority},
            ($vm->{provides_storage} ? ('--provides-storage') : ()) ],
            fallback_args => [ $vm->{name} ], after => sub {
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

# The zvols of the local legs go through HPS::Storage (its zvol-destroy refusals hold).
sub _steps_destroy ($self, $def, %a) {
    $self->_need_record($def->{name}, 'destroy');
    my $rec = $self->record($def->{name});
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
            # destroy throws the guest away: after vm-stop's graceful wait it is
            # forced off (a guest that ignores ACPI blocked destroy for good).
            push @s, _step($in->{mac}, 'vm-stop', [ $vm->{name}, '--force' ], ok_rc => [4]),
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
        push @s, _step($mac, 'storage-zvol-destroy', [$ds], key => "zvol:$ds",
            storage => [ 'zvol-destroy', dataset => $ds ]);
    }
    return @s;
}

# grow-disk: one disk of one VM to a new size, while the workload runs. The
# zvol of the disk's local leg grows through HPS::Storage (storage-zvol-grow,
# which never shrinks), then vm-disk-resize tells the guest. The filesystem
# inside the guest is the guest's business (cnh-disk-grow on a container host).
# Only a disk of one leg (always local): a mirrored disk would need both legs
# and the md grown.
sub _steps_grow_disk ($self, $def, %a) {
    $self->_need_record($def->{name}, 'grow-disk');
    _fail('usage', 'grow-disk needs a VM, a disk and a new size') unless defined $a{vm} && defined $a{disk} && defined $a{size};
    _fail('usage', "size '$a{size}' is not like 64G (M, G or T)") unless $a{size} =~ $SIZE_RE;
    my ($vm) = $self->_ordered($def, vm => $a{vm});
    my $in = $self->_vm_info($def, $vm);
    my ($d) = grep { $_->{name} eq $a{disk} } @{ $in->{disks} };
    _fail('notfound', "VM '$vm->{name}' of workload '$def->{name}' has no disk '$a{disk}'") unless $d;
    _fail('refused', "disk '$d->{name}' is mirrored ($d->{mirror}): grow-disk grows a single local zvol only")
        if $d->{mirrored};
    my $stor = $self->_st($vm->{compute});
    my $shown = $stor->plan('zvol-grow', dataset => $d->{dataset}, size => $a{size})->[0];
    $self->{notes} = [ "the definition still says $d->{size} for $vm->{name}/$d->{name}; a later create (after destroy) makes it at that size" ];
    return (
        _step($in->{mac}, $shown->{script}, $shown->{args}, storage => [ 'zvol-grow', dataset => $d->{dataset}, size => $a{size} ]),
        _step($in->{mac}, 'vm-disk-resize', [ $vm->{name}, $d->{device} ]),
    );
}

my %STEPS = (create => '_steps_create', start => '_steps_start', stop => '_steps_stop',
    destroy => '_steps_destroy', status => '_steps_status', 'grow-disk' => '_steps_grow_disk');

sub _prepare ($self, $op, $name, %a) {
    my $m = $STEPS{ $op // '' } // _fail('usage', 'unknown operation; one of: ' . join(', ', ops()));
    _fail('usage', '--vm is not for ' . $op) if defined $a{vm} && ($op eq 'create' || $op eq 'destroy');
    _fail('usage', '--resume is only for create') if $a{resume} && $op ne 'create';
    _fail('usage', '--forget is only for destroy') if $a{forget} && $op ne 'destroy';
    _fail('usage', '--disk and --size are only for grow-disk') if (defined $a{disk} || defined $a{size}) && $op ne 'grow-disk';
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
        { n => $n, host => $_->{host}, script => $s->{script}, args => [ @{ $s->{args} } ], input => $s->{input},
          (defined $_->{only} ? (only => $_->{only}) : ()) }
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
        return { dry_run => 1, op => $op, name => $name, plan => $plan, ($op eq 'destroy' || $op eq 'grow-disk' ? (notes => $self->{notes} // []) : ()) };
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
        # A conditional step (when): skipped when not needed; refused when needed
        # but impossible (refuse).
        if ($st->{when} && !$st->{when}->()) {
            push @results, { n => $n, host => $st->{host}, script => $st->{script}, args => $st->{args}, rc => 0,
                stdout => '', stderr => '', skipped => 1, not_needed => 1 };
            next;
        }
        if (defined $st->{refuse}) {
            $self->_log('err', $st->{refuse});
            _fail('refused', $st->{refuse});
        }
        $self->_rec_update($name, sub ($rec) { $rec->{attempting} = $st->{key} }) if $op eq 'create' && $st->{key};
        my $r = $self->_run_step($st, $n, scalar(@steps), $op);
        # A node on an older image may not know a newer option (exit 2, usage):
        # retry once with the plain form the step carries (2026-11-12: sch-001's
        # vm-start predated --priority and every start on it failed).
        if ($r->{rc} == 2 && $st->{fallback_args}) {
            $self->_log('notice', "$op $name: $st->{script} on $st->{host} does not take the newer options; "
                . 'running it in its older form (update the node\'s image for the full behaviour)');
            push @{ $self->{notes} }, "$st->{script} on $st->{host}: older node image, started without its newer options";
            $st = { %$st, args => $st->{fallback_args} };
            $r = $self->_run_step($st, $n, scalar(@steps), $op);
        }
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
        $st->{seen}->($r) if $st->{seen};    # every accepted exit (ok_rc included)
        $st->{after}->($r) if $st->{after} && $r->{rc} == 0;
        if ($op eq 'create' && $st->{key}) {
            $done{ $st->{key} } = 1;
            $self->_rec_update($name, sub ($rec) { push @{ $rec->{done} }, $st->{key}; delete $rec->{attempting} });
        }
    }
    my $out = { op => $op, name => $name, ok => 1, steps => \@results, ($op eq 'destroy' || $op eq 'grow-disk' ? (notes => $self->{notes} // []) : ()) };
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
        $self->{registry}->cluster_unset($self->_cluster, _rec_key($name));
        $self->{registry}->cluster_set($self->_cluster, _destroyed_key($name),
            { at => $self->_stamp, by => $self->{by}, forgotten => $a{forget} ? JSON::PP::true : JSON::PP::false });
        # The definition is the operator's intent: it stays unless --forget.
        if ($a{forget}) {
            unlink $self->definition_path($name);
            $out->{forgotten} = 1;
        }
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
