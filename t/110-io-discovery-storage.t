#!/usr/bin/env perl
# I/O discovery in HPS::Storage: create with measure (storage-pool-create
# --measure, then the zvol test after up), the measure verb, the registry keys,
# soft failure of the measurement, status/measure results, destroy clearing the
# figures. The node scripts are tested in scripts/tests/test_p3_25[4-6]*.bats.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Registry::Keys;

my $mac = $StorageFixture::MAC;
my @D2  = (disks => [ 'ata-SSD1', 'ata-SSD2' ]);

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

my $create_out = "IODISK ata-SSD1 520 480 0.41 1.90\nIODISK ata-SSD2 510 450 0.55 2.30\n";
my $pool_out   = "IOPOLICY lab sync=standard logbias=latency\nIOPOOL lab 330 0.80 3.10\n";

sub fresh {
    my (%o) = @_;
    my $f = StorageFixture::setup(ce => { out => { 'storage-pool-create' => $create_out, 'storage-io-measure' => $pool_out }, %{ $o{ce} // {} } });
    $f->{st} = $f->{mk}->();
    return $f;
}
sub keys_of { my ($f) = @_; return { map { $_ => $f->{reg}->host_get($mac, $_) } grep { $f->{reg}->host_exists($mac, $_) } @HPS::Storage::IO_KEYS } }

# --- create: library default measures nothing; measure => 1 adds the flag and the zvol test
{
    my $f = fresh();
    $f->{st}->run('create', pool => 'lab', @D2);
    is_deeply([ map { $_->{script} } $f->{ce}->calls ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock' ], 'no measure option: no measurement calls');
    ok(!$f->{reg}->host_exists($mac, 'storage_pool_write_mbps'), 'nothing recorded');
}
{
    my $f = fresh();
    $f->{st}->run('create', pool => 'lab', @D2, measure => 1);
    my @c = $f->{ce}->calls;
    is_deeply([ map { $_->{script} } @c ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock', 'storage-io-measure' ],
        'measure: the zvol test follows the unlock (the pool is up and enc is unlocked)');
    is_deeply($c[0]{args}, [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2', '--measure' ], 'storage-pool-create gets --measure');
    is_deeply($c[3]{args}, ['lab'], 'storage-io-measure <pool>');
    ok(!defined $c[3]{input}, 'the zvol test takes no input (no key)');
    my $k = keys_of($f);
    is($k->{storage_read_mbps}, 510, 'read: the lowest of the disks');
    is($k->{storage_write_mbps}, 450, 'raw write: the lowest of the disks');
    is($k->{storage_fsync_ms}, '0.55', 'fsync p50: the highest of the disks');
    is($k->{storage_fsync_max_ms}, '2.30', 'fsync max: the highest of the disks');
    is($k->{storage_pool_write_mbps}, 330, 'pool write from the zvol test');
    is($k->{storage_measured_at}, '2027-01-15T08:00:00Z', 'measured_at is ISO UTC from the clock');
    is(scalar(keys %$k), 6, 'six figures, nothing else');
    for my $key (@HPS::Storage::IO_KEYS) {
        ok(HPS::Registry::Keys::lookup('host', $key), "$key is in the key catalogue");
    }
    is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'create still ends up');
}

# --- the dry-run plan shows the measurement
{
    my $f = fresh();
    my $p = $f->{st}->plan('create', pool => 'lab', @D2, measure => 1);
    is_deeply([ map { $_->{script} } @$p ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock', 'storage-io-measure' ], 'plan: four calls');
    is($f->{ce}->calls + 0, 0, 'plan sends nothing');
    $p = $f->{st}->plan('measure');
    is_deeply([ map { join ' ', $_->{script}, @{ $_->{args} } } @$p ], ['storage-io-measure lab'], 'plan of measure');
}

# --- a failed measurement is not a failed create
{
    my $f = fresh(ce => { rc => { 'storage-io-measure' => 3 }, err => { 'storage-io-measure' => "refused: busy\n" } });
    my $r = eval { $f->{st}->run('create', pool => 'lab', @D2, measure => 1) };
    ok($r && $r->{ok}, 'create ok although the zvol test exited 3');
    is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'state up');
    ok(!$f->{reg}->host_exists($mac, 'storage_pool_write_mbps'), 'no pool figure');
    is($f->{reg}->host_get($mac, 'storage_read_mbps'), 510, 'the disk figures from create are kept');
    ok((grep { /not fatal/ } @{ $f->{log} }), 'the warning is logged');
    my $last = $f->{reg}->host_get_json($mac, 'storage_last');
    ok($last->{ok}, 'storage_last says ok');
}

# --- lines that do not parse are ignored (a runner that appends stderr, junk numbers)
{
    my $f = fresh(ce => { out => { 'storage-io-measure' => "+ dd if=x\nIOPOOL lab fast 0.1 0.2\nIOREAD d1 -4\nIOPOOL lab 77 0.10 0.90\nIOPOOL lab 99\n" } });
    $f->{st}->run('measure');
    is_deeply(keys_of($f), { storage_pool_write_mbps => 77, storage_fsync_ms => '0.10', storage_fsync_max_ms => '0.90',
        storage_measured_at => '2027-01-15T08:00:00Z' }, 'only the well-formed IOPOOL line counts');
}

# --- measure on a host whose pool exists
{
    my $f = fresh(ce => { out => { 'storage-io-measure' => "IOREAD d1 600\nIOREAD d2 580\n$pool_out" } });
    $f->{reg}->host_set($mac, 'storage_pool', 'lab');
    $f->{reg}->host_set($mac, 'STATE', 'CONFIGURED');
    my $r = $f->{st}->run('measure');
    is_deeply([ map { $_->{script} } $f->{ce}->calls ], ['storage-io-measure'], 'one call');
    my $k = keys_of($f);
    is($k->{storage_read_mbps}, 580, 'read: lowest disk');
    is($k->{storage_pool_write_mbps}, 330, 'pool write');
    is($k->{storage_fsync_ms}, '0.80', 'no raw figure held: the zvol fsync fills the keys');
    ok(!exists $k->{storage_write_mbps}, 'no raw write figure invented');
    is_deeply($r->{io}, $k, 'the result carries the figures');
}
{
    my $f = fresh();
    $f->{reg}->host_set($mac, $_->[0], $_->[1]) for [ storage_fsync_ms => '0.30' ], [ storage_fsync_max_ms => '1.00' ], [ storage_write_mbps => 480 ];
    $f->{st}->run('measure');
    my $k = keys_of($f);
    is($k->{storage_fsync_ms}, '0.30', 'a raw fsync figure from create is not overwritten by the zvol test');
    is($k->{storage_write_mbps}, 480, 'nor the raw write figure');
    is($k->{storage_pool_write_mbps}, 330, 'the pool figure is updated');
}

# --- refusals
{
    my $f = fresh();
    $f->{reg}->host_set($mac, 'STATE', 'HELD');
    is(err_of(sub { $f->{st}->run('measure') })->kind, 'refused', 'measure on an unassigned host is refused');
    is($f->{ce}->calls + 0, 0, 'nothing sent');
    $f = fresh(ce => { rc => { 'storage-io-measure' => 3 }, err => { 'storage-io-measure' => "[storage-io-measure] refused: lab/enc/hps-measure already exists\n" } });
    my $e = err_of(sub { $f->{st}->run('measure') });
    is($e->kind, 'refused', 'the measure verb: a node refusal is a refusal');
    like($e->message, qr/already exists/, 'with the node\'s words');
}

# --- status carries the figures; destroy clears them
{
    my $f = fresh();
    $f->{st}->run('create', pool => 'lab', @D2, measure => 1);
    my $r = $f->{st}->run('status');
    is($r->{io}{storage_pool_write_mbps}, 330, 'status result: io figures');
    $f->{st}->run('destroy');
    is_deeply(keys_of($f), {}, 'destroy clears every figure');
}

done_testing;
