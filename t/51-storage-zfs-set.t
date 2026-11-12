#!/usr/bin/env perl
# Zvol write properties: HPS::Storage zfs-set (sync and logbias on <pool>/enc or
# a zvol under it, nothing else) and the cluster keys storage_zvol_sync /
# storage_zvol_logbias that zvol-create and create pass to the node, so
# hps-workload create inherits them through the one zvol-create path.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::ClusterConfig;

my $mac = $StorageFixture::MAC;
my $DS  = 'lab/enc/vm/g1-root';

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub fresh { my %o = @_; my $f = StorageFixture::setup(%o); $f->{st} = $f->{mk}->(); return $f }
sub args0 { my ($f) = @_; return ($f->{ce}->calls)[0]{args} }

ok(scalar(grep { $_ eq 'zfs-set' } HPS::Storage::ops()), 'op zfs-set is known');

# --- zfs-set: one call, the tokens as given, on a zvol or on <pool>/enc
{
    my $f = fresh();
    my $r = $f->{st}->run('zfs-set', dataset => $DS, props => [ 'sync=disabled', 'logbias=throughput' ]);
    ok($r->{ok}, 'zfs-set ok');
    is_deeply([ $f->{ce}->scripts ], ['storage-zfs-set'], 'one storage-zfs-set call');
    is_deeply(args0($f), [ $DS, 'sync=disabled', 'logbias=throughput' ], 'dataset then prop=value tokens');
    is(($f->{ce}->calls)[0]{input}, undef, 'no input');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{op}, 'zfs-set', 'storage_last records the op');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'no pool state touched');
    $f->{ce}{calls} = [];
    $f->{st}->run('zfs-set', dataset => 'lab/enc', props => ['sync=standard']);
    is_deeply(args0($f), [ 'lab/enc', 'sync=standard' ], '<pool>/enc itself is accepted');
    $f->{ce}{calls} = [];
    $f->{st}->run('zfs-set', dataset => 'lab/enc/vm', props => ['logbias=latency']);
    is_deeply(args0($f), [ 'lab/enc/vm', 'logbias=latency' ], '<pool>/enc/vm is accepted');
    $f->{ce}{calls} = [];
    $f->{st}->run('zfs-set', dataset => 'lab/enc/t0', props => ['sync=always']);
    is_deeply(args0($f), [ 'lab/enc/t0', 'sync=always' ], 'sync=always passes (zfs-set is not limited to the key values)');
}

# --- refusals: dataset, properties, values, pool; nothing called
{
    my $f = fresh();
    for my $bad (undef, '', 'lab', 'lab/t0', 'lab/other/x', 'lab/enc/a/b', 'Lab/enc/t0', 'lab/enc/t0;x', '/lab/enc/t0') {
        my $e = err_of(sub { $f->{st}->run('zfs-set', dataset => $bad, props => ['sync=disabled']) });
        is(ref $e && $e->kind, 'usage', 'bad dataset ' . ($bad // 'undef') . ': usage');
    }
    for my $bad ([], ['sync=off'], ['logbias=fast'], ['compression=off'], ['volsize=2G'], ['sync'], ['=disabled'], ['sync=disabled;x'],
        [ 'sync=disabled', 'sync=standard' ], ['readonly=on'], [undef], [ {} ]) {
        my $e = err_of(sub { $f->{st}->run('zfs-set', dataset => $DS, props => $bad) });
        is(ref $e && $e->kind, 'usage', 'bad props [' . join(',', map { $_ // 'undef' } @$bad) . ']: usage');
    }
    is(err_of(sub { $f->{st}->run('zfs-set', dataset => $DS, props => 'sync=disabled') })->kind, 'usage', 'props not a list: usage');
    is(err_of(sub { $f->{st}->run('zfs-set', dataset => 'other/enc/t0', props => ['sync=disabled']) })->kind, 'refused', 'another pool is refused');
    is(scalar($f->{ce}->calls), 0, 'refusals called nothing');
    my $g = fresh(ce => { rc => { 'storage-zfs-set' => 3 } });
    is(err_of(sub { $g->{st}->run('zfs-set', dataset => $DS, props => ['sync=disabled']) })->kind, 'refused', 'node exit 3 -> refused');
    my $plan = $f->{st}->plan('zfs-set', dataset => $DS, props => ['sync=disabled']);
    is_deeply([ map { $_->{script} } @$plan ], ['storage-zfs-set'], 'plan: one call');
    is($plan->[0]{input}, undef, 'plan: no input');
}

# --- the cluster keys: nothing passed at the defaults, --sync/--logbias otherwise
{
    my $f = fresh();
    $f->{st}->run('zvol-create', dataset => $DS, size => '1G');
    is_deeply(args0($f), [ $DS, '1G' ], 'no keys: zvol-create passes dataset and size only');
    $f->{ce}{calls} = [];
    $f->{reg}->cluster_set('lab', 'storage_zvol_sync', 'standard');
    $f->{reg}->cluster_set('lab', 'storage_zvol_logbias', 'latency');
    $f->{st}->run('zvol-create', dataset => $DS, size => '1G');
    is_deeply(args0($f), [ $DS, '1G' ], 'keys at the ZFS defaults: nothing passed (the zvol inherits <pool>/enc)');
    $f->{ce}{calls} = [];
    $f->{reg}->cluster_set('lab', 'storage_zvol_sync', 'disabled');
    $f->{reg}->cluster_set('lab', 'storage_zvol_logbias', 'throughput');
    $f->{st}->run('zvol-create', dataset => $DS, size => '1G');
    is_deeply(args0($f), [ $DS, '1G', '--logbias', 'throughput', '--sync', 'disabled' ], 'disabled + throughput: both passed');
    $f->{ce}{calls} = [];
    $f->{reg}->cluster_set('lab', 'storage_zvol_logbias', '');
    $f->{st}->run('zvol-create', dataset => $DS, size => '1G');
    is_deeply(args0($f), [ $DS, '1G', '--sync', 'disabled' ], 'an empty key is unset');
    $f->{reg}->cluster_set('lab', 'storage_zvol_sync', 'always');
    my $e = err_of(sub { $f->{st}->run('zvol-create', dataset => $DS, size => '1G') });
    is(ref $e && $e->kind, 'refused', 'a key outside its enum refuses zvol-create (never silently ignored)');
    like($e->message, qr/storage_zvol_sync is 'always'; it must be one of standard, disabled/, 'and says which');

    # create: the pool's enc dataset takes the same policy
    $f->{reg}->cluster_set('lab', 'storage_zvol_sync', 'disabled');
    $f->{reg}->cluster_set('lab', 'storage_zvol_logbias', 'throughput');
    my $plan = $f->{st}->plan('create', disks => [ 'ata-A', 'ata-B' ]);
    is_deeply($plan->[0]{args}, [ 'lab', '--disk', 'ata-A', '--disk', 'ata-B', '--logbias', 'throughput', '--sync', 'disabled' ],
        'create passes the policy to storage-pool-create (after the disks)');
    like($plan->[0]{input}, qr/redacted/, 'the key stays the only input');
    $f->{reg}->cluster_unset('lab', 'storage_zvol_sync');
    $f->{reg}->cluster_unset('lab', 'storage_zvol_logbias');
    $plan = $f->{st}->plan('create', disks => [ 'ata-A', 'ata-B' ]);
    is_deeply($plan->[0]{args}, [ 'lab', '--disk', 'ata-A', '--disk', 'ata-B' ], 'unset keys: create unchanged');
}

# --- hps-workload create: the zvol step goes through zvol-create, so the policy
# arrives with no second path
{
    my $f = StorageFixture::setup_workload();
    $f->{reg}->cluster_set('lab', 'storage_zvol_sync', 'disabled');
    $f->{reg}->cluster_set('lab', 'storage_zvol_logbias', 'throughput');
    my $wl = $f->{wl}->();
    my $plan = $wl->plan('create', 't0');
    my @zv = grep { $_->{script} eq 'storage-zvol-create' } @$plan;
    ok(scalar @zv, 'workload create plans storage-zvol-create steps');
    for my $s (@zv) {
        is_deeply([ @{ $s->{args} }[ 2 .. 5 ] ], [ '--logbias', 'throughput', '--sync', 'disabled' ], "$s->{args}[0]: the cluster's policy shown in the plan");
    }
    $wl->run('create', 't0');
    my @calls = grep { $_->{script} eq 'storage-zvol-create' } $f->{ce}->calls;
    ok(scalar @calls, 'the create ran storage-zvol-create');
    for my $c (@calls) {
        is_deeply([ @{ $c->{args} }[ 2 .. 5 ] ], [ '--logbias', 'throughput', '--sync', 'disabled' ], "$c->{args}[0]: the policy on the call");
    }
    ok(!grep({ $_->{script} eq 'storage-zfs-set' } $f->{ce}->calls), 'no storage-zfs-set call: one path only');
}

# --- the catalogue
{
    my %q = map { $_->{key} => $_ } HPS::ClusterConfig::questions();
    is($q{storage_zvol_sync}{default}, 'standard', 'storage_zvol_sync defaults to standard');
    is($q{storage_zvol_sync}{rule}, 'enum:standard,disabled', 'storage_zvol_sync: standard or disabled');
    is($q{storage_zvol_logbias}{default}, 'latency', 'storage_zvol_logbias defaults to latency');
    is($q{storage_zvol_logbias}{rule}, 'enum:latency,throughput', 'storage_zvol_logbias: latency or throughput');
    ok(!HPS::ClusterConfig::validate_value($q{storage_zvol_sync}, 'disabled'), 'disabled validates');
    like(HPS::ClusterConfig::validate_value($q{storage_zvol_sync}, 'always'), qr/must be one of/, 'always is not a cluster policy');
}

done_testing;
