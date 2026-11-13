#!/usr/bin/env perl
# #14: destroy removes the export and the zvol of every iSCSI leg on its storage
# host (iscsi-unexport, then storage-zvol-destroy); create records the legs;
# --dry-run lists them; a host outside the registry is left alone with a note.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use WorkloadLegs;

my $f = WorkloadLegs::setup();
my $wl = $f->{wl}->();
$wl->run('create', 't0');

my $d = WorkloadLegs::rec($f)->{vms}{'t0-vm'}{disks}{root};
is_deeply($d->{remote}, [
    { host => 'sch-002', iqn => $WorkloadLegs::IQN{a}, dataset => $WorkloadLegs::ZVOL{a} },
    { host => 'sch-003', iqn => $WorkloadLegs::IQN{b}, dataset => $WorkloadLegs::ZVOL{b} } ], 'create records each leg: host, iqn and the zvol the host exports for it');

my $r = $wl->run('destroy', 't0', dry_run => 1);
my @plan = map { [ $_->{host}, $_->{script}, @{ $_->{args} } ] } @{ $r->{plan} };
is_deeply([ @plan[ -4 .. -1 ] ], [
    [ $WorkloadLegs::MAC{a}, 'iscsi-unexport', $WorkloadLegs::IQN{a} ],
    [ $WorkloadLegs::MAC{a}, 'storage-zvol-destroy', $WorkloadLegs::ZVOL{a} ],
    [ $WorkloadLegs::MAC{b}, 'iscsi-unexport', $WorkloadLegs::IQN{b} ],
    [ $WorkloadLegs::MAC{b}, 'storage-zvol-destroy', $WorkloadLegs::ZVOL{b} ] ], 'dry run lists both legs: unexport then zvol destroy, on the storage hosts') or diag explain \@plan;
$f->{ce}{calls} = [];
ok(WorkloadLegs::rec($f), 'dry run removes nothing');

$r = $wl->run('destroy', 't0');
ok($r->{ok} && !$r->{pending}, 'destroy ok');
my @c = grep { $_->{script} =~ /^(iscsi-unexport|storage-zvol-destroy)$/ } $f->{ce}->calls;
is_deeply([ map { [ $_->{mac}, $_->{script}, @{ $_->{args} } ] } @c ], [
    [ $WorkloadLegs::MAC{a}, 'iscsi-unexport', $WorkloadLegs::IQN{a} ],
    [ $WorkloadLegs::MAC{a}, 'storage-zvol-destroy', $WorkloadLegs::ZVOL{a} ],
    [ $WorkloadLegs::MAC{b}, 'iscsi-unexport', $WorkloadLegs::IQN{b} ],
    [ $WorkloadLegs::MAC{b}, 'storage-zvol-destroy', $WorkloadLegs::ZVOL{b} ] ], 'both legs unexported and destroyed on their own hosts') or diag explain \@c;
ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'record removed');
ok(!$f->{reg}->host_exists($WorkloadLegs::MAC{a}, 'storage_exports'), 'the storage host export list is updated');

#--- a record from before the legs were recorded: the zvol comes from the host's export list
{
    my $g = WorkloadLegs::setup();
    my $w = $g->{wl}->();
    $w->run('create', 't0');
    my $rec = WorkloadLegs::rec($g);
    delete $rec->{vms}{'t0-vm'}{disks}{root}{remote};
    $g->{reg}->cluster_set('lab', 'workload_t0', $rec);
    $g->{ce}{calls} = [];
    $w->run('destroy', 't0');
    is(scalar(grep { $_->{script} eq 'storage-zvol-destroy' } $g->{ce}->calls), 2, 'old record: the exported zvols are still found and destroyed');
}

#--- a leg host outside the registry (an external NAS) is not ours
{
    my $g = StorageFixture::setup_workload();    # legs on host 'nas'
    my $w = $g->{wl}->();
    $w->run('create', 't0');
    $g->{ce}{calls} = [];
    my $x = $w->run('destroy', 't0');
    ok($x->{ok}, 'destroy ok');
    is(scalar(grep { $_->{script} eq 'iscsi-unexport' } $g->{ce}->calls), 0, 'no unexport on a host the registry does not know');
    ok((grep { /host 'nas' is not in the registry/ } @{ $x->{notes} }), 'a note says so');
}

done_testing;
