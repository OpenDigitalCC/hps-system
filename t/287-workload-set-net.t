#!/usr/bin/env perl
# IPS-42: `hps-workload set` changes exactly flavour, egress and dns of the stored
# definition of an existing workload (define --replace refuses while it exists),
# checked as at define time, with --dry-run, and nothing else.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;
use HPS::Workload::Net;

local $ENV{HPS_DNSMASQ_LEASES} = '/nonexistent';
local $ENV{HPS_WORKLOAD_DNS_CMD};
$StorageFixture::NOW = 1_800_000_000;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-status' => "NIC t0-app 0 tap0 br-mgmt 52:54:00:00:00:01 virtio\nVM x running\n", 'mirror-status' => "MIRROR x clean\n" } }, no_def => 1);
my $d = StorageFixture::base_def();
$d->{vms} = [ $d->{vms}[0] ];
$d->{vms}[0]{disks}[0]{legs} = [ { host => 'sch-001', pool => 'lab' } ];
my $path = StorageFixture::write_def($f, $d);
my $wl = $f->{wl}->(metrics => bless({}, 'NoMetrics'));
{ package NoMetrics; sub latest { die "none\n" } }
$wl->run('create', 't0');    # a workload that exists: define --replace refuses
sub stored { open(my $fh, '<', $path) or die; local $/; my $t = <$fh>; close $fh; return JSON::PP->new->decode($t) }
sub refused { my ($re, $what, @a) = @_; my $r = eval { HPS::Workload::Net::set_net($wl, 't0', @a); 1 }; ok(!$r && ref $@ && $@->message =~ $re, $what) or diag($r ? 'accepted' : (ref $@ ? $@->message : $@)) }

my $before = JSON::PP->new->canonical->encode(do { my $s = stored(); delete @$s{qw(flavour egress dns)}; $s });
my $r = HPS::Workload::Net::set_net($wl, 't0', flavour => 'podman-host', egress => ['production.cloudfront.docker.com'], dns => ['*']);
is_deeply([ map { $_->{field} } @{ $r->{changes} } ], [qw(flavour egress dns)], 'three changes');
my $s = stored();
is($s->{flavour}, 'podman-host', 'flavour stored');
is_deeply($s->{egress}, ['production.cloudfront.docker.com'], 'egress stored');
is_deeply($s->{dns}, ['*'], 'dns stored');
is(JSON::PP->new->canonical->encode(do { my %c = %$s; delete @c{qw(flavour egress dns)}; \%c }), $before, 'nothing else of the definition changed');
ok($f->{reg}->cluster_exists('lab', 'workload_t0'), 'the record is there and untouched');
is(HPS::Workload::class_of($f->{reg}->cluster_get_json('lab', 'workload_t0')), 3, 'record class unchanged');

# dry run
$r = HPS::Workload::Net::set_net($wl, 't0', egress => undef, dry_run => 1);
is_deeply([ map { $_->{field} } @{ $r->{changes} } ], ['egress'], 'dry run: reports the change');
is_deeply(stored()->{egress}, ['production.cloudfront.docker.com'], 'and writes nothing');
like(HPS::Workload::Net::render_set($r), qr/^Dry run: set t0; nothing is changed\./, 'text form says so');

# same value: no change, no write; none removes
is(scalar @{ HPS::Workload::Net::set_net($wl, 't0', flavour => 'podman-host')->{changes} }, 0, 'the same value is no change');
HPS::Workload::Net::set_net($wl, 't0', egress => undef, dns => undef);
ok(!exists stored()->{egress} && !exists stored()->{dns}, 'none removes the fields');
is(stored()->{flavour}, 'podman-host', 'flavour untouched by that');

# validated as at define time
refused(qr/not a lower-case host name/, 'a wildcard host', egress => ['*.example.org']);
refused(qr/more than 16/, 'too many hosts', egress => [ map { "h$_.example.org" } 1 .. 17 ]);
refused(qr/pattern 'x' is not supported/, 'an unknown dns pattern', dns => ['x']);
refused(qr/flavour must be a name/, 'a bad flavour', flavour => 'Bad Name');
refused(qr/needs at least one/, 'nothing to set');
is_deeply([ sort grep { /^(flavour|egress|dns)$/ } keys %{ stored() } ], ['flavour'], 'a refusal wrote nothing');

# only these fields exist for set
eval { HPS::Workload::Net::set_net($wl, 't0', class => 1) };
like($@ ? $@->message : '', qr/needs at least one/, 'another field is not editable');
eval { HPS::Workload::Net::set_net($wl, 'nope', flavour => 'x') };
like(ref $@ ? $@->message : "$@", qr/no workload definition/, 'an unknown workload');

# the verb
my $o = `$^X -I$Bin/../lib/perl $Bin/../bin/hps-workload set t0 --class 2 2>&1`;
isnt($? >> 8, 0, 'the verb takes no other option');
$o = `$^X -I$Bin/../lib/perl $Bin/../bin/hps-workload set t0 2>&1`;
is($? >> 8, 2, 'the verb needs a field');
like($o, qr/set needs at least one of --flavour, --egress, --dns/, 'and says which');
$o = `$^X -I$Bin/../lib/perl $Bin/../bin/hps-workload destroy t0 --egress a.example.org 2>&1`;
is($? >> 8, 2, 'the options are only for set');

done_testing;
