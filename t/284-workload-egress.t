#!/usr/bin/env perl
# IPS-42 row 2: a definition may declare its flavour and egress hosts; the
# fields are checked strictly, kept by validate, and `hps-workload egress`
# lists them with the workload's addresses. A declaration grants nothing here.
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

# the fields
my $ok = HPS::Workload::validate(def(flavour => 'podman-host', egress => ['production.cloudfront.docker.com', 'production.cloudfront.docker.com']));
is($ok->{flavour}, 'podman-host', 'flavour kept');
is_deeply($ok->{egress}, ['production.cloudfront.docker.com'], 'egress kept, a repeat dropped');
ok(!exists HPS::Workload::validate(def())->{egress}, 'no egress declared: none in the result');
refused(def(egress => 'a.example.org'), qr/egress must be a list/, 'egress as a string');
refused(def(egress => ['*.example.org']), qr/not a lower-case host name/, 'a wildcard host');
refused(def(egress => ['Example.org']), qr/not a lower-case host name/, 'upper case');
refused(def(egress => ['example.org:443']), qr/not a lower-case host name/, 'a port');
refused(def(egress => ['10.1.2.3']), qr/not a lower-case host name/, 'an address');
refused(def(egress => ['localhost']), qr/not a lower-case host name/, 'one label');
refused(def(egress => ['a b.example.org']), qr/not a lower-case host name/, 'a space');
refused(def(egress => [ map { "h$_.example.org" } 1 .. 17 ]), qr/more than 16/, 'too many');
refused(def(egress => [ {} ]), qr/not a lower-case host name/, 'a reference');
refused(def(flavour => 'Podman Host'), qr/flavour must be a name/, 'a bad flavour');
refused(def(flavour => ['x']), qr/flavour must be a name/, 'a flavour list');

# egress_rows through a created workload with a lease
my $dir = tempdir(CLEANUP => 1);
open(my $lf, '>', "$dir/leases") or die;
print {$lf} "2000000000 52:54:00:00:00:01 10.0.0.11 t0-app *\n";
close $lf;
local $ENV{HPS_DNSMASQ_LEASES} = "$dir/leases";
$StorageFixture::NOW = 1_800_000_000;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-status' => "NIC t0-app 0 tap0 br-mgmt 52:54:00:00:00:01 virtio\nVM x running\n", 'mirror-status' => "MIRROR x clean\n" } }, no_def => 1);
StorageFixture::write_def($f, def(flavour => 'podman-host', egress => ['production.cloudfront.docker.com']));
my $other = def(name => 't1');
StorageFixture::write_def($f, $other);
my $wl = $f->{wl}->(metrics => bless({}, 'NoMetrics'));
{ package NoMetrics; sub latest { die "none\n" } }
my $rows = HPS::Workload::Net::egress_rows($wl);
is_deeply($rows, [], 'defined but not created: no record, no row');
$wl->run('create', 't0');
$wl->run('start', 't0');
$wl->run('status', 't0');
$rows = HPS::Workload::Net::egress_rows($wl);
is_deeply([ map { $_->{name} } @$rows ], ['t0'], 'only a recorded workload declaring egress is listed');
is_deeply($rows->[0], { name => 't0', project => 'lab', flavour => 'podman-host', state => 'running',
    egress => ['production.cloudfront.docker.com'], addresses => ['10.0.0.11'] }, 'the row: flavour, hosts, the lease address');
is_deeply(HPS::Workload::Net::egress_rows($wl, project => 'other'), [], '--project filters');
like(HPS::Workload::Net::render_egress($rows), qr/^t0\s+podman-host\s+running\s+10\.0\.0\.11 -> production\.cloudfront\.docker\.com$/, 'text form');
like(HPS::Workload::Net::render_egress([]), qr/no workload declares/, 'text form of none');

done_testing;
