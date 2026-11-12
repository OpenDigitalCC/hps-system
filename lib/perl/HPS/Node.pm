package HPS::Node;
# IPS-side node power control. power_off() shuts a node down so that its data
# is safe: storage down (HPS::Storage 'down'), then the node script
# node-poweroff over ctrl-exec (systemctl poweroff; the node's own shutdown unit
# stops guests and mirrors and exports the pools), then it waits for the BMC to
# report Off (hps-bmc, IPS-08) and forces power off only after force_after
# seconds, logged as a fault. With no BMC driver it stops after the node script
# and says the power state is not confirmed. net_up() gives a NixOS host its
# addresses on the storage and transit VLANs (net-vlan-address per network),
# then, on a transit host, builds the layout's vxlan networks
# (net-vxlan-ensure, HPS::Vxlan) and refreshes the other transit hosts' peers.
# One net-up at a time per host: net_up holds an flock on
# <jobs>/run/net-up-<mac>.lock (IPS-34 item 7: the pairing job and an operator
# net-up raced and each failed to create the other's interface).
#
# Every collaborator is injectable (storage, runner, bmc, logger, now, sleep) so
# the sequence is testable without a node, a BMC or a clock.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use POSIX qw(strftime);
use JSON::PP;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use HPS::Jobs ();
use HPS::Registry;
use HPS::Storage;
use HPS::ClusterConfig ();
use HPS::Vxlan ();

our $DEFAULT_FORCE_AFTER = 120;

# Result codes of power_off(): the CLI's exit status.
our %CODE = (off => 0, 'no-bmc' => 0, failed => 1, forced => 6);

# new(host => MAC|HOSTNAME, registry => $reg, storage => $obj (has run('down')),
#     runner => $obj (call(mac, script, args)), bmc => $obj (run($action, $host)),
#     logger => sub ($level, $msg), now => sub, sleep => sub ($s), poll => SECONDS,
#     lock_dir => DIR (net-up locks; default the jobs run/ dir),
#     lock_wait => SECONDS (how long net_up waits for another net-up; 300))
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $log = $opt{logger} // \&_default_logger;
    my $self = bless {
        host     => $opt{host},
        registry => $reg,
        logger   => $log,
        now      => $opt{now} // sub { time },
        sleep    => $opt{sleep} // sub ($s) { sleep $s },
        poll     => $opt{poll} // $ENV{HPS_NODE_POLL} // 5,
        bmc      => $opt{bmc} // HPS::Node::Bmc->new,
        lock_dir => $opt{lock_dir},
        lock_wait => $opt{lock_wait} // $ENV{HPS_NODE_LOCK_WAIT} // 300,
    }, $class;
    $self->{storage} = $opt{storage} // HPS::Storage->new(host => $opt{host}, registry => $reg, logger => $log);
    $self->{runner}  = $opt{runner}  // HPS::Storage::Runner::HpsRun->new;
    $self->{mac}     = $self->{storage}->mac;
    return $self;
}

sub mac ($self) { return $self->{mac} }

sub _default_logger ($level, $msg) {
    print STDERR "hps-node: $msg\n";
    return if $ENV{HPS_NODE_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-node: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub _record ($self, $result, $detail) {
    my $at = strftime('%Y-%m-%d %H:%M:%S UTC', gmtime($self->{now}->()));
    eval { $self->{registry}->host_set($self->{mac}, 'poweroff_last', { result => $result, at => $at, detail => $detail }) };
    return;
}

# The BMC power state: 'on', 'off' or 'unknown'; undef when there is no driver
# (command missing, or exit 5 "not supported by this device").
sub _power ($self) {
    my $r = $self->{bmc}->run('status', $self->{host}, '--json');
    return undef if $r->{missing} || $r->{rc} == 5;
    return 'unknown' if $r->{rc} != 0;
    my $doc = eval { JSON::PP->new->decode($r->{stdout}) };
    my $p = ref $doc eq 'HASH' ? $doc->{power} : undef;
    return defined $p && $p =~ /^(?:on|off)$/ ? $p : 'unknown';
}

# Poll until the BMC says off or the deadline passes. Returns 'off', 'timeout'
# or 'no-bmc'.
sub _wait_off ($self, $force_after) {
    my $deadline = $self->{now}->() + $force_after;
    while (1) {
        my $p = $self->_power;
        return 'no-bmc' unless defined $p;
        $self->_log('info', "BMC power state: $p");
        return 'off' if $p eq 'off';
        return 'timeout' if $self->{now}->() >= $deadline;
        $self->{sleep}->($self->{poll});
    }
}

sub _force_off ($self) {
    my $r = $self->{bmc}->run('force-off', $self->{host});
    return 0 if $r->{missing};
    $self->_log('error', "hps-bmc force-off exited $r->{rc}") if $r->{rc} != 0;
    return $r->{rc} == 0;
}

# power_off(force_after => SECONDS): returns {result => off|forced|no-bmc|failed,
# message}. 'failed' means the node was not (confirmed) powered off by a clean
# path and was not forced: the message says which step.
sub power_off ($self, %a) {
    my $force_after = $a{force_after} // $DEFAULT_FORCE_AFTER;
    my $host = $self->{host};
    $self->_log('info', "power-off $host: storage down");
    my $ok = eval { $self->{storage}->run('down'); 1 };
    unless ($ok) {
        my $e = $@;
        my $m = ref $e && $e->can('message') ? $e->message : $e;
        $m =~ s/\s+\z//;
        $self->_log('error', "power-off $host: storage down failed: $m; the node is not powered off");
        $self->_record('failed', "storage down: $m");
        return { result => 'failed', message => "storage down failed: $m" };
    }
    $self->_log('info', "power-off $host: node-poweroff");
    my $r = $self->{runner}->call(mac => $self->{mac}, script => 'node-poweroff', args => [], input => undef);
    if ($r->{rc} != 0) {
        my $last = (grep { length } split /\n/, ($r->{stderr} // ''))[-1] // '';
        $self->_log('error', "power-off $host: node-poweroff exited $r->{rc}" . (length $last ? ": $last" : ''));
        $self->_record('failed', "node-poweroff exit $r->{rc}");
        return { result => 'failed', message => "node-poweroff exited $r->{rc}" };
    }
    my $w = $self->_wait_off($force_after);
    if ($w eq 'no-bmc') {
        $self->_log('warning', "power-off $host: no BMC driver; poweroff was requested, power state not confirmed");
        $self->_record('no-bmc', 'poweroff requested; no BMC driver');
        return { result => 'no-bmc', message => 'poweroff requested on the node; no BMC driver, so power state is not confirmed' };
    }
    if ($w eq 'off') {
        $self->_log('info', "power-off $host: BMC reports off");
        $self->_record('off', 'clean');
        return { result => 'off', message => 'node is off (clean shutdown)' };
    }
    $self->_log('error', "FAULT power-off $host: not off after $force_after s; forcing power off through the BMC");
    unless ($self->_force_off) {
        $self->_record('failed', "not off after $force_after s; force-off failed");
        return { result => 'failed', message => "not off after $force_after s and the BMC force-off failed" };
    }
    my $after = $self->_power // 'unknown';
    $self->_log('error', "FAULT power-off $host: forced; BMC power state after force-off: $after");
    $self->_record('forced', "not off after $force_after s; BMC force-off sent");
    return { result => 'forced', message => "not off after $force_after s: forced off through the BMC (fault)" };
}

#=== net-up: host addresses on the storage and transit VLANs ====================

our $TRANSIT_MTU = $HPS::ClusterConfig::TRANSIT_MTU;    # the transit VLAN is jumbo (plans/networking.md)

sub _cluster_val ($self, $c, $key) {
    my $reg = $self->{registry};
    return $reg->cluster_exists($c, $key) ? $reg->cluster_get($c, $key) : undef;
}

sub _host_val ($self, $key) {
    my $reg = $self->{registry};
    return $reg->host_exists($self->{mac}, $key) ? $reg->host_get($self->{mac}, $key) : undef;
}

# net_plan(): the networks this host gets an address on, from the registry and
# the address rule (HPS::ClusterConfig::vlan_host_address). Storage networks
# (each network_storage_vlan<N>_subnet) for TYPE SCH or TCH; layout networks of
# purpose transit for TYPE TCH. Returns {mac, ip, prefix, networks => [{name,
# vlan, subnet, address, prefix, mtu, script, args} or {name, ..., refused =>
# reason}]}. Dies (HPS::Keysafe::Error refused) when the host as a whole cannot
# take part: not a NixOS host, or no provisioning address.
# On a TCH, after the transit networks, one entry per vxlan layout network
# (kind vxlan, vni, bridge, over, local, peers, script net-vxlan-ensure, args;
# HPS::Vxlan::host_plan), and `refresh`: the same call for every other transit
# host with an address on the transit network ({mac, host, name, vni, script,
# args} or {..., refused}), so their peer lists include this host. A host that
# joins or leaves is seen by every other on its next pairing.
sub net_plan ($self) {
    my $reg  = $self->{registry};
    my $host = $self->{host};
    my $c    = $reg->active_cluster;
    my $os   = $self->_host_val('os_id') // '';
    my (undef, $os_name) = split /:/, $os;
    _net_fail('refused', "$host: os_id '$os' is not a NixOS system; net-up drives NixOS nodes only")
        unless defined $os_name && $os_name eq 'nixos';
    my %type = map { $_ => 1 } split /,/, ($self->_host_val('TYPE') // '');
    my $ip = $self->_host_val('IP');
    _net_fail('refused', "$host: no provisioning address (host key IP)") unless defined $ip && length $ip;
    my $prefix = HPS::ClusterConfig::prefix_of_netmask($self->_host_val('NETMASK'));
    if (!defined $prefix) {
        my $cidr = $self->_cluster_val($c, 'network_cidr') // '';
        ($prefix) = $cidr =~ m{/([0-9]{1,2})\z};
    }
    _net_fail('refused', "$host: no provisioning prefix (host key NETMASK or cluster key network_cidr)") unless defined $prefix;
    my @nets;
    my %vlans;
    if ($type{SCH} || $type{TCH}) {
        my $mtu = $self->_cluster_val($c, 'network_storage_mtu') // 1500;
        my @vl  = sort { $a <=> $b } map { /^network_storage_vlan([0-9]+)_subnet\z/ ? $1 : () } $reg->cluster_list($c);
        for my $v (@vl) {
            push @nets, { name => "storage-vlan$v", purpose => 'storage', vlan => $v, mtu => $mtu,
                subnet  => $self->_cluster_val($c, "network_storage_vlan${v}_subnet"),
                gateway => $self->_cluster_val($c, "network_storage_vlan${v}_gateway") };
        }
    }
    if ($type{TCH}) {
        my $layout = $reg->cluster_exists($c, 'network_layout') ? eval { $reg->cluster_get_json($c, 'network_layout') } : undef;
        $layout = {} unless ref $layout eq 'HASH';
        for my $name (sort keys %$layout) {
            my $n = $layout->{$name};
            next unless ref $n eq 'HASH' && ($n->{purpose} // '') eq 'transit';
            push @nets, { name => $name, purpose => 'transit', vlan => $n->{vlan}, mtu => HPS::ClusterConfig::transit_mtu($n), subnet => $n->{cidr} };
        }
    }
    for my $n (grep { !$_->{kind} } @nets) {
        my $v = $n->{vlan};
        if (!defined $v || ref $v || $v !~ /^[1-9][0-9]{0,3}\z/ || $v > 4094) {
            $n->{refused} = 'no VLAN (1-4094): an untagged network needs a NIC of its own';
            next;
        }
        if ($vlans{$v}) {
            $n->{refused} = "VLAN $v is also network $vlans{$v}";
            next;
        }
        $vlans{$v} = $n->{name};
        my ($addr, $why) = HPS::ClusterConfig::vlan_host_address($ip, $prefix, $n->{subnet}, gateway => $n->{gateway});
        if (!defined $addr) { $n->{refused} = $why; next }
        my ($tp) = $n->{subnet} =~ m{/([0-9]+)\z};
        $n->{address} = $addr;
        $n->{prefix}  = $tp + 0;
        $n->{script}  = 'net-vlan-address';
        $n->{args}    = [ 'boot', "$v", "$addr/$tp", '--mtu', "$n->{mtu}" ];
    }
    my @refresh;
    if ($type{TCH}) {
        my %transit = map { $_->{name} => $_ } grep { ($_->{purpose} // '') eq 'transit' } @nets;
        for my $x (HPS::Vxlan::host_plan($reg, $self->{mac}, cluster => $c)) {
            my $t = $transit{ $x->{over} // '' };
            $x->{kind} = 'vxlan';
            $x->{refused} //= "its transit network '$x->{over}' is refused: $t->{refused}" if $t && $t->{refused};
            push @nets, $x;
        }
        my %others;
        for my $x (grep { ($_->{kind} // '') eq 'vxlan' && !$_->{refused} } @nets) {
            for my $h (HPS::Vxlan::transit_hosts($reg, $c, $self->_layout_entry($c, $x->{over}))) {
                $others{ $h->{mac} } //= $h if $h->{mac} ne $self->{mac} && defined $h->{address};
            }
        }
        for my $m (sort keys %others) {
            for my $x (HPS::Vxlan::host_plan($reg, $m, cluster => $c)) {
                push @refresh, { %$x, mac => $m, host => $others{$m}{name} };
            }
        }
    }
    return { mac => $self->{mac}, ip => $ip, prefix => $prefix + 0, networks => \@nets, refresh => \@refresh };
}

sub _layout_entry ($self, $c, $name) {
    my $reg = $self->{registry};
    my $layout = $reg->cluster_exists($c, 'network_layout') ? eval { $reg->cluster_get_json($c, 'network_layout') } : undef;
    return ref $layout eq 'HASH' ? $layout->{ $name // '' } : undef;
}

sub _net_fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

# net_up(dry_run => 0|1, wait => SECONDS): apply net_plan() through the runner,
# one node call per network (net-vlan-address, then net-vxlan-ensure for the
# vxlan networks). With wait, the node's agent is pinged first (bounded by
# wait), as after pairing. Returns the plan with result (ok | refused | failed)
# and per network rc/stderr; result is the worst of the networks (failed over
# refused over ok). A refused network is not called, nor a vxlan network whose
# transit network's call failed. Then the refresh calls on the other transit
# hosts: their outcome is logged and kept per entry (rc, summary, error) and
# never changes the result, because a host that is down gets its peers when it
# next pairs.
# Locks (_net_lock): this host's for its own calls, then each refreshed host's
# for its refresh call, one at a time, so two net-ups never wait on each other
# in a cycle. A net-up that cannot get this host's lock within lock_wait fails
# (kind 'failed'); a refresh that cannot get its host's lock is skipped with a
# warning.
sub net_up ($self, %a) {
    my $plan = $self->net_plan;
    my $host = $self->{host};
    $plan->{dry_run} = 1 if $a{dry_run};
    my @nets = @{ $plan->{networks} };
    my $result = 'ok';
    for my $n (grep { $_->{refused} } @nets) {
        $self->_log('warning', "net-up $host: $n->{name} refused: $n->{refused}");
        $result = 'refused';
    }
    if ($a{dry_run} || !grep { !$_->{refused} } @nets) {
        $plan->{result} = $result;
        return $plan;
    }
    my $lock = $self->_net_lock($self->{mac})
        // _net_fail('failed', "$host: another net-up for this host is still running after $self->{lock_wait}s");
    $self->_await_agent($a{wait} // 0);
    my %by = map { $_->{name} => $_ } @nets;
    for my $n (grep { !$_->{refused} } @nets) {
        if (($n->{kind} // '') eq 'vxlan') {
            my $t = $by{ $n->{over} };
            if ($t && defined $t->{rc} && $t->{rc} != 0) {
                $n->{error} = "not called: its transit network '$n->{over}' failed";
                $self->_log('error', "net-up $host: $n->{name}: $n->{error}");
                next;
            }
        }
        my $r = $self->_net_call($self->{mac}, "net-up $host: $n->{name}", $n);
        next if $r->{rc} == 0;
        $result = $r->{rc} == 3 && $result ne 'failed' ? 'refused' : 'failed';
    }
    close $lock;
    for my $x (@{ $plan->{refresh} }) {
        my $what = "net-up $host: refresh $x->{host} $x->{name}";
        if ($x->{refused}) {
            $self->_log('warning', "$what refused: $x->{refused}");
            next;
        }
        my $peer = $self->_net_lock($x->{mac});
        unless ($peer) {
            $x->{error} = "not called: another net-up for $x->{host} is still running after $self->{lock_wait}s";
            $self->_log('warning', "$what: $x->{error}");
            next;
        }
        $self->_net_call($x->{mac}, $what, $x, 'warning');
        close $peer;
    }
    $plan->{result} = $result;
    return $plan;
}

# _net_lock($mac): an exclusive flock on <lock_dir>/net-up-<mac>.lock, waited for
# up to lock_wait seconds (polled each second); the handle (close it, or let it
# go out of scope, to release), or undef when the wait ran out. A lock file
# that cannot be opened is an error: net-up does not run unlocked.
sub _net_lock ($self, $mac) {
    my $dir = $self->{lock_dir} //= HPS::Jobs->new(registry => $self->{registry})->sub_dir('run');
    make_path($dir) unless -d $dir;
    my $file = "$dir/net-up-$mac.lock";
    my $old = umask 002;
    my $ok = open(my $fh, '>>', $file);
    umask $old;
    _net_fail('failed', "cannot open the net-up lock $file: $!") unless $ok;
    my $deadline = $self->{now}->() + $self->{lock_wait};
    my $said;
    until (flock($fh, LOCK_EX | LOCK_NB)) {
        return undef if $self->{now}->() >= $deadline;
        $self->_log('info', "net-up: waiting for another net-up on $mac to finish") unless $said++;
        $self->{sleep}->(1);
    }
    return $fh;
}

# _net_call($mac, $what, \%entry, $level): one node call, rc/summary/error kept
# in the entry, logged (a failure at $level, default error).
sub _net_call ($self, $mac, $what, $n, $level = 'error') {
    $self->_log('info', "$what: $n->{script} " . join(' ', @{ $n->{args} }));
    my $r = $self->{runner}->call(mac => $mac, script => $n->{script}, args => [ @{ $n->{args} } ], input => undef);
    $n->{rc} = $r->{rc};
    my $last = (grep { length } split /\n/, ($r->{stderr} // ''))[-1] // '';
    my $sum  = (grep { length } split /\n/, ($r->{stdout} // ''))[-1] // '';
    if ($r->{rc} == 0) {
        $n->{summary} = $sum;
        $self->_log('info', "$what: $sum");
        return $r;
    }
    $n->{error} = $last;
    $self->_log($level, "$what: $n->{script} exited $r->{rc}" . (length $last ? ": $last" : ''));
    return $r;
}

# net_status(): the node's read-only net-status (bridges, VLAN sub-interfaces,
# their members and addresses) through the runner. Returns {rc, stdout, stderr}.
sub net_status ($self) {
    my $r = $self->{runner}->call(mac => $self->{mac}, script => 'net-status', args => [], input => undef);
    return { rc => $r->{rc}, stdout => $r->{stdout} // '', stderr => $r->{stderr} // '' };
}

# resources(): the node's read-only host-resources (the host reserve and what
# the guests hold: machine.slice, ZFS ARC, memory) through the runner. Returns
# {rc, stdout, stderr}.
sub resources ($self) {
    my $r = $self->{runner}->call(mac => $self->{mac}, script => 'host-resources', args => [], input => undef);
    return { rc => $r->{rc}, stdout => $r->{stdout} // '', stderr => $r->{stderr} // '' };
}

# Ping the agent until it answers or wait seconds pass (calls go ahead anyway).
sub _await_agent ($self, $wait) {
    return 1 unless $wait > 0 && $self->{runner}->can('ping');
    my $deadline = $self->{now}->() + $wait;
    while (1) {
        return 1 if $self->{runner}->ping($self->{mac});
        last if $self->{now}->() >= $deadline;
        $self->{sleep}->(2);
    }
    $self->_log('info', "agent of $self->{mac} did not answer a ping within ${wait}s; calling anyway");
    return 0;
}

#=== the BMC command ===========================================================

package HPS::Node::Bmc;
# Runs `hps-bmc <action> <host> [args]`; the command is HPS_BMC_CMD or hps-bmc
# on PATH. run() returns {rc, stdout, stderr, missing}; missing is true when the
# command cannot be executed at all (no BMC driver installed).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use FindBin ();
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);

# Default: the hps-bmc beside the running tool (bin/), then hps-bmc on PATH.
# The IPS keeps its tools in /srv/hps-system/bin, which is not on PATH (lab
# 2026-11-11: hps-node reported "no BMC driver" while hps-bmc drove the iLO).
sub new ($class, %opt) {
    my $beside = "$FindBin::RealBin/hps-bmc";
    my $cmd    = $opt{cmd} // $ENV{HPS_BMC_CMD} // (-x $beside ? $beside : 'hps-bmc');
    return bless { cmd => $cmd }, $class;
}

sub run ($self, $action, $host, @extra) {
    my ($in, $out);
    my $err = gensym;
    my $pid = eval { open3($in, $out, $err, $self->{cmd}, $action, $host, @extra) };
    return { rc => 127, stdout => '', stderr => "cannot run $self->{cmd}\n", missing => 1 } unless $pid;
    close $in;
    my %buf = (out => '', err => '');
    my $sel = IO::Select->new($out, $err);
    while ($sel->count) {
        for my $fh ($sel->can_read) {
            my $n = sysread($fh, my $chunk, 65536);
            if (!$n) { $sel->remove($fh); next }
            $buf{ $fh == $out ? 'out' : 'err' } .= $chunk;
        }
    }
    waitpid($pid, 0);
    my $rc = $? == -1 ? 1 : ($? & 127) ? 128 + ($? & 127) : $? >> 8;
    return { rc => $rc, stdout => $buf{out}, stderr => $buf{err}, missing => $rc == 127 ? 1 : 0 };
}

1;

__END__

=head1 NAME

HPS::Node - IPS-side node power control (power-off) and host VLAN addresses (net-up)

=head1 SEQUENCE

C<power_off>: C<HPS::Storage> C<down> (a failure stops here; the node is left
alone); ctrl-exec script C<node-poweroff>; then poll C<hps-bmc status HOST
--json> every C<HPS_NODE_POLL> (5) seconds until it reports C<off>. After
C<force_after> seconds (default 120) C<hps-bmc force-off HOST> is sent and
logged as a fault. A missing command or exit 5 from C<hps-bmc> is the no-BMC
path: stop after the node script and report.

The node's own C<hps-shutdown-storage.service> stops guests and mirrors and
exports the pools on every poweroff, so the pools are exported whether or not
the IPS asked.

C<net_up>: C<net_plan> lists the storage networks (C<network_storage_vlanN_subnet>;
TYPE SCH or TCH) and the layout networks of purpose transit (TYPE TCH) with
the host's address on each (C<HPS::ClusterConfig::vlan_host_address>), then
one C<net-vlan-address boot VLAN ADDR/PREFIX --mtu MTU> call per network.
On a TCH, then one C<net-vxlan-ensure> call per layout network of kind vxlan
(C<HPS::Vxlan>), and the same call on every other transit host to refresh its
peers (failures there are logged and do not change the result).
NixOS hosts only. Nothing is recorded: the addresses follow from C<IP>.

=head1 REGISTRY KEYS (per host)

C<poweroff_last> (C<{result,at,detail}>; result off, forced, no-bmc, failed).

=cut
