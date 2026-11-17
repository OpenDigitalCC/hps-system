#!/usr/bin/env perl
# VM addresses from the IPS's dnsmasq leases, matched by MAC: parsing, expiry,
# and status --json per VM addresses.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload::List;

my $dir = tempdir(CLEANUP => 1);
open(my $lf, '>', "$dir/leases") or die;
print {$lf} <<'L';
2000000000 52:54:00:00:00:01 10.0.0.11 app-host *
1000000000 52:54:00:00:00:02 10.0.0.12 expired *
0 52:54:00:00:00:03 10.0.0.13 forever 01:52:54:00:00:03
1900000000 52:54:00:00:00:04 10.0.0.14 old *
2100000000 52:54:00:00:00:04 10.0.0.15 newer *
garbage line
duid 00:01
L
close $lf;
my $l = HPS::Workload::List::leases("$dir/leases", 1_800_000_000);
is($l->{'52:54:00:00:00:01'}{ip}, '10.0.0.11', 'lease read');
ok(!exists $l->{'52:54:00:00:00:02'}, 'an expired lease is none');
is($l->{'52:54:00:00:00:03'}{ip}, '10.0.0.13', 'expiry 0 is permanent');
is($l->{'52:54:00:00:00:04'}{ip}, '10.0.0.15', 'latest expiry wins');
is_deeply(HPS::Workload::List::leases("$dir/none", 1), {}, 'no file: no leases');

# status --json through a created workload
local $ENV{HPS_DNSMASQ_LEASES} = "$dir/leases";
$StorageFixture::NOW = 1_800_000_000;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-status' => "NIC t0-app 0 tap0 br-mgmt 52:54:00:00:00:01 virtio\nNIC t0-db 0 tap1 br-mgmt 52:54:00:00:00:09 virtio\nNIC t0-db 1 tap2 br-db 52:54:00:00:00:03 virtio\nVM x running\n", 'mirror-status' => "MIRROR x clean\n" } });
my $wl = $f->{wl}->(metrics => bless({}, 'NoMetrics'));
{ package NoMetrics; sub latest { die "none\n" } }
$wl->run('create', 't0');
$wl->run('start', 't0');
my $r = $wl->run('status', 't0');
my %v = map { $_->{vm} => $_ } @{ $r->{vms} };
is_deeply($v{'t0-app'}{addresses}, [ { net => 'mgmt', mac => '52:54:00:00:00:01', ip => '10.0.0.11', source => 'dhcp-lease', reserved => JSON::PP::true } ], 'app: its lease (the first status reserves it, IPS-42)');
is_deeply($v{'t0-db'}{addresses}, [ { net => 'db', mac => '52:54:00:00:00:03', ip => '10.0.0.13', source => 'dhcp-lease', reserved => JSON::PP::true } ],
    'db: only the NIC with a lease, net from the NIC index');
open($lf, '>', "$dir/leases") or die; close $lf;
$r = $wl->run('status', 't0');
is_deeply([ map { [ map { $_->{source} } @{ $_->{addresses} } ] } @{ $r->{vms} } ], [ ['reservation'], ['reservation'] ],
    'no leases: only the reservations made at the first status remain, source reservation (IPS-42 row 5)');

done_testing;
