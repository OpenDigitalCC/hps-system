#!/usr/bin/env perl
# IPS-42 row 6: "dns": ["*"] in a definition asks the IPS's DNS to answer
# <vm>.<domain> and *.<vm>.<domain> with the VM's reserved address. The field is
# checked strictly (one pattern exists, and the table that holds it takes more);
# the wildcard is published beside the host rows for a workload that exists and
# is gone with the workload.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;
use HPS::Workload::Net;

sub refused {
    my ($def, $re, $what) = @_;
    my $r = eval { HPS::Workload::validate($def); 1 };
    ok(!$r && ref $@ && $@->message =~ $re, $what) or diag($r ? 'accepted' : (ref $@ ? $@->message : $@));
}
sub def { my %x = @_; my $d = StorageFixture::base_def(); $d->{vms} = [ $d->{vms}[0] ]; $d->{vms}[0]{disks}[0]{legs} = [ { host => 'sch-001', pool => 'lab' } ]; return { %$d, %x } }

is_deeply(HPS::Workload::validate(def(dns => ['*', '*']))->{dns}, ['*'], 'the wildcard is accepted, a repeat dropped');
ok(!exists HPS::Workload::validate(def())->{dns}, 'no dns declared: none in the result');
is_deeply(HPS::Workload::validate(def(dns => []))->{dns}, [], 'an empty list is allowed (no names)');
refused(def(dns => '*'), qr/dns must be a list/, 'a string');
refused(def(dns => ['*.example.org']), qr/pattern '\*\.example\.org' is not supported \(supported: "\*"\)/, 'a pattern that is not the wildcard');
refused(def(dns => ['www']), qr/not supported/, 'a bare name');
refused(def(dns => [ {} ]), qr/not a pattern/, 'a reference');
refused(def(dns => [undef]), qr/not a pattern/, 'null');
refused(def(dns => [ '*', 'a', 'b', 'c', 'd' ]), qr/more than 4/, 'too many');
is_deeply([ sort keys %HPS::Workload::Net::DNS_PATTERNS ], ['*'], 'the table holds the one pattern (a further one is a further entry)');

# the published rows
my $dir = tempdir(CLEANUP => 1);
open(my $lf, '>', "$dir/leases") or die;
print {$lf} "2000000000 52:54:00:00:00:01 10.0.0.11 t0-app *\n";
close $lf;
local $ENV{HPS_DNSMASQ_LEASES} = "$dir/leases";
local $ENV{HPS_WORKLOAD_DNS_CMD};
$StorageFixture::NOW = 1_800_000_000;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-status' => "NIC t0-app 0 tap0 br-mgmt 52:54:00:00:00:01 virtio\nVM x running\n", 'mirror-status' => "MIRROR x clean\n" } }, no_def => 1);
StorageFixture::write_def($f, def(dns => ['*']));
my $wl = $f->{wl}->(metrics => bless({}, 'NoMetrics'));
{ package NoMetrics; sub latest { die "none\n" } }
my $hosts = $f->{reg}->cluster_dir('lab') . '/services/workload_hosts';
sub published { open(my $fh, '<', $hosts) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
$wl->run('create', 't0');
$wl->run('start', 't0');
HPS::Workload::Net::reserve($wl, 't0');
like(published(), qr/^host 52:54:00:00:00:01 10\.0\.0\.11 t0-app dns$/m, 'the host row');
like(published(), qr/^wild t0-app 10\.0\.0\.11$/m, 'the wildcard row, for the VM name and its NIC 0 address');
is(scalar(() = published() =~ /^wild /mg), 1, 'one wildcard row');

# the definition changes (a definition is replaced only while no workload exists, so
# edit the file as an operator would for a test): no dns, no wildcard on the next status
StorageFixture::write_def($f, def());
HPS::Workload::Net::reserve($wl, 't0');
unlike(published(), qr/^wild /m, 'a definition without dns: no wildcard row');
StorageFixture::write_def($f, def(dns => ['*']));
HPS::Workload::Net::reserve($wl, 't0');
like(published(), qr/^wild t0-app 10\.0\.0\.11$/m, 'and back');

# a plain destroy: the name stops resolving, the wildcard goes, the reservation stays
$wl->run('stop', 't0');
$wl->run('destroy', 't0');
unlike(published(), qr/^wild /m, 'destroy removed the wildcard row');
like(published(), qr/^host 52:54:00:00:00:01 10\.0\.0\.11 t0-app -$/m, 'the address stays reserved');
# a re-create brings both back
$wl->run('create', 't0');
like(published(), qr/^wild t0-app 10\.0\.0\.11$/m, 'create brought the wildcard back');
$wl->run('destroy', 't0', forget => 1);
unlike(published(), qr/^(?:wild|host) /m, 'destroy --forget removed every row');

done_testing;
