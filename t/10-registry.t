#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::HiRes qw(time sleep);
use lib 'lib/perl';
use HPS::Registry;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(
    config_base     => $base,
    system_registry => "$base/system.db",
    lock_timeout    => 1,
);
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");

# system
ok($reg->system_set('ACTIVE_CLUSTER', 'lab'), 'system set');
is($reg->system_get('ACTIVE_CLUSTER'), 'lab', 'system raw scalar');
is($reg->active_cluster, 'lab', 'active_cluster');
ok($reg->system_exists('ACTIVE_CLUSTER'), 'system exists');
ok(!$reg->system_exists('NOPE'), 'system not exists');
is_deeply([ $reg->system_list ], ['ACTIVE_CLUSTER'], 'system list');
ok($reg->system_unset('ACTIVE_CLUSTER'), 'system unset');
ok(!$reg->system_exists('ACTIVE_CLUSTER'), 'gone after unset');
ok($reg->system_unset('ACTIVE_CLUSTER'), 'unset of a missing key is fine');
$reg->system_set('ACTIVE_CLUSTER', 'lab');

# value shapes, as the Bash wrappers treat them
$reg->system_set('S', 'hello world');
is($reg->system_get('S'), 'hello world', 'string raw');
like(do { local $/; open my $f, '<', "$base/system.db/S.json"; <$f> }, qr/^"hello world"\s*$/, 'non-JSON stored as JSON string');
$reg->system_set('N', '42');
is($reg->system_get('N'), '42', 'number raw');
like(do { local $/; open my $f, '<', "$base/system.db/N.json"; <$f> }, qr/^42\s*$/, 'number stored as number');
$reg->system_set('O', '{"a":1,"b":[1,2]}');
is_deeply($reg->system_get_json('O'), { a => 1, b => [ 1, 2 ] }, 'object round-trip');
$reg->system_set('R', { x => 'y' });
is_deeply($reg->system_get_json('R'), { x => 'y' }, 'hashref stored');
is($reg->system_get('MISSING'), undef, 'get missing is undef');

# key validation
for my $bad ('a/b', '../x', 'a b', '', 'a.b') {
    ok(!eval { $reg->system_set($bad, 'x'); 1 }, "bad key '$bad' refused");
    like($@, qr/Invalid key/, 'names the key');
}

# cluster
is($reg->cluster_set('lab', 'dns_domain', 'lab.example'), 1, 'cluster set');
is($reg->cluster_get('lab', 'dns_domain'), 'lab.example', 'cluster get');
ok($reg->cluster_exists('lab'), 'cluster exists');
ok($reg->cluster_exists('lab', 'dns_domain'), 'cluster key exists');
ok(!$reg->cluster_exists('other'), 'cluster missing');
is_deeply([ $reg->cluster_list('lab') ], ['dns_domain'], 'cluster list');
is_deeply([ $reg->cluster_list_all ], ['lab'], 'cluster list_all');
ok(!eval { $reg->cluster_set('other', 'k', 'v'); 1 }, 'set on unknown cluster refused');
like($@, qr/Cluster not found: other/, 'names cluster');
ok(!eval { $reg->cluster_get('bad/name', 'k'); 1 }, 'bad cluster name refused');
$reg->cluster_unset('lab', 'dns_domain');
ok(!$reg->cluster_exists('lab', 'dns_domain'), 'cluster unset');

# host
my $mac = 'AA:BB:CC:00:11:22';
ok(!$reg->host_exists($mac), 'host absent');
$reg->host_set($mac, 'STATE', 'HELD');
ok(-d "$base/clusters/lab/hosts/aabbcc001122.db", 'host dir uses normalised MAC');
ok($reg->host_exists('aa-bb-cc-00-11-22'), 'MAC forms agree');
is($reg->host_get('aabb.cc00.1122', 'STATE'), 'HELD', 'host get via another MAC form');
like($reg->host_get($mac, 'UPDATED'), qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC$/, 'UPDATED stamped like make_timestamp');
$reg->host_unset($mac, 'UPDATED');
$reg->host_set($mac, 'k2', 'v2');
ok($reg->host_exists($mac, 'UPDATED'), 'UPDATED rewritten by every host set');
is_deeply([ $reg->host_list($mac) ], [ 'STATE', 'UPDATED', 'k2' ], 'host list');
$reg->host_set('11:22:33:44:55:66', 'STATE', 'x');
is_deeply([ $reg->host_list_all ], [ sort 'aabbcc001122', '112233445566' ], 'host list_all');
ok(!eval { $reg->host_get('nonsense', 'STATE'); 1 }, 'invalid MAC refused');
like($@, qr/Invalid MAC/, 'names MAC');
$reg->host_unset($mac, 'k2');
ok(!$reg->host_exists($mac, 'k2'), 'host unset');

# os
my $os = 'x86_64:nixos:26.05';
ok(!$reg->os_exists($os), 'os absent');
$reg->os_set($os, 'kernel', 'bzImage');
ok($reg->os_exists($os), 'os exists');
ok($reg->os_exists($os, 'kernel'), 'os key exists');
is($reg->os_get($os, 'kernel'), 'bzImage', 'os get');
is(do { open my $f, '<', "$base/os.db/x86_64_nixos_26.05.os/.os_id"; local $/; <$f> }, "$os\n", '.os_id holds the id');
$reg->os_set('aarch64:alpine-3:3.20', 'k', 'v');
is_deeply([ $reg->os_list ], [ sort 'aarch64:alpine-3:3.20', $os ], 'os list');
make_path("$base/os.db/aarch64_rocky_9.4.os");
ok((grep { $_ eq 'aarch64:rocky:9.4' } $reg->os_list), 'legacy dir without .os_id reconstructed');
ok(!eval { $reg->os_exists('nonsense'); 1 }, 'malformed os id refused');

# no stray temp files
my @tmp = glob("$base/system.db/*.tmp");
is(scalar @tmp, 0, 'no temp files left');

# locks
my $lockdir = "$base/system.db/.lock";
my $lock    = "$lockdir/LK.lock";
$reg->system_set('LK', 'v1');
ok(!-e $lock, 'lock released after set');

# live pid holder blocks and times out
open(my $lf, '>', $lock) or die;
printf {$lf} "ts:%d\npid:%d\nop:write\nhost:test\n", time, $$;
close $lf;
my $t0 = time;
ok(!eval { $reg->system_set('LK', 'v2'); 1 }, 'set refused while a live pid holds the lock');
my $took = time - $t0;
like($@, qr/Cannot acquire lock for LK/, 'timeout message');
cmp_ok($took, '>=', 0.9, 'waited for the timeout');
is($reg->system_get('LK'), 'v1', 'value unchanged');
ok(-e $lock, 'live holder lock left alone');

# it waits, then succeeds when the holder releases
my $pid = fork();
die unless defined $pid;
if (!$pid) { sleep 0.4; unlink $lock; exit 0 }
$t0 = time;
ok($reg->system_set('LK', 'v3'), 'set succeeds once the lock is released');
cmp_ok(time - $t0, '>=', 0.3, 'it did wait');
waitpid $pid, 0;
is($reg->system_get('LK'), 'v3', 'new value written');

# dead pid is cleaned
my $dead = fork();
die unless defined $dead;
exit 0 if !$dead;
waitpid $dead, 0;
open($lf, '>', $lock) or die;
printf {$lf} "ts:1\npid:%d\nop:write\nhost:test\n", $dead;
close $lf;
$t0 = time;
ok($reg->system_set('LK', 'v4'), 'set succeeds over a stale lock');
cmp_ok(time - $t0, '<', 0.5, 'stale lock removed without waiting');
is($reg->system_get('LK'), 'v4', 'value written');
ok(!-e $lock, 'lock released');

# lock file format (what Bash acquire_lock writes)
my $seen;
{
    no warnings 'redefine';
    my $orig = \&HPS::Registry::_release;
    local *HPS::Registry::_release = sub { open my $f, '<', $_[0]; local $/; $seen = <$f>; $orig->(@_) };
    $reg->system_set('LK', 'v5');
}
like($seen, qr/\Ats:\d+\npid:$$\nop:write\nhost:\S+\n\z/, 'lock file carries ts/pid/op/host');

done_testing;
