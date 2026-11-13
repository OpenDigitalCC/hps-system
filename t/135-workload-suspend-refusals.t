#!/usr/bin/env perl
# Suspend and resume refusals: start and stop of a suspended VM, resume of a
# VM that is not suspended, suspend twice, a host with no pool, an unfinished create.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }
sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }

my $f = StorageFixture::setup_workload(ce => { out => { 'vm-save' => "VM-SAVE x y 1024\n" } });
my $wl = $f->{wl}->();

my $e = err_of(sub { $wl->plan('suspend', 't0') });
is($e && $e->kind, 'notfound', 'suspend before create: not found');
$wl->run('create', 't0');
$wl->run('start', 't0');

$e = err_of(sub { $wl->plan('resume', 't0') });
is($e && $e->kind, 'refused', 'resume of a running workload: refused');
like($e->message, qr/VM t0-db is not suspended \(state running\)/, 'says which VM and state');

$wl->run('suspend', 't0', vm => 't0-db');
for my $op (qw(start stop suspend)) {
    $e = err_of(sub { $wl->plan($op, 't0', vm => 't0-db') });
    is($e && $e->kind, 'refused', "$op of a suspended VM: refused");
    like($e->message, qr/VM t0-db is suspended .*\/lab\/enc\/state\/t0-db\.save.*resume/, "$op: names the file and points to resume");
}
$e = err_of(sub { $wl->plan('start', 't0') });
is($e && $e->kind, 'refused', 'start of the whole workload with one VM suspended: refused');
$e = err_of(sub { $wl->plan('stop', 't0', dry_run => 1) });
ok($e, 'stop --dry-run refuses too');
ok(!err_of(sub { $wl->plan('stop', 't0', vm => 't0-app') }), 'the VM that is not suspended can still be stopped');
$e = err_of(sub { $wl->plan('resume', 't0', vm => 't0-app') });
is($e && $e->kind, 'refused', 'resume of the VM that is running: refused');
ok(!err_of(sub { $wl->plan('resume', 't0', vm => 't0-db') }), 'resume of the suspended one plans');
$e = err_of(sub { $wl->plan('suspend', 't0', vm => 'ghost') });
is($e && $e->kind, 'notfound', 'unknown --vm: not found');

#--- a compute host with no pool: every leg remote, no storage_pool identity
{
    my $g = StorageFixture::setup_workload();
    my $def = StorageFixture::base_def();
    $def->{vms} = [ $def->{vms}[0] ];
    $def->{vms}[0]{compute_host} = 'sch-001';
    $def->{vms}[0]{disks}[0]{legs} = [
        { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-a', portal => '192.0.2.50' },
        { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-b', portal => '192.0.2.50' } ];
    StorageFixture::write_def($g, $def);
    my $w = $g->{wl}->();
    my $ok = eval { $w->run('create', 't0'); 1 }; diag($@->message) unless $ok;
    SKIP: {
        skip 'a thin-host definition is not accepted by this fixture', 3 unless $ok;
        $w->run('start', 't0');
        my $x = err_of(sub { $w->plan('suspend', 't0') });
        is($x && $x->kind, 'refused', 'a host with no pool: refused');
        like($x->message, qr/no storage pool of its own.*storage_pool/, 'with a fixable message');
        $g->{reg}->host_set($StorageFixture::MAC, 'storage_pool', 'lab');
        ok(!err_of(sub { $w->plan('suspend', 't0') }), 'with a storage_pool identity it plans');
    }
}

#--- an unfinished create
{
    my $g = StorageFixture::setup_workload(ce => { rc => { 'vm-define' => 1 } });
    my $w = $g->{wl}->();
    ok(err_of(sub { $w->run('create', 't0') }), 'create stops');
    my $x = err_of(sub { $w->plan('suspend', 't0') });
    is($x && $x->kind, 'refused', 'suspend of a creating workload: refused');
    like($x->message, qr/not fully created/, 'finish the create first');
}

done_testing;
