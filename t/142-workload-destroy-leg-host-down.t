#!/usr/bin/env perl
# #14: a storage host that is down leaves its leg pending: destroy says so, the
# record stays (partly destroyed), and a later destroy completes only that leg.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use WorkloadLegs;

my $f = WorkloadLegs::setup();
my $wl = $f->{wl}->();
$wl->run('create', 't0');
$f->{ce}{rc}{'iscsi-unexport'} = [ 0, 1 ];    # leg a ok, leg b's host is down
$f->{ce}{calls} = [];
my $r = $wl->run('destroy', 't0', forget => 1);
ok(!$r->{ok}, 'destroy is not ok');
is(scalar @{ $r->{pending} }, 1, 'one leg pending');
is($r->{pending}[0]{iqn}, $WorkloadLegs::IQN{b}, 'the leg of the down host');
is($r->{pending}[0]{dataset}, $WorkloadLegs::ZVOL{b}, 'with its zvol');
like($r->{pending}[0]{error}, qr/iscsi-unexport exited 1/, 'and why');
like(join("\n", @{ $r->{notes} }), qr/INCOMPLETE.*sch-003.*run destroy t0 again/s, 'the notes say so');
is_deeply([ map { $_->{script} } grep { $_->{mac} eq $WorkloadLegs::MAC{b} } $f->{ce}->calls ], [ "iscsi-unexport" ], "the down host is asked the unexport only, no zvol destroy after it failed") or diag explain WorkloadLegs::calls($f);
is(scalar(grep { $_->{script} eq 'storage-zvol-destroy' } $f->{ce}->calls), 1, 'the other leg zvol was destroyed');
my $rec = WorkloadLegs::rec($f);
ok($rec, 'the record stays');
is($rec->{destroy_pending}[0]{iqn}, $WorkloadLegs::IQN{b}, 'with the pending leg');
ok(-e $f->{reg}->workload_dir('lab') . '/t0.json', 'the definition is kept while pending (--forget waits)');
ok(!$f->{reg}->cluster_exists('lab', 'workload_t0_destroyed'), 'no destroyed audit record yet');

my $e = eval { $wl->run('start', 't0'); 1 } ? undef : $@;
like(ref $e ? $e->message : '', qr/partly destroyed/, 'start refuses a partly destroyed workload');

# the host is back: only the pending leg is removed, then the record and (--forget) the definition go
$f->{ce}{rc} = {};
$f->{ce}{calls} = [];
$r = $wl->run('destroy', 't0');
ok($r->{ok} && !$r->{pending}, 'the second destroy completes');
is_deeply(WorkloadLegs::calls($f), [
    [ 'iscsi-unexport', $WorkloadLegs::IQN{b} ], [ 'storage-zvol-destroy', $WorkloadLegs::ZVOL{b} ] ], 'only the pending leg is touched') or diag explain WorkloadLegs::calls($f);
ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'record removed');
ok($f->{reg}->cluster_exists('lab', 'workload_t0_destroyed'), 'destroyed audit record written');
ok(!-e $f->{reg}->workload_dir('lab') . '/t0.json', 'the --forget of the first run is honoured');

done_testing;
