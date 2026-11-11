#!/usr/bin/env perl
# CS-3.6: workload definition validation. Every refusal is named.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use Storable qw(dclone);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

my $layout = StorageFixture::layout();

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

# refuses($mutator, $re, $label): a copy of the base definition, mutated, is refused
# with kind 'refused' and a message matching $re.
sub refuses {
    my ($mut, $re, $label, %o) = @_;
    my $d = StorageFixture::base_def();
    $mut->($d);
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout, %o) });
    ok(defined $e && ref $e, "$label: refused") or return;
    is($e->kind, 'refused', "$label: kind refused");
    like($e->message, $re, "$label: reason named");
    return;
}

my $ok = HPS::Workload::validate(StorageFixture::base_def(), layout => $layout);
is($ok->{name}, 't0', 'the base definition is valid');
is($ok->{vms}[0]{compute}, 'sch-001', 'compute host = host of the first local leg');
is($ok->{vms}[1]{priority}, 1, 'priority carried');

# defaults and optional parts
{
    my $d = StorageFixture::base_def();
    delete $d->{access};
    delete $_->{priority} for @{ $d->{vms} };
    my $v = HPS::Workload::validate($d, layout => $layout);
    is_deeply($v->{access}, {}, 'access is optional');
    is($v->{vms}[0]{priority}, 3, 'priority defaults to 3');
}
{
    my $d = StorageFixture::base_def();
    ok(HPS::Workload::validate($d), 'nets are not compared with a layout unless one is passed');
}

# top level
refuses(sub { $_[0] = [] }, qr/must be a JSON object/, 'not an object');
refuses(sub { $_[0]{extra} = 1 }, qr/unknown field 'extra'/, 'unknown top field');
refuses(sub { $_[0]{name} = 'T0' }, qr/name must match/, 'upper-case name');
refuses(sub { $_[0]{name} = '0t' }, qr/name must match/, 'name starts with a digit');
refuses(sub { $_[0]{name} = 'a' x 33 }, qr/name must match/, 'name too long');
refuses(sub { delete $_[0]{project} }, qr/project/, 'no project');
refuses(sub { $_[0]{vms} = [] }, qr/vms must be a non-empty list/, 'no vms');
refuses(sub { $_[0]{vms}[1]{name} = 't0-app' }, qr/'t0-app' is used twice/, 'duplicate vm name');

# access
refuses(sub { $_[0]{access}{ssh_keys} = ['nonsense'] }, qr/not a public key/, 'bad ssh key');
refuses(sub { $_[0]{access}{ssh_keys} = 'x' }, qr/ssh_keys must be a list/, 'ssh_keys not a list');
refuses(sub { $_[0]{access}{console} = 'yes' }, qr/console must be true or false/, 'console not boolean');
refuses(sub { $_[0]{access}{shell} = 1 }, qr/unknown field 'shell'/, 'unknown access field');

# vm
refuses(sub { $_[0]{vms}[0]{name} = 'App' }, qr/name must match/, 'bad vm name');
refuses(sub { $_[0]{vms}[0]{memory_mib} = 255 }, qr/memory_mib must be 256-262144/, 'memory below range');
refuses(sub { $_[0]{vms}[0]{memory_mib} = 262145 }, qr/memory_mib must be 256-262144/, 'memory above range');
refuses(sub { $_[0]{vms}[0]{memory_mib} = '2g' }, qr/memory_mib/, 'memory not a number');
refuses(sub { $_[0]{vms}[0]{vcpus} = 0 }, qr/vcpus must be 1-64/, 'vcpus zero');
refuses(sub { $_[0]{vms}[0]{vcpus} = 65 }, qr/vcpus must be 1-64/, 'vcpus above range');
refuses(sub { $_[0]{vms}[0]{priority} = 0 }, qr/priority must be 1-5/, 'priority zero');
refuses(sub { $_[0]{vms}[0]{priority} = 6 }, qr/priority must be 1-5/, 'priority six');
refuses(sub { $_[0]{vms}[0]{image} = '../etc' }, qr/image must match/, 'image path traversal');
refuses(sub { $_[0]{vms}[0]{image} = '-x' }, qr/image must match/, 'image starts with a dash');
refuses(sub { $_[0]{vms}[0]{bogus} = 1 }, qr/unknown field 'bogus'/, 'unknown vm field');
refuses(sub { $_[0]{vms}[0]{nets} = [] }, qr/nets must be a non-empty list/, 'no nets');
# a net listed twice is two NICs on that network (IPS-15: two ports, one segment)
{
    my $x = StorageFixture::base_def();
    $x->{vms}[0]{nets} = [ 'mgmt', 'mgmt' ];
    my $d = HPS::Workload::validate($x, layout => $layout);
    is_deeply($d->{vms}[0]{nets}, [ 'mgmt', 'mgmt' ], 'a net listed twice gives two NICs on it');
}
refuses(sub { $_[0]{vms}[0]{nets} = ['nowhere'] }, qr/net 'nowhere' is not in the cluster's network_layout/, 'net not in the layout');

# no layout at all
{
    my $e = err_of(sub { HPS::Workload::validate(StorageFixture::base_def(), layout => undef) });
    is(ref $e && $e->kind, 'refused', 'no layout: refused');
    like($e->message, qr/net 'mgmt' is not in the cluster's network_layout/, 'no layout: the first net is named');
}

# disks
refuses(sub { $_[0]{vms}[0]{disks} = [] }, qr/disks must be a non-empty list/, 'no disks');
refuses(sub { push @{ $_[0]{vms}[0]{disks} }, dclone($_[0]{vms}[0]{disks}[0]) }, qr/at most 1 disk per VM/, 'second disk');
refuses(sub { $_[0]{vms}[0]{disks}[0]{name} = 'Root' }, qr/name must match/, 'bad disk name');
for my $size ('0G', '20', '20g', '20K', 'G', '-5G', '1.5G') {
    refuses(sub { $_[0]{vms}[0]{disks}[0]{size} = $size }, qr/size must match/, "size '$size'");
}
for my $size ('256M', '20G', '2T') {
    my $d = StorageFixture::base_def();
    $d->{vms}[0]{disks}[0]{size} = $size;
    ok(HPS::Workload::validate($d, layout => $layout), "size '$size' is fine");
}

# legs
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs} = [] }, qr/1 or 2 legs/, 'no legs');
refuses(sub { push @{ $_[0]{vms}[0]{disks}[0]{legs} }, { host => 'x', iqn => 'iqn.2026-01.a:b' } }, qr/1 or 2 legs/, 'three legs');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0] = { host => 'sch-001', pool => 'lab', iqn => 'iqn.2026-01.a:b' } }, qr/not both and not neither/, 'leg with pool and iqn');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0] = { host => 'sch-001' } }, qr/not both and not neither/, 'leg with neither');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0]{host} = 'bad host' }, qr/host must match/, 'bad leg host');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0]{pool} = 'Lab' }, qr/pool must match/, 'bad pool');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[1]{iqn} = 'nope' }, qr/iqn must match/, 'bad iqn');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[1]{portal} = 'host.example' }, qr/portal must be an IPv4/, 'bad portal');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0]{portal} = '192.0.2.9' }, qr/portal is only for an iqn leg/, 'portal on a local leg');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[1] = { host => 'sch-001', pool => 'lab' } }, qr/at most one local leg/, 'two local legs');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs} = [ { host => 'nas', iqn => 'iqn.2026-01.a:b' } ] }, qr/one leg needs a local/, 'one remote leg only');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0]{extra} = 1 }, qr/unknown field 'extra'/, 'unknown leg field');

# compute host
{
    my $d = StorageFixture::base_def();
    $d->{vms}[0]{disks}[0]{legs} = [ { host => 'nas', iqn => 'iqn.2026-01.a:b' }, { host => 'nas2', iqn => 'iqn.2026-01.a:c' } ];
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    like($e && $e->message, qr/no local .* leg and no compute_host/, 'all legs remote and no compute_host: refused');
    $d->{vms}[0]{compute_host} = 'cmp-001';
    is(HPS::Workload::validate($d, layout => $layout)->{vms}[0]{compute}, 'cmp-001', 'compute_host names a compute-only node');
    $d->{vms}[0]{compute_host} = 'bad host';
    $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    like($e && $e->message, qr/compute_host must match/, 'bad compute_host');
}
refuses(sub { $_[0]{vms}[0]{compute_host} = 'cmp-001' }, qr/compute_host 'cmp-001' differs from the host of its local legs \(sch-001\)/, 'compute_host disagrees with the local leg');
refuses(sub { $_[0]{vms}[0]{disks}[0]{legs}[0]{host} = 'other-host'; $_[0]{vms}[0]{compute_host} = 'sch-001' }, qr/differs from the host of its local legs/, 'local leg on another host than compute_host');

# loading from the registry's workload directory
{
    my $f = StorageFixture::setup_workload();
    my $wl = $f->{wl}->();
    like($f->{reg}->workload_dir('lab'), qr{/clusters/lab/workloads\z}, 'workload_dir is under the cluster directory');
    is($f->{reg}->workload_dir, $f->{reg}->workload_dir('lab'), 'workload_dir defaults to the active cluster');
    is($wl->load('t0')->{name}, 't0', 'load reads workloads/<name>.json');

    my $e = err_of(sub { $wl->load('nope') });
    is($e->kind, 'notfound', 'missing definition: notfound');
    $e = err_of(sub { $wl->load('Bad Name') });
    is($e->kind, 'usage', 'bad name: usage');

    my $path = $f->{reg}->workload_dir('lab') . '/junk.json';
    open(my $fh, '>', $path) or die;
    print {$fh} '{not json';
    close $fh;
    $e = err_of(sub { $wl->load('junk') });
    is($e->kind, 'refused', 'invalid JSON: refused');
    like($e->message, qr/not valid JSON/, 'invalid JSON named');

    my $d = StorageFixture::base_def();
    $d->{name} = 'other';
    open($fh, '>', "$path") or die;
    print {$fh} encode_json($d);
    close $fh;
    $e = err_of(sub { $wl->load('junk') });
    like($e->message, qr/name 'other' differs from the file name 'junk'/, 'name must equal the file name');

    $d = StorageFixture::base_def();
    $d->{name} = 'nonet';
    $d->{vms}[0]{nets} = ['ghost'];
    open($fh, '>', $f->{reg}->workload_dir('lab') . '/nonet.json') or die;
    print {$fh} encode_json($d);
    close $fh;
    $e = err_of(sub { $wl->load('nonet') });
    like($e->message, qr/net 'ghost' is not in the cluster's network_layout/, 'load checks nets against the cluster layout');
}

done_testing;
