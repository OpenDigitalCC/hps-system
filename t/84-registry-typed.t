#!/usr/bin/env perl
# IPS-07: typed host accessors refuse a value of the wrong type and name the key.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db", lock_timeout => 1);
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $mac = 'aabbccddee01';
$reg->host_set($mac, 'STATE', 'CONFIGURED');

sub err_of { my ($c) = @_; eval { $c->(); 1 } and return ''; return $@ }

# epoch
$reg->host_set($mac, 'ctrl_exec_paired_at', '1794321826');
is($reg->host_get_epoch($mac, 'ctrl_exec_paired_at'), 1794321826, 'epoch read as a number');
is($reg->host_get_epoch($mac, 'last_boot_at'), undef, 'unset key: undef');
$reg->host_set($mac, 'last_boot_at', 'yesterday');
like(err_of(sub { $reg->host_get_epoch($mac, 'last_boot_at') }), qr/Registry key 'last_boot_at' holds 'yesterday', which is not epoch/, 'a non-epoch value is refused, key named');
$reg->host_set($mac, 'last_boot_at', '2026-11-10 10:00:00 UTC');
like(err_of(sub { $reg->host_get_epoch($mac, 'last_boot_at') }), qr/'last_boot_at'/, 'a timestamp string is refused for an epoch');

# bool
for my $t ([ 'true', 1 ], [ 'false', 0 ], [ '1', 1 ], [ '0', 0 ]) {
    $reg->host_set($mac, 'storage_trim_ok', $t->[0]);
    is($reg->host_get_bool($mac, 'storage_trim_ok'), $t->[1], "bool $t->[0]");
}
$reg->host_set($mac, 'storage_trim_ok', 'maybe');
like(err_of(sub { $reg->host_get_bool($mac, 'storage_trim_ok') }), qr/Registry key 'storage_trim_ok' holds 'maybe', which is not bool/, 'a non-bool value is refused, key named');

# the catalogue's declared type refuses an accessor of another type
$reg->host_set($mac, 'ctrl_exec_paired', '1794321826');
like(err_of(sub { $reg->host_get_bool($mac, 'ctrl_exec_paired') }), qr/Registry key 'ctrl_exec_paired' is declared epoch, not bool/,
    'the boolean-looking name that holds an epoch is refused as a bool, even when the digits would pass');
$reg->host_set($mac, 'STATE', '1');
like(err_of(sub { $reg->host_get_epoch($mac, 'STATE') }), qr/'STATE' is declared string, not epoch/, 'a string key is refused as an epoch');

# a key the catalogue does not know is checked on its value only
$reg->host_set($mac, 'scratch_flag', 'true');
is($reg->host_get_bool($mac, 'scratch_flag'), 1, 'uncatalogued key: value check only');

# the typed read does not disturb the plain read
is($reg->host_get($mac, 'ctrl_exec_paired_at'), '1794321826', 'host_get unchanged');
done_testing;
