package HPS::Workload::List;
# Read-only views over the workload records of the active cluster (IPS-35 #2,
# #3, #14): list, VM addresses from the IPS's dnsmasq leases, the image
# catalogue, and what the guests placed on a compute host have committed.
# Every function takes an HPS::Workload object ($wl) for its registry, cluster,
# layout, images directory and clock. Nothing here writes or calls a node.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use POSIX qw(strftime);

my $MAC_RE = qr/^[0-9a-f]{2}(?::[0-9a-f]{2}){5}\z/;

sub leases_file () { return $ENV{HPS_DNSMASQ_LEASES} // '/var/lib/misc/dnsmasq.leases' }

# leases($file, $now): {mac => {ip, expiry, name}} from a dnsmasq leases file
# (expiry mac ip name client-id). An expired lease (expiry 0 means never) is
# not a lease; of several for one MAC the latest expiry wins. A missing or
# unreadable file is no leases.
sub leases ($file, $now) {
    my %l;
    open(my $fh, '<', $file) or return {};
    while (my $line = <$fh>) {
        my ($exp, $mac, $ip, $name) = split ' ', $line;
        next unless defined $ip && $exp =~ /^[0-9]+\z/ && lc($mac) =~ $MAC_RE && $ip =~ /^[0-9]{1,3}(?:\.[0-9]{1,3}){3}\z/;
        next if $exp > 0 && $exp < $now;
        $mac = lc $mac;
        my $rank = $exp == 0 ? 1e18 : $exp;
        next if $l{$mac} && $l{$mac}{rank} >= $rank;
        $l{$mac} = { ip => $ip, expiry => $exp + 0, name => (defined $name && $name ne '*' ? $name : undef), rank => $rank };
    }
    close $fh;
    delete $_->{rank} for values %l;
    return \%l;
}

# The NICs of a recorded VM in index order: [{net, mac}], from the --net
# bridges of its recorded vm-define arguments and its recorded MACs. net is the
# layout network of that bridge (the bridge itself when the layout has none).
sub nics ($rv, $layout) {
    my @bridge;
    my @a = @{ $rv->{define} // [] };
    for my $i (0 .. $#a - 1) { push @bridge, $a[ $i + 1 ] if $a[$i] eq '--net' }
    my %net_of = map { ref $layout->{$_} eq 'HASH' && defined $layout->{$_}{bridge} ? ($layout->{$_}{bridge} => $_) : () } keys %{ $layout // {} };
    my @mac = @{ $rv->{macs} // [] };
    return map { +{ net => $net_of{ $bridge[$_] // '' } // $bridge[$_], mac => lc $mac[$_] } } 0 .. $#mac;
}

# addresses($rv, $layout, $leases): [{net, mac, ip, source => 'dhcp-lease'}] for
# the NICs of the VM that hold a lease; empty when none. Never a guess.
sub addresses ($rv, $layout, $leases) {
    return [ map { +{ net => $_->{net}, mac => $_->{mac}, ip => $leases->{ $_->{mac} }{ip}, source => 'dhcp-lease' } }
        grep { $leases->{ $_->{mac} } } nics($rv, $layout) ];
}

# annotate_status($wl, $rec, $vms): each status VM gets addresses.
sub annotate_status ($wl, $rec, $vms) {
    my $leases = leases(leases_file(), $wl->{now}->());
    my $layout = $wl->layout;
    $_->{addresses} = addresses($rec->{vms}{ $_->{vm} } // {}, $layout, $leases) for @$vms;
    return;
}

# The names of the recorded workloads of the cluster.
sub names ($wl) {
    return grep { /^[a-z][a-z0-9-]{0,31}\z/ } map { /^workload_(.+)\z/ ? $1 : () } $wl->{registry}->cluster_list($wl->_cluster);
}

sub _project ($wl, $name) {
    my $path = eval { $wl->definition_path($name) } // return undef;
    open(my $fh, '<:raw', $path) or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP->new->utf8->decode($text) };
    return ref $d eq 'HASH' && defined $d->{project} && !ref $d->{project} ? "$d->{project}" : undef;
}

# list($wl, project => P): [{name, project, state, hosts, vms, addresses,
# created_at}] by name. project is null where the definition is gone.
sub list ($wl, %a) {
    my $leases = leases(leases_file(), $wl->{now}->());
    my $layout = $wl->layout;
    my @out;
    for my $name (names($wl)) {
        my $rec = $wl->record($name) // next;
        next unless ref $rec eq 'HASH';
        my $project = _project($wl, $name);
        next if defined $a{project} && (!defined $project || $project ne $a{project});
        my $vms = $rec->{vms} // {};
        my %host = map { defined $_->{host} ? ($_->{host} => 1) : () } values %$vms;
        my @addr;
        for my $vm (sort keys %$vms) {
            push @addr, map { +{ vm => $vm, %$_ } } @{ addresses($vms->{$vm}, $layout, $leases) };
        }
        push @out, { name => $name, project => $project, state => $rec->{state}, class => HPS::Workload::class_of($rec), hosts => [ sort keys %host ],
            vms => scalar(keys %$vms), addresses => \@addr, created_at => $rec->{created_at} };
    }
    return \@out;
}

sub render_list ($rows) {
    return "no workloads\n" unless @$rows;
    my @h = qw(NAME PROJECT STATE CLASS HOST VMS ADDRESS CREATED);
    my @r = map { [ $_->{name}, $_->{project} // '-', $_->{state} // '-', $_->{class} // '?', join(',', @{ $_->{hosts} }) || '-', $_->{vms},
        (@{ $_->{addresses} } ? $_->{addresses}[0]{ip} : '-'), $_->{created_at} // '-' ] } @$rows;
    my @w = map { my $c = $_; (sort { $b <=> $a } map { length $_->[$c] } \@h, @r)[0] } 0 .. $#h;
    my $line = sub ($r) { return join('  ', map { sprintf('%-*s', $w[$_], $r->[$_]) } 0 .. $#h) =~ s/\s+\z//r . "\n" };
    return $line->(\@h) . join('', map { $line->($_) } @r);
}

#--- the image catalogue ---------------------------------------------------------

# images($dir): [{name, size, sha256, mtime}] for every <name>.qcow2 with its
# <name>.sha256 (sha256 null when that file is missing or malformed).
sub images ($dir) {
    my @out;
    opendir(my $dh, $dir) or return [];
    for my $f (sort grep { /^(?!\.).+\.qcow2\z/ } readdir $dh) {
        next unless -f "$dir/$f";
        my $name = $f =~ s/\.qcow2\z//r;
        my @st = stat "$dir/$f";
        my $hex;
        if (open(my $fh, '<', "$dir/$name.sha256")) {
            my $l = <$fh> // '';
            close $fh;
            ($hex) = $l =~ /^([0-9a-fA-F]{64})(?:\s|\z)/;
        }
        push @out, { name => $name, size => $st[7], sha256 => defined $hex ? lc $hex : undef,
            mtime => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $st[9]) };
    }
    closedir $dh;
    return \@out;
}

sub render_images ($rows) {
    return "no images in the catalogue\n" unless @$rows;
    return join('', map { sprintf("%-32s %12d  %s  %s\n", $_->{name}, $_->{size}, $_->{mtime}, $_->{sha256} // 'no checksum') } @$rows);
}

# check_images($wl, $def): refuse a definition naming an image the catalogue
# does not hold (a <name>.qcow2 and its <name>.sha256 in the images directory).
sub check_images ($wl, $def) {
    my %have = map { defined $_->{sha256} ? ($_->{name} => 1) : () } @{ images($wl->{images_dir}) };
    for my $vm (@{ $def->{vms} }) {
        next unless defined $vm->{image} && !$have{ $vm->{image} };
        my @names = map { $_->{name} } @{ images($wl->{images_dir}) };
        die HPS::Keysafe::Error->new('refused', "vm $vm->{name}: image '$vm->{image}' is not in the catalogue (hps-workload images lists it"
            . (@names ? ": " . join(', ', @names) : ', and it is empty') . ")");
    }
    return;
}

#--- committed guest resources (hps-node resources) ------------------------------

# committed($reg, $cluster, $host_mac): sums over the defined guests recorded
# on that compute host (record host is its MAC or HOSTNAME), running or not.
sub committed ($reg, $cluster, $mac) {
    my $name = $reg->host_exists($mac, 'HOSTNAME') ? $reg->host_get($mac, 'HOSTNAME') : '';
    (my $flat = lc $mac) =~ s/://g;
    my %c = (vcpus => 0, mem_mib => 0, guests => 0, running_mem_mib => 0, running => 0);
    for my $k ($reg->cluster_list($cluster)) {
        next unless $k =~ /^workload_[a-z][a-z0-9-]{0,31}\z/;
        my $rec = $reg->cluster_get_json($cluster, $k);
        next unless ref $rec eq 'HASH';
        for my $rv (values %{ $rec->{vms} // {} }) {
            my $h = $rv->{host} // next;
            (my $hf = lc $h) =~ s/://g;
            next unless $hf eq $flat || (length $name && $h eq $name);
            my @def = ref $rv->{define} eq 'ARRAY' ? @{ $rv->{define} } : ();
            my ($mem, $cpu);
            for my $i (0 .. $#def - 1) {
                $mem = $def[ $i + 1 ] if $def[$i] eq '--memory';
                $cpu = $def[ $i + 1 ] if $def[$i] eq '--vcpus';
            }
            next unless defined $mem && $mem =~ /^[0-9]+\z/;
            $c{guests}++;
            $c{mem_mib} += $mem;
            $c{vcpus} += $cpu if defined $cpu && $cpu =~ /^[0-9]+\z/;
            if (($rv->{state} // '') eq 'running') { $c{running}++; $c{running_mem_mib} += $mem }
        }
    }
    return \%c;
}

# committed_line($c, $stdout): the COMMITTED line; free_mem_mib is the
# RESERVE line's guest_mem_max_mib less the committed memory ("-" without it).
sub committed_line ($c, $stdout) {
    my ($max) = ($stdout // '') =~ /^RESERVE .*\bguest_mem_max_mib=([0-9]+)/m;
    return "COMMITTED vcpus=$c->{vcpus} mem_mib=$c->{mem_mib} guests=$c->{guests} free_mem_mib="
        . (defined $max ? $max - $c->{mem_mib} : '-')
        . " running_guests=$c->{running} running_mem_mib=$c->{running_mem_mib}\n";
}

1;
