#!/usr/bin/env perl
# Stop order of a compute host's guests (incident 2026-11-12: s1's SCH VMs
# stopped before its TCH VMs, so the probes' md mirrors lost both iSCSI legs).
# A storage provider (a network-boot VM with disks of its own: a nested SCH or
# IPS) defaults to priority 1 (start first, stop last), starts before and stops
# after the consumers at one priority, and vm-start tells the node its priority
# and role (hps-shutdown-storage orders by them).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

my $layout = {
    %{ StorageFixture::layout() },
    prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' },
};

sub vm {
    my ($name, %o) = @_;
    return { name => $name, memory_mib => 2048, vcpus => 2, boot => 'network', nets => ['prov'],
             compute_host => 'sch-001', %o };
}
my $DISK = [ { name => 'd0', size => '20G', legs => [ { host => 'sch-001', pool => 'lab' } ] } ];

#--- defaults
{
    my $v = HPS::Workload::validate({ name => 's1', project => 'lab', vms => [
        vm('s1-sch', disks => $DISK), vm('s1-tch'), vm('s1-tch5', priority => 5), vm('s1-sch4', disks => $DISK, priority => 4),
    ] }, layout => $layout);
    my %by = map { $_->{name} => $_ } @{ $v->{vms} };
    is($by{'s1-sch'}{provides_storage}, 1, 'a network-boot VM with disks provides storage');
    is($by{'s1-sch'}{priority}, 1, 'and defaults to priority 1 (start first, stop last)');
    is($by{'s1-tch'}{provides_storage}, 0, 'a diskless network-boot VM (a nested TCH) consumes');
    is($by{'s1-tch'}{priority}, 3, 'and keeps the default 3');
    is($by{'s1-tch5'}{priority}, 5, 'an explicit priority is kept');
    is($by{'s1-sch4'}{priority}, 4, 'also for a provider');
    my $d = HPS::Workload::validate(StorageFixture::base_def(), layout => StorageFixture::layout());
    is($d->{vms}[0]{provides_storage}, 0, 'a disk-boot VM (mirrors over iSCSI legs) consumes');
}

#--- order at one priority: providers start first and stop last
{
    my $f = StorageFixture::setup_workload(no_def => 1);
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    my $wl = $f->{wl}->();
    my $def = HPS::Workload::validate({ name => 's1', project => 'lab', vms => [
        vm('s1-tch-001', priority => 4), vm('s1-sch-001', disks => $DISK, priority => 4), vm('s1-tch-002', priority => 4),
    ] }, layout => $layout);
    is_deeply([ map { $_->{name} } $wl->_ordered($def) ], [ 's1-sch-001', 's1-tch-001', 's1-tch-002' ],
        'start: the provider first, then the consumers in definition order');
    is_deeply([ map { $_->{name} } reverse $wl->_ordered($def) ], [ 's1-tch-002', 's1-tch-001', 's1-sch-001' ],
        'stop: the consumers first, the provider last');
    $def->{vms}[0]{priority} = 1;
    is(($wl->_ordered($def))[0]{name}, 's1-tch-001', 'priority still comes first: a priority 1 consumer starts before a priority 4 provider');
}

#--- vm-start carries the priority and the role
{
    my $f = StorageFixture::setup_workload(no_def => 1,
        ce => { out => { 'vm-define' => "VM s1-tch-001 defined mac=52:54:00:12:34:56\n" } });
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    StorageFixture::write_def($f, { name => 's1', project => 'lab', vms => [ vm('s1-tch-001') ] });
    my $wl = $f->{wl}->();
    ok($wl->run('create', 's1')->{ok}, 'create ok');
    $f->{ce}{calls} = [];
    $wl->run('start', 's1');
    my ($start) = grep { $_->{script} eq 'vm-start' } $f->{ce}->calls;
    is_deeply($start->{args}, [ 's1-tch-001', '--priority', 3 ], 'a consumer: vm-start <vm> --priority 3');
}
{
    my $f = StorageFixture::setup_workload(no_def => 1,
        ce => { out => { 'vm-define' => "VM s1-sch-001 defined mac=52:54:00:12:34:57\n" } });
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    StorageFixture::write_def($f, { name => 's1', project => 'lab', vms => [ vm('s1-sch-001', disks => $DISK) ] });
    my $wl = $f->{wl}->();
    my $r = $wl->run('create', 's1');
    ok($r->{ok}, 'create of a provider ok') or diag explain $r;
    $f->{ce}{calls} = [];
    $wl->run('start', 's1');
    my ($start) = grep { $_->{script} eq 'vm-start' } $f->{ce}->calls;
    is_deeply($start->{args}, [ 's1-sch-001', '--priority', 1, '--provides-storage' ],
        'a provider: vm-start <vm> --priority 1 --provides-storage');
}

done_testing;
