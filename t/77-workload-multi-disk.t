#!/usr/bin/env perl
# A VM with several disks: validation (1..8, unique names), one zvol-create per
# local leg then one vm-define with a --disk per disk in definition order, a
# mirror per two-leg disk, and the destroy that cleans a create stopped part way.
use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $MAC = $StorageFixture::MAC;

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }
sub script_list { my ($f) = @_; return map { "$_->{script}" } $f->{ce}->calls }

sub local_disk { my ($n) = @_; return { name => $n, size => '20G', legs => [ { host => 'sch-001', pool => 'lab' } ] } }

sub three_disk_def {
    my $d = StorageFixture::base_def();
    $d->{vms} = [ {
        name => 't0-st', memory_mib => 2048, vcpus => 2, nets => ['mgmt'], boot => 'network',
        disks => [ map { local_disk($_) } qw(d1 d2 d3) ],
    } ];
    return $d;
}

sub fixture {
    my $f = StorageFixture::setup_workload(no_def => 1);
    StorageFixture::write_def($f, three_disk_def());
    return $f;
}

#--- validation
my $layout = StorageFixture::layout();
{
    my $d = three_disk_def();
    ok(HPS::Workload::validate($d, layout => $layout), 'three disks are valid');
    $d->{vms}[0]{disks} = [ map { local_disk("d$_") } 1 .. 8 ];
    ok(HPS::Workload::validate($d, layout => $layout), 'eight disks are valid');
    $d->{vms}[0]{disks} = [ map { local_disk("d$_") } 1 .. 9 ];
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    like($e->message, qr/at most 8 disks per VM/, 'nine disks are refused');
    $d->{vms}[0]{disks} = [ local_disk('d1'), local_disk('d1') ];
    $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    like($e->message, qr/disk name 'd1' is used twice/, 'a repeated disk name is refused');
}

#--- plan and run: three zvols, then one vm-define with three --disk in order
{
    my $f = fixture();
    my $plan = $f->{wl}->()->plan('create', 't0');
    is_deeply([ map { $_->{script} } @$plan ], [ ('storage-zvol-create') x 3, 'net-bridge-ensure', 'vm-define' ],
        'create plan: a zvol per disk, bridge, one define');
    is_deeply([ map { $_->{args}[0] } @$plan[ 0 .. 2 ] ],
        [ map { "lab/enc/vm/t0-t0-st-$_" } qw(d1 d2 d3) ], 'zvol datasets in definition order');
    my ($def) = grep { $_->{script} eq 'vm-define' } @$plan;
    is_deeply($def->{args},
        [ 't0-st', '--memory', 2048, '--vcpus', 2, '--boot', 'network',
          '--disk', '/dev/zvol/lab/enc/vm/t0-t0-st-d1', '--disk', '/dev/zvol/lab/enc/vm/t0-t0-st-d2',
          '--disk', '/dev/zvol/lab/enc/vm/t0-t0-st-d3', '--net', 'br-mgmt' ],
        'vm-define: one --disk per disk, in order');
    my $r = $f->{wl}->()->run('create', 't0');
    ok($r->{ok}, 'create ok');
}

#--- a mixed definition: a mirrored disk and a plain one
{
    my $f = StorageFixture::setup_workload(no_def => 1);
    my $d = three_disk_def();
    $d->{vms}[0]{disks} = [ local_disk('d1'), { name => 'd2', size => '20G', legs => [
        { host => 'sch-001', pool => 'lab' },
        { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-t0-d2', portal => '192.0.2.50' } ] } ];
    StorageFixture::write_def($f, $d);
    my $plan = $f->{wl}->()->plan('create', 't0');
    is_deeply([ map { $_->{script} } @$plan ], [ ('storage-zvol-create') x 2, 'mirror-create', 'net-bridge-ensure', 'vm-define' ],
        'a mirror only for the two-leg disk');
    my ($def) = grep { $_->{script} eq 'vm-define' } @$plan;
    is_deeply([ grep { $def->{args}[$_] eq '--disk' } 0 .. $#{ $def->{args} } ], [ 7, 9 ], 'two --disk');
    is_deeply([ @{ $def->{args} }[ 8, 10 ] ], [ '/dev/zvol/lab/enc/vm/t0-t0-st-d1', '/dev/md/t0-st-d2' ],
        'device per disk: zvol, then the mirror') or diag explain $def->{args};
}

#--- the second zvol fails: destroy removes the first (tried) and the failed one, not the third
{
    my $f = fixture();
    my $wl = $f->{wl}->();
    $f->{ce}{rc}{'storage-zvol-create'} = [ 0, 1 ];
    my $e = err_of(sub { $wl->run('create', 't0') });
    is($e->kind, 'failed', 'create fails on the second zvol');
    is_deeply([ script_list($f) ], [ ('storage-zvol-create') x 2 ], 'nothing runs after the failure');
    delete $f->{ce}{rc}{'storage-zvol-create'};
    $f->{ce}{calls} = [];
    my $r = $wl->run('destroy', 't0');
    ok($r->{ok}, 'destroy of the unfinished create ok');
    is_deeply([ script_list($f) ], [ ('storage-zvol-destroy') x 2 ], 'the first and the failed zvol are destroyed, the third is skipped');
    is_deeply([ map { $_->{args}[0] } $f->{ce}->calls ],
        [ map { "lab/enc/vm/t0-t0-st-$_" } qw(d1 d2) ], 'the right datasets') or diag explain [ $f->{ce}->calls ];
}

done_testing;
