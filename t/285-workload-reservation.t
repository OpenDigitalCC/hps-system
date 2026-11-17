#!/usr/bin/env perl
# IPS-42 row 5: a DHCP reservation per workload NIC, by MAC, recorded with the
# workload (cluster key workloadnet_<name>), made from the current lease, shown
# in status, kept across a re-create (new MACs, same address), released by
# destroy --forget, published for the dnsmasq generators.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;
use HPS::Workload::Net;
use HPS::Workload::List;

my $dir = tempdir(CLEANUP => 1);
sub leases { open(my $lf, '>', "$dir/leases") or die; print {$lf} $_[0]; close $lf }
my $LEASES = "2000000000 52:54:00:00:00:01 10.0.0.11 t0-app *\n2000000000 52:54:00:00:00:03 10.0.0.13 t0-db *\n";
leases('');    # none yet when the VMs are created and started
local $ENV{HPS_DNSMASQ_LEASES} = "$dir/leases";
local $ENV{HPS_WORKLOAD_DNS_CMD};
$StorageFixture::NOW = 1_800_000_000;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-status' => "NIC t0-app 0 tap0 br-mgmt 52:54:00:00:00:01 virtio\nNIC t0-db 0 tap1 br-mgmt 52:54:00:00:00:09 virtio\nNIC t0-db 1 tap2 br-db 52:54:00:00:00:03 virtio\nVM x running\n", 'mirror-status' => "MIRROR x clean\n" } });
my $wl = $f->{wl}->(metrics => bless({}, 'NoMetrics'));
{ package NoMetrics; sub latest { die "none\n" } }
my $hosts = $f->{reg}->cluster_dir('lab') . '/services/workload_hosts';
$wl->run('create', 't0');
$wl->run('start', 't0');
leases($LEASES);

# before anything: no reservation, create did not make one, no file
ok(!$f->{reg}->cluster_exists('lab', 'workloadnet_t0'), 'create and a start with no lease yet reserved nothing');
ok(!-e $hosts, 'no published file either');

# a dry run changes nothing
my $r = HPS::Workload::Net::reserve($wl, 't0', dry_run => 1);
is_deeply([ map { "$_->{vm}/$_->{nic}/$_->{mac}/$_->{ip}/$_->{action}" } @{ $r->{changes} } ],
    ['t0-app/0/52:54:00:00:00:01/10.0.0.11/reserved', 't0-db/1/52:54:00:00:00:03/10.0.0.13/reserved'], 'dry run: the NICs that hold a lease');
ok(!$f->{reg}->cluster_exists('lab', 'workloadnet_t0') && !-e $hosts, 'dry run wrote nothing');
like(join("\n", @{ $r->{notes} }), qr/t0-db NIC 0 \(52:54:00:00:00:09\): no lease yet/, 'a NIC without a lease is noted, not reserved');

# status only reads: it shows the lease, writes nothing, and says what to run
my $s = $wl->run('status', 't0');
my %v = map { $_->{vm} => $_ } @{ $s->{vms} };
is_deeply($v{'t0-app'}{addresses}, [ { net => 'mgmt', mac => '52:54:00:00:00:01', ip => '10.0.0.11', source => 'dhcp-lease' } ],
    'status: the leased address, not marked reserved');
ok(!$f->{reg}->cluster_exists('lab', 'workloadnet_t0') && !-e $hosts, 'status wrote no reservation and no file');
HPS::Workload::Net::reserve($wl, 't0');
$s = $wl->run('status', 't0');
%v = map { $_->{vm} => $_ } @{ $s->{vms} };
is_deeply($v{'t0-app'}{addresses}, [ { net => 'mgmt', mac => '52:54:00:00:00:01', ip => '10.0.0.11', source => 'dhcp-lease', reserved => JSON::PP::true } ],
    'after reserve: the leased address is marked reserved');
my $got = $f->{reg}->cluster_get_json('lab', 'workloadnet_t0');
is_deeply([ map { "$_->{nic}:$_->{mac}:$_->{ip}:$_->{net}" } @{ $got->{'t0-app'} } ], ['0:52:54:00:00:00:01:10.0.0.11:mgmt'], 'recorded by VM and NIC index');
is_deeply([ map { "$_->{nic}:$_->{mac}:$_->{ip}:$_->{net}" } @{ $got->{'t0-db'} } ], ['1:52:54:00:00:00:03:10.0.0.13:db'], 'NIC 1 of t0-db, NIC 0 had no lease');
open(my $fh, '<', $hosts) or die "no $hosts: $!";
my $pub = do { local $/; <$fh> };
close $fh;
like($pub, qr/^host 52:54:00:00:00:01 10\.0\.0\.11 t0-app dns$/m, 'published: NIC 0 under the VM name');
like($pub, qr/^host 52:54:00:00:00:03 10\.0\.0\.13 t0-db-nic1 dns$/m, 'published: NIC 1 under <vm>-nic1');

# idempotent, and the lease going away leaves the reservation visible
my $again = HPS::Workload::Net::reserve($wl, 't0');
is(scalar @{ $again->{changes} }, 0, 'a second reserve changes nothing');
leases('');
$s = $wl->run('status', 't0');
%v = map { $_->{vm} => $_ } @{ $s->{vms} };
is_deeply($v{'t0-app'}{addresses}, [ { net => 'mgmt', mac => '52:54:00:00:00:01', ip => '10.0.0.11', source => 'reservation', reserved => JSON::PP::true } ],
    'no lease: the reservation still shows, source reservation');

# a re-created VM: new MAC, same address
my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t0');
$rec->{vms}{'t0-app'}{macs} = ['52:54:00:00:00:77'];
$f->{reg}->cluster_set('lab', 'workload_t0', $rec);
$again = HPS::Workload::Net::reserve($wl, 't0');
is_deeply([ map { "$_->{vm}/$_->{mac}/$_->{ip}/$_->{action}" } @{ $again->{changes} } ],
    ['t0-app/52:54:00:00:00:77/10.0.0.11/re-pointed from 52:54:00:00:00:01'], 'a changed MAC takes over the reserved address');
open($fh, '<', $hosts) or die; $pub = do { local $/; <$fh> }; close $fh;
like($pub, qr/^host 52:54:00:00:00:77 10\.0\.0\.11 t0-app dns$/m, 'published with the new MAC');
unlike($pub, qr/00:01 /, 'the old MAC is gone from the published file');

# an address a registered host holds is never reserved
$f->{reg}->host_set($StorageFixture::MAC, 'IP', '10.0.0.15');
$f->{reg}->cluster_unset('lab', 'workloadnet_t0');
leases("2000000000 52:54:00:00:00:77 10.0.0.15 t0-app *\n");
$again = HPS::Workload::Net::reserve($wl, 't0');
is(scalar @{ $again->{changes} }, 0, 'an address of a registered host is refused');
like(join("\n", @{ $again->{notes} }), qr/10\.0\.0\.15 is already held by registered host/, 'and said');

# another workload's reservation is never taken
leases("2000000000 52:54:00:00:00:77 10.0.0.16 t0-app *\n");
$f->{reg}->cluster_set('lab', 'workloadnet_other', { vm1 => [ { nic => 0, net => 'mgmt', mac => '52:54:00:aa:00:01', ip => '10.0.0.16', since => 'x' } ] });
$again = HPS::Workload::Net::reserve($wl, 't0');
like(join("\n", @{ $again->{notes} }), qr/10\.0\.0\.16 is already held by workload other/, 'another workload\'s address is refused');
$f->{reg}->cluster_unset('lab', 'workloadnet_other');

# the hook: run as <cmd> dns-dhcp, its failure said
my $hook = "$dir/hook.sh";
open(my $hf, '>', $hook) or die;
print {$hf} "#!/bin/sh\necho \"\$@\" >> $dir/hook.log\n[ -n \"\$HOOK_FAIL\" ] && { echo oops; exit 3; }\nexit 0\n";
close $hf;
chmod 0755, $hook;
leases("2000000000 52:54:00:00:00:77 10.0.0.11 t0-app *\n");
{
    local $ENV{HPS_WORKLOAD_DNS_CMD} = $hook;
    $again = HPS::Workload::Net::reserve($wl, 't0');
    is(scalar @{ $again->{changes} }, 1, 'reserved again after the key was cleared');
    like(join("\n", @{ $again->{notes} }), qr/regenerated the DHCP and DNS files/, 'the hook ran');
    open(my $lg, '<', "$dir/hook.log") or die; my $l = <$lg>; close $lg;
    is($l, "dns-dhcp\n", 'as <cmd> dns-dhcp');
    local $ENV{HOOK_FAIL} = 1;
    my $rel = HPS::Workload::Net::release($wl, 't0');
    like("@$rel", qr/FAILED \(exit 3\): oops/, 'a failing hook is said with its exit and output');
}
ok(!$f->{reg}->cluster_exists('lab', 'workloadnet_t0'), 'release removed the key');
open($fh, '<', $hosts) or die; $pub = do { local $/; <$fh> }; close $fh;
unlike($pub, qr/^host /m, 'and the published rows');

# destroy --forget releases
leases("2000000000 52:54:00:00:00:77 10.0.0.11 t0-app *\n");
$wl->run('stop', 't0');
ok($f->{reg}->cluster_exists('lab', 'workloadnet_t0'), 'a state-changing verb (stop) reserves a NIC that holds a lease');
$wl->run('destroy', 't0');
ok($f->{reg}->cluster_exists('lab', 'workloadnet_t0'), 'a plain destroy keeps the reservation (the address survives a re-create)');
open($fh, '<', $hosts) or die; $pub = do { local $/; <$fh> }; close $fh;
like($pub, qr/^host 52:54:00:00:00:77 10\.0\.0\.11 t0-app -$/m, 'its name stops resolving: dhcp only, no dns');
$wl->run('create', 't0');
$wl->run('destroy', 't0', forget => 1);
ok(!$f->{reg}->cluster_exists('lab', 'workloadnet_t0'), 'destroy --forget released it');

# the verb refuses what it does not take
my $o = `$^X -I$Bin/../lib/perl $Bin/../bin/hps-workload reserve x --force 2>&1`;
is($? >> 8, 2, 'reserve takes only --dry-run and --json');
like($o, qr/reserve takes only/, 'and says so');

done_testing;
