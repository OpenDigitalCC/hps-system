#!/usr/bin/env perl
# VXLAN workload networks: the layout kind vxlan (HPS::ClusterConfig), transit
# hosts, peers and the node call (HPS::Vxlan), hps-node net-up building them on
# a TCH and refreshing the other TCHs (HPS::Node), and hps-workload create and
# start for a VM on a vxlan network (HPS::Workload). Fake runner; the CLI on
# the hps-run stand-in.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::ClusterConfig;
use HPS::Vxlan;
use HPS::Node;

my $MAC = $StorageFixture::MAC;    # tch-001 (sch-001 in the workload fixture)

#=== validation =================================================================

sub verr { return HPS::ClusterConfig::validate_layout(JSON::PP->new->canonical->encode($_[0])) }

my $TRANSIT = { cidr => '10.11.2.0/24', vlan => 112, bridge => 'br-transit', purpose => 'transit' };
my $CLIENT  = { kind => 'vxlan', vni => 1100, over => 'transit', bridge => 'br-client', purpose => 'workload' };

is(verr({ transit => $TRANSIT, client => $CLIENT }), undef, 'a vxlan network over a transit network');
is(verr({ transit => $TRANSIT, client => { %$CLIENT, mtu => 1450 } }), undef, 'with an mtu');
is(verr({ transit => $TRANSIT, client => $CLIENT, two => { %$CLIENT, vni => 1101, bridge => 'br-two' } }), undef, 'two VNIs over one transit');
is(verr({ transit => $TRANSIT, client => { %$CLIENT, vni => 16777215 } }), undef, 'the highest VNI');
my %bad = (
    'vni 0'                     => [ { vni => 0 },           qr/vni must be 1 to 16777215/ ],
    'vni 16777216'              => [ { vni => 16777216 },    qr/vni must be 1 to 16777215/ ],
    'vni text'                  => [ { vni => 'x' },         qr/vni must be/ ],
    'vni missing'               => [ { vni => undef },       qr/vni must be/ ],
    'purpose storage'           => [ { purpose => 'storage' }, qr/purpose "workload"/ ],
    'a cidr'                    => [ { cidr => '10.9.0.0/24' }, qr/takes no cidr/ ],
    'a vlan'                    => [ { vlan => 1100 },       qr/takes no vlan/ ],
    'a nic'                     => [ { nic => 'aa:bb:cc:00:00:01' }, qr/takes no nic/ ],
    'an uplink'                 => [ { uplink => 'boot' },   qr/takes no uplink/ ],
    'no over'                   => [ { over => undef },      qr/over .* is required/ ],
    'over a missing network'    => [ { over => 'nosuch' },   qr/over 'nosuch' is not a network of the layout/ ],
    'over a workload network'   => [ { over => 'odoo' },     qr/over 'odoo' is not a purpose transit network/ ],
    'over itself'               => [ { over => 'client' },   qr/over 'client' is not a purpose transit network/ ],
    'mtu 8951'                  => [ { mtu => 8951 },        qr/mtu must be 576 to 8950 \(the transit MTU 9000 less 50\)/ ],
    'mtu 500'                   => [ { mtu => 500 },         qr/mtu must be 576 to 8950/ ],
    'a bridge without br-'      => [ { bridge => 'client' }, qr/bridge must match/ ],
    'the transit bridge'        => [ { bridge => 'br-transit' }, qr/bridge 'br-transit' is also used/ ],
);
for my $what (sort keys %bad) {
    my ($change, $re) = @{ $bad{$what} };
    my %n = (%$CLIENT, %$change);
    delete $n{$_} for grep { !defined $n{$_} } keys %n;
    my $e = verr({ transit => $TRANSIT, odoo => { cidr => '10.40.0.0/24', vlan => 40, bridge => 'br-odoo', purpose => 'workload' }, client => \%n });
    like($e // '', $re, "refused: $what");
}
like(verr({ transit => $TRANSIT, client => $CLIENT, two => { %$CLIENT, bridge => 'br-two' } }) // '',
    qr/vni 1100 is also used by 'client'/, 'refused: a VNI used twice');
like(verr({ transit => { %$TRANSIT, vni => 5 } }) // '', qr/vni is only for a vxlan network/, 'refused: vni on a VLAN network');
like(verr({ transit => { %$TRANSIT, over => 'x' } }) // '', qr/over is only for a vxlan network/, 'refused: over on a VLAN network');
like(verr({ fab => { kind => 'fabric', purpose => 'emulated-switch', bridge => 'br-fab', vni => 1 } }) // '',
    qr/vni is only for a vxlan network/, 'refused: vni on a fabric network');
like(verr({ x => { kind => 'tunnel', purpose => 'workload', bridge => 'br-x' } }) // '', qr/kind must be "fabric" or "vxlan"/, 'refused: another kind');
is(HPS::ClusterConfig::vxlan_mtu($CLIENT), 8950, 'MTU default: transit 9000 less 50');
is(HPS::ClusterConfig::vxlan_mtu({ %$CLIENT, mtu => 1450 }), 1450, 'MTU from the layout');

#=== the s1 cluster: four TCHs, one SCH =========================================

# tch-001 is the fixture host ($MAC); tch-002..004 and sch-002 are added.
my %HOSTS = (
    $MAC           => [ 'tch-001', 'TCH',     '10.11.0.12' ],
    '525400000012' => [ 'tch-002', 'TCH',     '10.11.0.13' ],
    '525400000013' => [ 'tch-003', 'SCH,TCH', '10.11.0.14' ],
    '525400000014' => [ 'tch-004', 'TCH',     '10.11.0.15' ],
    '525400000020' => [ 'sch-002', 'SCH',     '10.11.0.20' ],
    '525400000021' => [ 'tch-rk1', 'TCH',     '10.11.0.21', 'x86_64:rocky:10' ],
    '525400000022' => [ 'tch-noip', 'TCH',    undef ],
);

sub s1 {
    my (%o) = @_;
    my $f = StorageFixture::setup(ce => $o{ce});
    my $reg = $f->{reg};
    for my $m (sort keys %HOSTS) {
        my ($name, $type, $ip, $os) = @{ $HOSTS{$m} };
        $reg->host_set($m, 'HOSTNAME', $name);
        $reg->host_set($m, 'TYPE', $type);
        $reg->host_set($m, 'os_id', $os // 'x86_64:nixos:26.05');
        $reg->host_set($m, 'IP', $ip) if defined $ip;
        $reg->host_set($m, 'NETMASK', '255.255.255.0');
    }
    $reg->cluster_set('lab', 'network_cidr', '10.11.0.0/24');
    $reg->cluster_set('lab', 'network_layout', $o{layout} // { transit => $TRANSIT, client => $CLIENT,
        odoo => { cidr => '10.40.0.0/24', vlan => 40, bridge => 'br-odoo', purpose => 'workload' } });
    my @log;
    my $n = HPS::Node->new(host => $o{host} // 'tch-001', registry => $reg, storage => $f->{mk}->(host => $o{mac} // $MAC),
        runner => $f->{ce}, logger => sub { push @log, "$_[0] $_[1]" }, now => sub { 1 }, sleep => sub { });
    return ($n, $f, \@log);
}

sub calls { my ($f) = @_; return [ map { "$_->{mac} " . join ' ', $_->{script}, @{ $_->{args} } } $f->{ce}->calls ] }

my $PEERS_1 = '--peer 10.11.2.13 --peer 10.11.2.14 --peer 10.11.2.15';

#--- HPS::Vxlan: transit hosts and the peer rule
{
    my (undef, $f) = s1();
    my $reg = $f->{reg};
    my @t = HPS::Vxlan::transit_hosts($reg, 'lab', $TRANSIT);
    is_deeply([ map { $_->{name} } @t ], [qw(tch-001 tch-002 tch-003 tch-004 tch-noip)],
        'transit hosts: TYPE TCH (SCH,TCH too), NixOS; sch-002 and the Rocky TCH are not');
    is_deeply([ map { $_->{address} // 'refused' } @t ], [qw(10.11.2.12 10.11.2.13 10.11.2.14 10.11.2.15 refused)],
        'each at its transit address (host part of the provisioning address)');
    like($t[-1]{refused}, qr/no provisioning address/, 'a TCH without an IP has no transit address');

    my @p = HPS::Vxlan::host_plan($reg, '525400000013');
    is(scalar @p, 1, 'one vxlan network in the layout: one call');
    is_deeply($p[0]{peers}, [qw(10.11.2.12 10.11.2.13 10.11.2.15)], 'peers: every other transit host, sorted by address');
    is($p[0]{local}, '10.11.2.14', 'local: its own transit address');
    is_deeply($p[0]{args}, [ '1100', 'br-client', '--local', '10.11.2.14', '--peer', '10.11.2.12', '--peer', '10.11.2.13',
        '--peer', '10.11.2.15', '--mtu', '8950' ], 'the node call');
    is($p[0]{script}, 'net-vxlan-ensure', 'net-vxlan-ensure');

    my @s = HPS::Vxlan::host_plan($reg, '525400000020');
    like($s[0]{refused}, qr/not a transit host/, 'an SCH is refused');
    my @n = HPS::Vxlan::host_plan($reg, '525400000022');
    like($n[0]{refused}, qr/no address on transit network 'transit': no provisioning address/, 'a TCH without an address is refused');

    $reg->cluster_set('lab', 'network_layout', { transit => { %$TRANSIT, vlan => undef }, client => $CLIENT });
    like((HPS::Vxlan::host_plan($reg, $MAC))[0]{refused}, qr/no VLAN/, 'an untagged transit network: refused');
    $reg->cluster_set('lab', 'network_layout', { transit => $TRANSIT });
    is(scalar(HPS::Vxlan::host_plan($reg, $MAC)), 0, 'no vxlan network: no call');
}

#--- net-up on a TCH: addresses, then the vxlan, then the refresh of the others
{
    my ($n, $f) = s1();
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'TCH net-up: ok');
    is_deeply(calls($f), [
        "$MAC net-vlan-address boot 112 10.11.2.12/24 --mtu 9000",
        "$MAC net-vxlan-ensure 1100 br-client --local 10.11.2.12 $PEERS_1 --mtu 8950",
        '525400000012 net-vxlan-ensure 1100 br-client --local 10.11.2.13 --peer 10.11.2.12 --peer 10.11.2.14 --peer 10.11.2.15 --mtu 8950',
        '525400000013 net-vxlan-ensure 1100 br-client --local 10.11.2.14 --peer 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.15 --mtu 8950',
        '525400000014 net-vxlan-ensure 1100 br-client --local 10.11.2.15 --peer 10.11.2.12 --peer 10.11.2.13 --peer 10.11.2.14 --mtu 8950',
    ], 'transit address, its vxlan with three peers, then every other TCH refreshed (not the one without an address)');
    my ($vx) = grep { ($_->{kind} // '') eq 'vxlan' } @{ $r->{networks} };
    is($vx->{rc}, 0, 'the vxlan entry has its rc');
    is(scalar @{ $r->{refresh} }, 3, 'three refresh entries');
    is($r->{refresh}[0]{host}, 'tch-002', 'named by HOSTNAME');
}

#--- dry run: the whole plan, refresh included, no calls
{
    my ($n, $f) = s1();
    my $r = $n->net_up(dry_run => 1);
    is(scalar(@{ calls($f) }), 0, 'dry run calls nothing');
    is(scalar @{ $r->{refresh} }, 3, 'dry run lists the refreshes');
}

#--- an SCH gets no vxlan and refreshes nobody
{
    my ($n, $f) = s1(host => 'sch-002', mac => '525400000020');
    my $r = $n->net_up;
    is_deeply([ grep { /vxlan/ } @{ calls($f) } ], [], 'SCH: no vxlan call');
    is_deeply($r->{refresh}, [], 'SCH: no refresh');
}

#--- the transit call fails: the vxlan is not called; failure is the result
{
    my ($n, $f, $log) = s1(ce => { rc => { 'net-vlan-address' => 1 } });
    my $r = $n->net_up;
    is($r->{result}, 'failed', 'transit failed: failed');
    my ($vx) = grep { ($_->{kind} // '') eq 'vxlan' } @{ $r->{networks} };
    ok(!defined $vx->{rc}, 'vxlan not called');
    like($vx->{error}, qr/its transit network 'transit' failed/, 'says why');
    ok(!grep({ /^$MAC net-vxlan-ensure/ } @{ calls($f) }), 'no vxlan call on this host');
}

#--- the host's transit address refused (lands on the broadcast): its vxlan refused, no refresh
{
    local $HOSTS{$MAC} = [ 'tch-001', 'TCH', '10.11.0.255' ];
    my ($n, $f) = s1();
    $f->{reg}->host_set($MAC, 'NETMASK', '255.255.255.0');
    my $r = $n->net_up;
    is($r->{result}, 'refused', 'transit refused: refused');
    my ($vx) = grep { ($_->{kind} // '') eq 'vxlan' } @{ $r->{networks} };
    like($vx->{refused}, qr/broadcast/, 'vxlan refused with the reason');
    is_deeply($r->{refresh}, [], 'no refresh when this host has no vxlan');
}

#--- a refresh that fails is logged and does not change the result
{
    my ($n, $f, $log) = s1(ce => { rc => { 'net-vxlan-ensure' => [ 0, 1, 0, 0 ] } });
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'a failed refresh: still ok');
    is($r->{refresh}[0]{rc}, 1, 'its rc kept');
    ok((grep { /^warning .*refresh tch-002 client: net-vxlan-ensure exited 1/ } @$log), 'logged as a warning');
    is(scalar(@{ calls($f) }), 5, 'the other refreshes still run');
}

#--- the node refuses (exit 3): refused
{
    my ($n, $f) = s1(ce => { rc => { 'net-vxlan-ensure' => [ 3, 0, 0, 0 ] } });
    is($n->net_up->{result}, 'refused', 'node refusal of the vxlan: refused');
}

#--- the CLI
{
    my ($n, $f) = s1();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}       = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}   = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}           = "$tmp/hps-run";
    local $ENV{HPS_NODE_NO_SYSLOG}    = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
    local $ENV{SHIM_DIR}              = $tmp;
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-node", 'net-up', '--dry-run', 'tch-001');
    my $out = qx(@cmd 2>$tmp/stderr);
    is($? >> 8, 0, 'CLI dry run: 0');
    like($out, qr/^client \(vni 1100\): net-vxlan-ensure 1100 br-client --local 10\.11\.2\.12 \Q$PEERS_1\E --mtu 8950$/m, 'CLI: the vxlan call');
    like($out, qr/^refresh tch-004 client \(vni 1100\): net-vxlan-ensure 1100 br-client --local 10\.11\.2\.15 /m, 'CLI: a refresh line');
    @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-node", 'net-up', 'tch-001');
    $out = qx(@cmd 2>$tmp/stderr);
    is($? >> 8, 0, 'CLI: applied');
    like($out, qr/^refresh tch-002 client \(vni 1100\): node says hi$/m, 'CLI: the refresh summary');
}

#=== hps-workload: a VM on a vxlan network ====================================

sub wl_fixture {
    my (%o) = @_;
    my $f = StorageFixture::setup_workload(no_def => 1);
    my $reg = $f->{reg};
    $reg->host_set($MAC, 'TYPE', $o{type} // 'SCH,TCH');
    $reg->host_set($MAC, 'os_id', 'x86_64:nixos:26.05');
    $reg->host_set($MAC, 'IP', '10.11.0.12');
    $reg->host_set($MAC, 'NETMASK', '255.255.255.0');
    for my $m ('525400000012', '525400000013') {
        $reg->host_set($m, 'HOSTNAME', "tch-$m");
        $reg->host_set($m, 'TYPE', 'TCH');
        $reg->host_set($m, 'os_id', 'x86_64:nixos:26.05');
        $reg->host_set($m, 'IP', $m eq '525400000012' ? '10.11.0.13' : '10.11.0.14');
        $reg->host_set($m, 'NETMASK', '255.255.255.0');
    }
    $reg->cluster_set('lab', 'network_layout', { %{ StorageFixture::layout() }, transit => $TRANSIT, client => $CLIENT });
    my $def = StorageFixture::base_def();
    $def->{vms}[0]{nets} = [ 'mgmt', 'client' ];
    $def->{vms}[1]{nets} = [ 'client' ];
    StorageFixture::write_def($f, $def);
    return $f;
}

my $VX = [ '1100', 'br-client', '--local', '10.11.2.12', '--peer', '10.11.2.13', '--peer', '10.11.2.14', '--mtu', '8950' ];
{
    my $f = wl_fixture();
    my $wl = $f->{wl}->();
    my $plan = $wl->plan('create', 't0');
    my @vx = grep { $_->{script} eq 'net-vxlan-ensure' } @$plan;
    is(scalar @vx, 1, 'create: one net-vxlan-ensure per compute host and network');
    is_deeply($vx[0]{args}, $VX, 'create: local and peers from the transit addresses');
    my @names = map { $_->{script} } @$plan;
    my ($iv) = grep { $names[$_] eq 'net-vxlan-ensure' } 0 .. $#names;
    my ($id) = grep { $names[$_] eq 'vm-define' } 0 .. $#names;
    ok($iv < $id, 'create: before the first vm-define');
    is(scalar(grep { $_ eq 'net-bridge-ensure' } @names), 1, 'create: net-bridge-ensure only for the VM with a VLAN net (t0-db has only the vxlan net)');
    my ($def_app) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-app' } @$plan;
    like(join(' ', @{ $def_app->{args} }), qr/--net br-mgmt --net br-client/, 'vm-define: the vxlan bridge is the NIC\'s bridge');

    my $r = $wl->run('create', 't0');
    ok($r->{ok}, 'create ran');
    is(scalar(grep { $_->{script} eq 'net-vxlan-ensure' } $f->{ce}->calls), 1, 'create: net-vxlan-ensure called once');
    is_deeply($f->{reg}->host_get_json($MAC, 'nets'), ['mgmt'], 'create: the vxlan net is not added to the host key nets');

    $f->{ce}{calls} = [];
    my $sp = $wl->plan('start', 't0');
    my @svx = grep { $_->{script} eq 'net-vxlan-ensure' } @$sp;
    is(scalar @svx, 1, 'start: net-vxlan-ensure once for the host and network');
    is_deeply($svx[0]{args}, $VX, 'start: the same call');
    is($sp->[0]{script}, 'net-vxlan-ensure', 'start: before the first VM\'s steps');
}

#--- a compute host that is not a transit host refuses the plan
{
    my $f = wl_fixture(type => 'SCH');
    my $wl = $f->{wl}->();
    eval { $wl->plan('create', 't0') };
    isa_ok($@, 'HPS::Keysafe::Error', 'not a transit host');
    like($@->message, qr/net 'client' \(vxlan 1100\) cannot be built on compute host 'sch-001': the host is not a transit host/, 'says why');
}

#--- a vxlan net is not a fabric port
{
    my $f = wl_fixture();
    my $def = StorageFixture::base_def();
    $def->{vms}[0]{nets} = [ { net => 'client', pvid => 5 } ];
    eval { HPS::Workload::validate($def, layout => $f->{reg}->cluster_get_json('lab', 'network_layout')) };
    like($@ && $@->message, qr/not a fabric/, 'pvid on a vxlan net is refused');
}

done_testing;
