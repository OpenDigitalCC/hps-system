#!/usr/bin/env perl
# hps-node resources: the COMMITTED line from the workload records on that host.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Node;

my $f = StorageFixture::setup(ce => { out => { 'host-resources' =>
    "RESERVE roles=SCH cpus=48 host_cpus=0-1 guest_cpus=2-47 mem_total_mib=257788 host_mem_mib=25778 arc_max_mib=64447 guest_mem_max_mib=167563\nMEM total_mib=1\n" } });
my $reg = $f->{reg};
sub vm { my ($host, $state, $mem, $cpu) = @_;
    return { host => $host, state => $state, define => [ 'x', '--memory', $mem, '--vcpus', $cpu, '--disk', '/d', '--net', 'br' ] } }
my $n = sub { HPS::Node->new(host => 'sch-001', registry => $f->{reg}, storage => $f->{mk}->(), runner => $f->{ce}, logger => sub { }) };

like($n->()->resources->{stdout}, qr/^COMMITTED vcpus=0 mem_mib=0 guests=0 free_mem_mib=167563 running_guests=0 running_mem_mib=0$/m, 'no workloads: all free');

$reg->cluster_set('lab', 'workload_a', { state => 'running', vms => { 'a-1' => vm('sch-001', 'running', 8192, 4), 'a-2' => vm('sch-001', 'stopped', 4096, 2) } });
$reg->cluster_set('lab', 'workload_b', { state => 'running', vms => { 'b-1' => vm($StorageFixture::MAC, 'running', 1024, 1), 'b-2' => vm('sch-002', 'running', 99999, 40) } });
$reg->cluster_set('lab', 'workload_c', { state => 'created', vms => { 'c-1' => vm('sch-001', 'suspended', 2048, 2) } });
$reg->cluster_set('lab', 'workload_c_destroyed', { at => 'x' });
my $r = $n->()->resources;
like($r->{stdout}, qr/^COMMITTED vcpus=9 mem_mib=15360 guests=4 free_mem_mib=152203 running_guests=2 running_mem_mib=9216$/m,
    'defined guests on this host (by hostname or MAC), running or not; other hosts and audit keys excluded') or diag $r->{stdout};
like($r->{stdout}, qr/\ACOMMITTED.*\n?|RESERVE.*\nMEM.*\nCOMMITTED.*\nIOBUDGET/s, 'between the node output and IOBUDGET');
is($r->{rc}, 0, 'rc');

# no RESERVE line: free is a dash
my $f2 = StorageFixture::setup();
my $n2 = HPS::Node->new(host => 'sch-001', registry => $f2->{reg}, storage => $f2->{mk}->(), runner => $f2->{ce}, logger => sub { });
like($n2->resources->{stdout}, qr/^COMMITTED vcpus=0 mem_mib=0 guests=0 free_mem_mib=- /m, 'no guest_mem_max_mib: dash');
done_testing;
