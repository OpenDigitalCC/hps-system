#!/usr/bin/env perl
# Growing a VM's disk (lab 2026-11-12, cnh-001's state disk filled):
# HPS::Storage zvol-grow (one storage-zvol-grow call, the host's pool only),
# hps-storage zvol-grow, and HPS::Workload / hps-workload grow-disk
# (storage-zvol-grow then vm-disk-resize, a single local zvol only).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $MAC = $StorageFixture::MAC;
my $DS  = 'lab/enc/vm/t1-t1-cnh-d0';

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

#--- HPS::Storage zvol-grow
ok(scalar(grep { $_ eq 'zvol-grow' } HPS::Storage::ops()), 'zvol-grow is an op');
{
    my $f = StorageFixture::setup();
    my $st = $f->{mk}->();
    my $r = $st->run('zvol-grow', dataset => $DS, size => '64G');
    ok($r->{ok}, 'zvol-grow runs');
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ], [ [ 'storage-zvol-grow', $DS, '64G' ] ],
        'one storage-zvol-grow call: dataset and the new size');
    is(($f->{ce}->calls)[0]{input}, undef, 'no input');
    is($f->{reg}->host_get_json($MAC, 'storage_last')->{op}, 'zvol-grow', 'storage_last records the op');
    for my $bad (undef, '', '1', '0G', '64g', '1.5G', '64G; x') {
        my $e = err_of(sub { $st->run('zvol-grow', dataset => $DS, size => $bad) });
        is(ref $e && $e->kind, 'usage', 'bad size ' . ($bad // 'undef') . ': usage');
    }
    for my $bad ('lab/t0', 'lab/enc', 'lab/enc/a/b', '/lab/enc/t0') {
        my $e = err_of(sub { $st->run('zvol-grow', dataset => $bad, size => '64G') });
        is(ref $e && $e->kind, 'usage', "bad dataset $bad: usage");
    }
    is(err_of(sub { $st->run('zvol-grow', dataset => 'other/enc/vm/x', size => '64G') })->kind, 'refused',
        'a dataset in another pool is refused');
    is(scalar($f->{ce}->calls), 1, 'refusals called nothing');
}
{
    my $f = StorageFixture::setup(ce => { rc => { 'storage-zvol-grow' => 3 } });
    my $e = err_of(sub { $f->{mk}->()->run('zvol-grow', dataset => $DS, size => '8G') });
    is($e->kind, 'refused', 'the node refusing (a shrink, exit 3) is a refusal');
}

#--- hps-storage zvol-grow
{
    my $f   = StorageFixture::setup();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}       = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}   = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}           = "$tmp/hps-run";
    local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
    local $ENV{SHIM_DIR}              = $tmp;
    local $ENV{SUDO_USER}             = 'tester';
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-storage", @_);
        my $out = qx(@cmd 2>&1);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $cli->($MAC, 'zvol-grow', $DS);
    is($rc, 2, 'hps-storage zvol-grow without a size: usage');
    ($rc, $out) = $cli->($MAC, 'zvol-grow', $DS, '64G', 'x');
    is($rc, 2, 'an extra argument: usage');
    ok(!-e "$tmp/args", 'usage errors call nothing');
    ($rc, $out) = $cli->($MAC, 'zvol-grow', $DS, '64G', '--dry-run');
    is($rc, 0, '--dry-run: 0');
    like($out, qr{1\. storage-zvol-grow \Q$DS\E 64G}, 'the call is shown');
    ok(!-e "$tmp/args", 'a dry run calls nothing');
    ($rc, $out) = $cli->($MAC, 'zvol-grow', $DS, '64G');
    is($rc, 0, 'zvol-grow runs');
    like($out, qr{== 1\. storage-zvol-grow \Q$DS\E 64G \(exit 0\)}, 'result shown');
    open(my $h, '<', "$tmp/args") or die;
    like(do { local $/; <$h> }, qr{^--json $MAC storage-zvol-grow \Q$DS\E 64G$}m, 'sent to the host');
}

#--- HPS::Workload grow-disk
sub cnh_def {
    my $d = StorageFixture::base_def();
    $d->{name} = 't1';
    $d->{vms} = [ {
        name => 't1-cnh', memory_mib => 2048, vcpus => 2, nets => ['mgmt'], boot => 'network',
        disks => [ { name => 'd0', size => '20G', legs => [ { host => 'sch-001', pool => 'lab' } ] },
                   { name => 'd1', size => '20G', legs => [ { host => 'sch-001', pool => 'lab' },
                       { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-t1-d1', portal => '192.0.2.50' } ] } ],
    } ];
    return $d;
}

sub wl_fixture {
    my $f = StorageFixture::setup_workload(no_def => 1);
    StorageFixture::write_def($f, cnh_def());
    return $f;
}

ok(scalar(grep { $_ eq 'grow-disk' } HPS::Workload::ops()), 'grow-disk is an op');
{
    my $f = wl_fixture();
    my $e = err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd0', size => '64G') });
    is($e->kind, 'notfound', 'grow-disk of a workload never created: not found');
    $f->{wl}->()->run('create', 't1');
    $f->{ce}{calls} = [];

    my $plan = $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd0', size => '64G');
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } @$plan ],
        [ [ 'storage-zvol-grow', $DS, '64G' ], [ 'vm-disk-resize', 't1-cnh', "/dev/zvol/$DS" ] ],
        'plan: storage-zvol-grow of the disk\'s zvol, then vm-disk-resize by its device');
    is($plan->[0]{host}, $MAC, 'on the compute host');

    my $r = $f->{wl}->()->run('grow-disk', 't1', vm => 't1-cnh', disk => 'd0', size => '64G');
    ok($r->{ok}, 'grow-disk runs');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-zvol-grow', 'vm-disk-resize' ], 'the two calls, in order');
    like(join(' ', @{ $r->{notes} }), qr/definition still says 20G/, 'notes that the definition keeps its size');
    is($f->{reg}->cluster_get_json('lab', 'workload_t1')->{state}, 'created', 'the record is unchanged');

    $f->{ce}{calls} = [];
    is(err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd1', size => '64G') })->kind,
        'refused', 'a mirrored disk is refused');
    is(err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd9', size => '64G') })->kind,
        'notfound', 'an unknown disk: not found');
    is(err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 'nosuch', disk => 'd0', size => '64G') })->kind,
        'notfound', 'an unknown VM: not found');
    is(err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd0', size => '64g') })->kind,
        'usage', 'a bad size: usage');
    is(err_of(sub { $f->{wl}->()->plan('grow-disk', 't1', vm => 't1-cnh', disk => 'd0') })->kind,
        'usage', 'no size: usage');
    is(err_of(sub { $f->{wl}->()->plan('start', 't1', disk => 'd0', size => '64G') })->kind,
        'usage', '--disk/--size on another op: usage');
    is(scalar($f->{ce}->calls), 0, 'refusals called nothing');
}
{
    my $f = StorageFixture::setup_workload(no_def => 1, ce => { rc => { 'storage-zvol-grow' => 3 } });
    StorageFixture::write_def($f, cnh_def());
    $f->{wl}->()->run('create', 't1');
    $f->{ce}{calls} = [];
    my $e = err_of(sub { $f->{wl}->()->run('grow-disk', 't1', vm => 't1-cnh', disk => 'd0', size => '8G') });
    is($e->kind, 'refused', 'the node refusing the grow (a shrink) stops the run');
    is_deeply([ $f->{ce}->scripts ], ['storage-zvol-grow'], 'vm-disk-resize is not called after a refused grow');
}

#--- hps-workload grow-disk usage
{
    my $f = wl_fixture();
    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_);
        my $out = qx(@cmd 2>&1);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $cli->('grow-disk', 't1', 't1-cnh', 'd0');
    is($rc, 2, 'grow-disk without a size: usage');
    ($rc, $out) = $cli->('grow-disk', 't1', 't1-cnh', 'd0', '64G', 'x');
    is($rc, 2, 'an extra argument: usage');
    ($rc, $out) = $cli->('grow-disk', 't1', '--vm', 't1-cnh', 'd0', '64G');
    is($rc, 2, '--vm with grow-disk: usage');
    like($out, qr/hps-workload grow-disk <name> <vm> <disk> <new size>/, 'the usage names it');
    ($rc, $out) = $cli->('grow-disk', 't1', 't1-cnh', 'd0', '64G', '--dry-run');
    is($rc, 4, 'a workload never created: not found (4)');
}

done_testing;
