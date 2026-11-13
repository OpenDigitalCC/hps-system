package WorkloadLegs;
# A workload whose root disk has two iSCSI legs on two storage hosts (sch-002,
# sch-003), as the scale probes do: the compute host sch-001 has no pool of its
# own, and the operator created each leg's zvol and export with hps-storage.
use strict;
use warnings;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

our %IQN = (a => 'iqn.2026-11.hps.lab:sch-002:t0-a', b => 'iqn.2026-11.hps.lab:sch-003:t0-b');
our %ZVOL = (a => 'lab/enc/vm/t0-a', b => 'lab/enc/vm/t0-b');
our %MAC = (a => '525400000002', b => '525400000003');

sub setup {
    my %o = @_;
    my $f = StorageFixture::setup_workload(%o, no_def => 1);
    my $reg = $f->{reg};
    my %host = (a => 'sch-002', b => 'sch-003');
    for my $l (qw(a b)) {
        my $m = $MAC{$l};
        $reg->host_set($m, 'STATE', 'NETWORK_BOOT');
        $reg->host_set($m, 'TYPE', 'SCH');
        $reg->host_set($m, 'HOSTNAME', $host{$l});
        $reg->host_set($m, 'IP', $l eq 'a' ? '192.0.2.52' : '192.0.2.53');
        $reg->host_set($m, 'storage_pool', 'lab');
        $reg->host_set($m, 'storage_exports', [ { zvol => $ZVOL{$l}, iqn => $IQN{$l},
            initiator => 'iqn.2026-11.hps.lab:sch-001.example', portal => $l eq 'a' ? '192.0.2.52' : '192.0.2.53' } ]);
    }
    my $def = { name => 't0', project => 'lab',
        access => { ssh_keys => ['ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest tester'], console => JSON::PP::true },
        vms => [ { name => 't0-vm', memory_mib => 2048, vcpus => 2, image => 'debian-13-generic-amd64', nets => ['mgmt'],
            priority => 1, compute_host => 'sch-001',
            disks => [ { name => 'root', size => '20G', legs => [
                { host => 'sch-002', iqn => $IQN{a}, portal => '192.0.2.52' },
                { host => 'sch-003', iqn => $IQN{b}, portal => '192.0.2.53' } ] } ] } ] };
    $f->{def} = $def;
    StorageFixture::write_def($f, $def);
    return $f;
}

sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }
sub calls { my ($f) = @_; return [ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ] }

1;
