#!/usr/bin/env perl
# hps-node net-up (scale test phase 2): a NixOS host's addresses on the storage
# networks (SCH, TCH) and the transit network (TCH), one net-vlan-address call
# per network through the runner. Library on the fake runner; CLI on the
# hps-run stand-in.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Node;

my $mac = $StorageFixture::MAC;

# A fake runner whose agent answers pings only after a few tries.
package PingCE {
    our @ISA = ('FakeCE');
    sub ping { my ($s) = @_; $s->{pings}++; return $s->{pings} > ($s->{late} // 0) ? 1 : 0 }
}

# s1: provisioning 10.11.0.0/24; storage A/B VLAN 113/114 on 10.113.0.0/24 and
# 10.113.1.0/24 (base VLAN 113, subnet base 10.113), MTU 9000; transit VLAN 112.
sub s1 {
    my (%o) = @_;
    my $f = StorageFixture::setup(ce => $o{ce});
    my $reg = $f->{reg};
    $reg->host_set($mac, 'TYPE', $o{type} // 'SCH');
    $reg->host_set($mac, 'os_id', $o{os} // 'x86_64:nixos:26.05');
    $reg->host_set($mac, 'IP', $o{ip} // '10.11.0.153') unless $o{no_ip};
    $reg->host_set($mac, 'NETMASK', '255.255.255.0') unless $o{no_mask};
    $reg->cluster_set('lab', 'network_cidr', '10.11.0.0/24');
    $reg->cluster_set('lab', 'network_storage_mtu', '9000');
    for my $i (0, 1) {
        my $v = 113 + $i;
        $reg->cluster_set('lab', "network_storage_vlan${v}_subnet", "10.113.$i.0/24");
        $reg->cluster_set('lab', "network_storage_vlan${v}_gateway", "10.113.$i.1");
        $reg->cluster_set('lab', "network_storage_vlan${v}_netmask", '255.255.255.0');
    }
    $reg->cluster_set('lab', 'network_layout', $o{layout} // {
        transit => { cidr => '10.11.2.0/24', vlan => 112, bridge => 'br-transit', purpose => 'transit' },
        odoo    => { cidr => '10.40.0.0/24', vlan => 40, bridge => 'br-odoo', purpose => 'workload' },
    });
    my @log;
    my $storage = $f->{mk}->();
    my $clock = 1_800_000_000;
    my $n = HPS::Node->new(host => 'sch-001', registry => $reg, storage => $storage, runner => $f->{ce},
        logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $clock }, sleep => sub { $clock += $_[0] });
    return ($n, $f, \@log);
}

sub calls { my ($f) = @_; return [ map { join ' ', $_->{script}, @{ $_->{args} } } $f->{ce}->calls ] }

# --- SCH: both storage networks, no transit
{
    my ($n, $f) = s1(type => 'SCH');
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'SCH: ok');
    is_deeply(calls($f), [
        'net-vlan-address boot 113 10.113.0.153/24 --mtu 9000',
        'net-vlan-address boot 114 10.113.1.153/24 --mtu 9000',
    ], 'SCH: storage A and B, last octet kept, storage MTU');
}

# --- TCH: storage and transit; converged (SCH,TCH) the same
for my $type ('TCH', 'SCH,TCH') {
    my ($n, $f) = s1(type => $type);
    my $r = $n->net_up;
    is($r->{result}, 'ok', "$type: ok");
    is_deeply(calls($f), [
        'net-vlan-address boot 113 10.113.0.153/24 --mtu 9000',
        'net-vlan-address boot 114 10.113.1.153/24 --mtu 9000',
        'net-vlan-address boot 112 10.11.2.153/24 --mtu 9000',
    ], "$type: storage A, B and transit (MTU 9000)");
}

# --- other types: nothing to do
{
    my ($n, $f) = s1(type => 'CNH');
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'CNH: ok');
    is(scalar @{ $r->{networks} }, 0, 'CNH: no networks');
    is(scalar(@{ calls($f) }), 0, 'CNH: no calls');
}

# --- dry run: the plan, no calls
{
    my ($n, $f) = s1(type => 'TCH');
    my $r = $n->net_up(dry_run => 1);
    ok($r->{dry_run}, 'dry run flagged');
    is(scalar(@{ calls($f) }), 0, 'dry run calls nothing');
    is_deeply([ map { $_->{address} } @{ $r->{networks} } ], [ '10.113.0.153', '10.113.1.153', '10.11.2.153' ], 'dry run: the addresses');
    is_deeply($r->{networks}[2]{args}, [ 'boot', '112', '10.11.2.153/24', '--mtu', '9000' ], 'dry run: the node call');
}

# --- the prefix comes from network_cidr when NETMASK is unset; storage MTU default 1500
{
    my ($n, $f) = s1(no_mask => 1);
    $f->{reg}->cluster_unset('lab', 'network_storage_mtu');
    $n->net_up;
    is(calls($f)->[0], 'net-vlan-address boot 113 10.113.0.153/24 --mtu 1500', 'network_cidr prefix; MTU 1500 by default');
}

# --- refusals of the whole host
{
    my ($n, $f) = s1(os => 'x86_64:rocky:10');
    eval { $n->net_up };
    isa_ok($@, 'HPS::Keysafe::Error', 'a non-NixOS host');
    is($@->kind, 'refused', 'non-NixOS: refused');
    like($@->message, qr/not a NixOS system/, 'says why');
    ($n, $f) = s1(no_ip => 1);
    eval { $n->net_up };
    like($@->message, qr/no provisioning address/, 'no IP: refused');
    is(scalar(@{ calls($f) }), 0, 'nothing called');
}

# --- a network refused (the host lands on the gateway), the others still applied
{
    my ($n, $f, $log) = s1(type => 'TCH', ip => '10.11.0.1');
    my $r = $n->net_up;
    is($r->{result}, 'refused', 'one network refused: result refused');
    is_deeply(calls($f), [ 'net-vlan-address boot 112 10.11.2.1/24 --mtu 9000' ], 'storage refused (gateway .1), transit still called');
    like($r->{networks}[0]{refused}, qr/the gateway of 10\.113\.0\.0\/24/, 'the reason');
    ok((grep { /storage-vlan113 refused/ } @$log), 'logged');
}

# --- layout transit without a vlan, and a transit VLAN that is also a storage VLAN
{
    my ($n, $f) = s1(type => 'TCH', layout => {
        t1 => { cidr => '10.11.2.0/24', bridge => 'br-t1', purpose => 'transit' },
        t2 => { cidr => '10.11.3.0/24', vlan => 113, bridge => 'br-t2', purpose => 'transit' },
    });
    my $r = $n->net_up;
    is($r->{result}, 'refused', 'bad transit entries: refused');
    my %by = map { $_->{name} => $_ } @{ $r->{networks} };
    like($by{t1}{refused}, qr/no VLAN/, 'untagged transit refused');
    like($by{t2}{refused}, qr/VLAN 113 is also network storage-vlan113/, 'duplicate VLAN refused');
    is(scalar(@{ calls($f) }), 2, 'the storage networks are still called');
}

# --- a node call that fails, or refuses
{
    my ($n, $f) = s1(ce => { rc => { 'net-vlan-address' => [ 0, 1 ] } });
    my $r = $n->net_up;
    is($r->{result}, 'failed', 'a failing call: failed');
    is($r->{networks}[1]{rc}, 1, 'its rc');
    is($r->{networks}[1]{error}, 'boom from net-vlan-address', 'the last stderr line');
    ($n, $f) = s1(ce => { rc => { 'net-vlan-address' => [ 3, 0 ] } });
    $r = $n->net_up;
    is($r->{result}, 'refused', 'a node refusal (3): refused');
    is(scalar(@{ calls($f) }), 2, 'the next network is still called');
}

# --- wait: the agent is pinged until it answers
{
    my ($n, $f) = s1();
    my $ce = bless { calls => [], rc => {}, out => {}, late => 2 }, 'PingCE';
    $n->{runner} = $ce;
    my $r = $n->net_up(wait => 60);
    is($ce->{pings}, 3, 'pinged until the agent answered');
    is(scalar(@{ $ce->{calls} }), 2, 'then called');
}

# --- the CLI
{
    my $f   = StorageFixture::setup();
    my $reg = $f->{reg};
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    $reg->host_set($mac, 'TYPE', 'SCH,TCH');
    $reg->host_set($mac, 'os_id', 'x86_64:nixos:26.05');
    $reg->host_set($mac, 'IP', '10.11.0.153');
    $reg->host_set($mac, 'NETMASK', '255.255.255.0');
    $reg->cluster_set('lab', 'network_storage_mtu', '9000');
    $reg->cluster_set('lab', 'network_storage_vlan113_subnet', '10.113.0.0/24');
    $reg->cluster_set('lab', 'network_storage_vlan113_gateway', '10.113.0.1');
    $reg->cluster_set('lab', 'network_layout', { transit => { cidr => '10.11.2.0/24', vlan => 112, bridge => 'br-transit', purpose => 'transit' } });
    local $ENV{HPS_CONFIG_BASE}     = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}         = "$tmp/hps-run";
    local $ENV{HPS_NODE_NO_SYSLOG}  = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
    local $ENV{SHIM_DIR}            = $tmp;
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-node", @_);
        my $out = qx(@cmd 2>$tmp/stderr);
        return ($? >> 8, $out);
    };
    my $args = sub { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; chomp @l; \@l } : [] };

    my ($rc, $out) = $cli->('net-up');
    is($rc, 2, 'CLI: no host: usage');
    ($rc) = $cli->('net-up', 'sch-001', 'extra');
    is($rc, 2, 'CLI: two hosts: usage');
    ($rc) = $cli->('net-up', 'sch-001', '--wait', '-1');
    is($rc, 2, 'CLI: negative wait: usage');
    ($rc) = $cli->('net-up', 'nosuch');
    is($rc, 4, 'CLI: unknown host: not found');

    ($rc, $out) = $cli->('net-up', '--dry-run', 'sch-001');
    is($rc, 0, 'CLI dry run: 0');
    like($out, qr/^storage-vlan113 \(vlan 113\): net-vlan-address boot 113 10\.113\.0\.153\/24 --mtu 9000$/m, 'CLI dry run prints the storage call');
    like($out, qr/^transit \(vlan 112\): net-vlan-address boot 112 10\.11\.2\.153\/24 --mtu 9000$/m, 'CLI dry run prints the transit call');
    like($out, qr/sch-001: dry run: ok, 2 network\(s\), 2 to call/, 'CLI dry run summary');
    is(scalar @{ $args->() }, 0, 'CLI dry run calls nothing');

    ($rc, $out) = $cli->('net-up', 'sch-001', '--json');
    is($rc, 0, 'CLI: applied');
    my $doc = decode_json($out);
    is($doc->{result}, 'ok', 'CLI json result');
    is_deeply($args->(), [ "--json $mac net-vlan-address boot 113 10.113.0.153/24 --mtu 9000",
                           "--json $mac net-vlan-address boot 112 10.11.2.153/24 --mtu 9000" ], 'CLI: hps-run called once per network');

    unlink "$tmp/args";
    local $ENV{FAKE_NODE_EXIT} = 3;
    local $ENV{FAKE_NODE_STDERR} = '[net-vlan-address] refused: eth0.113 is a member of bridge br-stor';
    ($rc, $out) = $cli->('net-up', 'sch-001');
    is($rc, 3, 'CLI: node refusal: 3');
    like($out, qr/exited 3: \[net-vlan-address\] refused: eth0\.113 is a member/, 'CLI shows the node\'s reason');
}

done_testing;
