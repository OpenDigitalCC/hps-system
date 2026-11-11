#!/usr/bin/env perl
# Scale test phase 1: workload definitions with fabric NICs ({net,pvid,tagged,model}
# nets entries) and VM hardware ({disk_bus, smbios}); validation and the vm-define
# arguments the driver builds.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

my $layout = StorageFixture::layout();
$layout->{fab} = { kind => 'fabric', purpose => 'emulated-switch', bridge => 'br-fab' };

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

sub refuses {
    my ($mut, $re, $label) = @_;
    my $d = StorageFixture::base_def();
    $mut->($d->{vms}[0]);
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    ok(defined $e && ref $e, "$label: refused") or return;
    is($e->kind, 'refused', "$label: kind refused");
    like($e->message, $re, "$label: reason named");
    return;
}

sub accepts {
    my ($mut, $label) = @_;
    my $d = StorageFixture::base_def();
    $mut->($d->{vms}[0]);
    my $v = eval { HPS::Workload::validate($d, layout => $layout) };
    ok($v, "$label: valid") or diag $@ && $@->message;
    return $v;
}

# existing definitions are unchanged: no nics, no hardware keys
{
    my $v = HPS::Workload::validate(StorageFixture::base_def(), layout => $layout);
    ok(!exists $v->{vms}[0]{nics}, 'a definition with string nets has no nics key');
    ok(!exists $v->{vms}[0]{hardware}, 'and no hardware key');
}

# nets objects
{
    my $v = accepts(sub { $_[0]{nets} = [ 'mgmt', { net => 'fab', pvid => 110, tagged => [ 111, 112 ], model => 'e1000e' } ] }, 'fabric NIC');
    is_deeply($v->{vms}[0]{nets}, [ 'mgmt', 'fab' ], 'nets stay the list of names');
    is_deeply($v->{vms}[0]{nics}, [ { net => 'mgmt' }, { net => 'fab', pvid => 110, tagged => [ 111, 112 ], model => 'e1000e' } ],
        'nics carry the per-NIC options');
    accepts(sub { $_[0]{nets} = [ { net => 'mgmt', model => 'rtl8139' } ] }, 'model on a plain net');
    accepts(sub { $_[0]{nets} = [ { net => 'fab', pvid => 1 }, { net => 'fab', pvid => 4094 } ] }, 'two ports on one fabric');
}
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 0 } ] }, qr/pvid must be 1-4094/, 'pvid 0');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 4095 } ] }, qr/pvid must be 1-4094/, 'pvid 4095');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 'x' } ] }, qr/pvid must be 1-4094/, 'pvid text');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, tagged => 111 } ] }, qr/tagged must be a list/, 'tagged not a list');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, tagged => [0] } ] }, qr/tagged must be a list/, 'tagged 0');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, tagged => [ 111, 111 ] } ] }, qr/listed twice/, 'tagged twice');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, tagged => [110] } ] }, qr/also the pvid/, 'tagged = pvid');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, model => 'ne2k' } ] }, qr/model must be/, 'model');
refuses(sub { $_[0]{nets} = [ { net => 'fab', pvid => 110, bogus => 1 } ] }, qr/unknown field 'bogus'/, 'unknown NIC field');
refuses(sub { $_[0]{nets} = [ { pvid => 110 } ] }, qr/net names must match/, 'object without net');
refuses(sub { $_[0]{nets} = [ { net => 'ghost', pvid => 110 } ] }, qr/'ghost' is not in the cluster's network_layout/, 'object net not in layout');
refuses(sub { $_[0]{nets} = ['fab'] }, qr/fabric.*needs a pvid/, 'a fabric net as a plain name');
refuses(sub { $_[0]{nets} = [ { net => 'fab', model => 'virtio' } ] }, qr/needs a pvid/, 'fabric NIC without pvid');
refuses(sub { $_[0]{nets} = [ { net => 'mgmt', pvid => 5 } ] }, qr/not a fabric/, 'pvid on a plain net');
refuses(sub { $_[0]{nets} = [ { net => 'mgmt', tagged => [5] } ] }, qr/not a fabric/, 'tagged on a plain net');

# hardware
{
    my $v = accepts(sub { $_[0]{hardware} = { disk_bus => 'sata', smbios => { vendor => 'HPS Lab', product => 'Gen-C', serial => 'S3-001' } } }, 'hardware');
    is_deeply($v->{vms}[0]{hardware}, { disk_bus => 'sata', smbios => { vendor => 'HPS Lab', product => 'Gen-C', serial => 'S3-001' } },
        'hardware carried');
    accepts(sub { $_[0]{hardware} = { disk_bus => 'scsi' } }, 'disk_bus alone');
    accepts(sub { $_[0]{hardware} = { smbios => { vendor => 'A', product => 'B' } } }, 'smbios without serial');
    accepts(sub { $_[0]{hardware} = {} }, 'empty hardware');
}
refuses(sub { $_[0]{hardware} = [] }, qr/hardware must be an object/, 'hardware not an object');
refuses(sub { $_[0]{hardware} = { cpu => 'x' } }, qr/unknown field 'cpu'/, 'unknown hardware field');
refuses(sub { $_[0]{hardware} = { disk_bus => 'ide' } }, qr/disk_bus must be virtio, scsi or sata/, 'disk_bus');
refuses(sub { $_[0]{hardware} = { smbios => 'x' } }, qr/smbios must be an object/, 'smbios not an object');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => 'A' } } }, qr/product is required/, 'smbios without product');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => 'A', product => 'B', extra => 'C' } } }, qr/unknown field 'extra'/, 'smbios unknown key');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => "A'B", product => 'B' } } }, qr/smbios vendor must match/, 'quote in smbios');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => 'A<b>', product => 'B' } } }, qr/smbios vendor must match/, 'XML metacharacter in smbios');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => 'A,b', product => 'B' } } }, qr/smbios vendor must match/, 'comma in smbios');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => '', product => 'B' } } }, qr/smbios vendor must match/, 'empty smbios');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => 'a' x 64, product => 'B' } } }, qr/smbios vendor must match/, 'long smbios');
refuses(sub { $_[0]{hardware} = { smbios => { vendor => ['A'], product => 'B' } } }, qr/smbios vendor must match/, 'smbios ref');

# the driver: vm-define arguments
{
    my $f = StorageFixture::setup_workload();
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    my $d = StorageFixture::base_def();
    $d->{vms}[0]{nets} = [ 'mgmt', { net => 'fab', pvid => 110, tagged => [ 111, 112 ], model => 'e1000e' }, { net => 'fab', pvid => 7 } ];
    $d->{vms}[0]{hardware} = { disk_bus => 'scsi', smbios => { vendor => 'HPS Lab', product => 'Gen-B', serial => 'X1' } };
    StorageFixture::write_def($f, $d);
    my $plan = $f->{wl}->()->plan('create', 't0');
    my ($def) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-app' } @$plan;
    ok($def, 'plan has the vm-define of t0-app') or BAIL_OUT('no vm-define');
    my @a = @{ $def->{args} };
    my $i = 0;
    $i++ while $i < @a && $a[$i] ne '--net';
    is_deeply([ @a[ $i .. $i + 13 ] ],
        [ '--net', 'br-mgmt', '--net', 'br-fab', '--nic-model', 'e1000e', '--vlan-pvid', 110, '--vlan-tagged', '111,112',
          '--net', 'br-fab', '--vlan-pvid', 7 ],
        'per-NIC options follow their --net') or diag "@a";
    like("@a", qr/--disk-bus scsi --smbios vendor=HPS Lab,product=Gen-B,serial=X1\z/, 'hardware options close the call');
    my ($other) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-db' } @$plan;
    unlike("@{ $other->{args} }", qr/--nic-model|--vlan|--disk-bus|--smbios/, 'a VM without them gets none');
}

done_testing;
