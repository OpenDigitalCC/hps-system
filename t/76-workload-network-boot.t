#!/usr/bin/env perl
# CS-3.12a: a VM that netboots ("boot": "network") - validation, the create
# plan (no image, no disk, no zvol, no mirror), the MACs in the registry
# record, and the other operations unchanged.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

my $MAC = $StorageFixture::MAC;
my $layout = {
    %{ StorageFixture::layout() },
    prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' },
};

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

sub net_def {
    return {
        name => 'n0', project => 'lab',
        vms => [ { name => 'n0-node', memory_mib => 4096, vcpus => 2, boot => 'network', nets => ['prov'],
                   compute_host => 'sch-001' } ],
    };
}

sub refuses {
    my ($mut, $re, $label) = @_;
    my $d = net_def();
    $mut->($d);
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    ok(defined $e && ref $e, "$label: refused") or return;
    is($e->kind, 'refused', "$label: kind refused");
    like($e->message, $re, "$label: reason named");
    return;
}

#--- definition
my $ok = HPS::Workload::validate(net_def(), layout => $layout);
my $vm = $ok->{vms}[0];
is($vm->{boot}, 'network', 'boot network carried');
ok(!exists $vm->{image}, 'a network-boot VM has no image');
is_deeply($vm->{disks}, [], 'disks default to none');
is($vm->{compute}, 'sch-001', 'compute host from compute_host');

{
    my $d = net_def();
    $d->{vms}[0]{disks} = [];
    ok(HPS::Workload::validate($d, layout => $layout), 'an empty disks list is valid');
}
{
    my $d = StorageFixture::base_def();
    my $v = HPS::Workload::validate($d, layout => StorageFixture::layout());
    is($v->{vms}[0]{boot}, 'disk', 'boot defaults to disk');
    is($v->{vms}[0]{image}, 'debian-13-generic-amd64', 'a disk VM keeps its image');
    $d->{vms}[0]{boot} = 'disk';
    ok(HPS::Workload::validate($d), 'boot "disk" is accepted');
    delete $d->{vms}[0]{image};
    my $e = err_of(sub { HPS::Workload::validate($d) });
    like($e->message, qr/image must match/, 'a disk-boot VM without an image is still refused');
    $d = StorageFixture::base_def();
    $d->{vms}[0]{disks} = [];
    $e = err_of(sub { HPS::Workload::validate($d) });
    like($e->message, qr/disks must be a non-empty list/, 'a disk-boot VM without disks is still refused');
}

refuses(sub { $_[0]{vms}[0]{boot} = 'pxe' }, qr/boot must be "disk" or "network"/, 'unknown boot');
refuses(sub { $_[0]{vms}[0]{image} = 'debian-13-generic-amd64' }, qr/no image/, 'network boot with an image');
refuses(sub { delete $_[0]{vms}[0]{compute_host} }, qr/no local .* leg and no compute_host/, 'network boot without disks needs compute_host');
refuses(sub { $_[0]{vms}[0]{nets} = ['ghost'] }, qr/net 'ghost' is not in the cluster's network_layout/, 'net not in the layout');
refuses(sub { $_[0]{vms}[0]{disks} = 'x' }, qr/disks must be a list/, 'disks not a list');
refuses(sub { $_[0]{vms}[0]{extra} = 1 }, qr/unknown field 'extra'/, 'unknown field still refused');

#--- create plan and run
sub fixture {
    my %o = @_;
    my $f = StorageFixture::setup_workload(no_def => 1, %o);
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    StorageFixture::write_def($f, net_def());
    return $f;
}

{
    my $f = fixture();
    my $plan = $f->{wl}->()->plan('create', 'n0');
    is_deeply([ map { $_->{script} } @$plan ], [ 'net-bridge-ensure', 'vm-define' ],
        'create plan: ensure the bridge, define - no zvol, no image, no mirror, no image write');
    is_deeply($plan->[1]{args}, [ 'n0-node', '--memory', 4096, '--vcpus', 2, '--boot', 'network', '--net', 'br-prov' ],
        'vm-define: --boot network, the layout bridge, no --disk and no --image');
    is($plan->[1]{host}, $MAC, 'addressed to the compute host by MAC');
}

{
    my $f = fixture(ce => { out => { 'vm-define' => "[vm-define] x\nVM n0-node defined mac=52:54:00:12:34:56\n" } });
    my $wl = $f->{wl}->();
    my $r = $wl->run('create', 'n0');
    ok($r->{ok}, 'create ok');
    is_deeply([ $f->{ce}->scripts ], [ 'net-bridge-ensure', 'vm-define' ], 'node calls in plan order');
    is_deeply($f->{reg}->host_get_json($MAC, 'nets'), ['prov'], 'host nets key lists prov before the bridge is ensured');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_n0');
    is($rec->{state}, 'created', 'registry: created');
    is($rec->{vms}{'n0-node'}{state}, 'defined', 'registry: vm defined');
    is_deeply($rec->{vms}{'n0-node'}{macs}, ['52:54:00:12:34:56'], 'registry: the MAC vm-define reported');
    is_deeply($rec->{vms}{'n0-node'}{disks}, {}, 'registry: no disks');

    # start / status / stop / destroy: no mirrors, no zvols
    $f->{ce}{calls} = [];
    $wl->run('start', 'n0');
    is_deeply([ $f->{ce}->scripts ], ['vm-start'], 'start: vm-start only');
    is(($f->{reg}->cluster_get_json('lab', 'workload_n0'))->{state}, 'running', 'registry: running');
    $f->{ce}{calls} = [];
    $wl->run('status', 'n0');
    is_deeply([ $f->{ce}->scripts ], ['vm-status'], 'status: vm-status only');
    $f->{ce}{calls} = [];
    $wl->run('stop', 'n0');
    is_deeply([ $f->{ce}->scripts ], ['vm-stop'], 'stop: vm-stop only');
    is(($f->{reg}->cluster_get_json('lab', 'workload_n0'))->{state}, 'stopped', 'registry: stopped');
    StorageFixture::approve($f, 'workload-destroy', pool => 'n0');
    $f->{ce}{calls} = [];
    $wl->run('destroy', 'n0');
    is_deeply([ $f->{ce}->scripts ], [ 'vm-stop', 'vm-undefine' ], 'destroy: stop and undefine, no zvol destroy');
    ok(!$f->{reg}->cluster_exists('lab', 'workload_n0'), 'registry: record removed');
}

{
    my $f = fixture(ce => { out => { 'vm-define' => "VM n0-node defined mac=52:54:00:12:34:56\nVM n0-node defined mac=52:54:00:12:34:57\n" } });
    $f->{wl}->()->run('create', 'n0');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_n0');
    is(scalar @{ $rec->{vms}{'n0-node'}{macs} }, 2, 'one MAC per NIC line');
}

done_testing;
