#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Keysafe;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $ks  = HPS::Keysafe->new(registry => $reg);
my $dir = "$base/clusters/lab/keysafe";

sub mode { return sprintf '%04o', (lstat $_[0])[2] & 07777 }
sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }

is($ks->dir, $dir, 'dir is under the active cluster');
ok(!-e $dir, 'constructing creates nothing');

my $k = $ks->get_or_create_key('52:54:00:AA:BB:01', 'zfs-enc');
is(length $k, 32, 'key is 32 bytes');
is(mode($dir), '0700', 'keysafe dir is 0700');
is(mode("$dir/525400aabb01"), '0700', 'host dir is 0700');
is(mode("$dir/525400aabb01/zfs-enc.key"), '0600', 'key file is 0600');
is($ks->get_or_create_key('525400aabb01', 'zfs-enc'), $k, 'second call returns the same key');
is($ks->get_or_create_key('52-54-00-aa-bb-01', 'zfs-enc'), $k, 'MAC spelling does not matter');
isnt($ks->get_or_create_key('525400aabb02', 'zfs-enc'), $k, 'another host gets another key');

opendir(my $dh, "$dir/525400aabb01"); my @left = grep { /^\./ && !/^\.\.?$/ } readdir $dh; closedir $dh;
is(scalar @left, 0, 'no temporary file is left behind');

ok($ks->has_key('525400aabb01', 'zfs-enc'), 'has_key');
ok(!$ks->has_key('525400aabb01', 'nope'), 'has_key false');
ok(!$ks->has_key('525400aabb09', 'zfs-enc'), 'has_key false for an unknown host');
$ks->get_or_create_key('525400aabb01', 'alpha');
is_deeply([ $ks->list('525400aabb01') ], [ 'alpha', 'zfs-enc' ], 'list is sorted, without suffix');
is_deeply([ $ks->list('525400aabb77') ], [], 'list of an unknown host is empty');

my $s = $ks->cluster_secret('approval');
is(length $s, 32, 'cluster secret is 32 bytes');
is(mode("$dir/approval.hmac"), '0600', 'approval.hmac is 0600');
is($ks->cluster_secret('approval'), $s, 'secret is stable');
isnt($ks->cluster_secret('other'), $s, 'purposes differ');
ok(!(grep { $_ eq 'approval' } $ks->list('525400aabb01')), 'cluster secrets are not host keys');

# delete
ok($ks->delete_key('525400aabb01', 'alpha'), 'delete_key removes');
ok(!$ks->delete_key('525400aabb01', 'alpha'), 'delete_key of a missing key is 0');
ok(!$ks->has_key('525400aabb01', 'alpha'), 'gone');

# usage errors
for my $bad ('../x', 'a/b', '', '.hid', 'a..b') {
    my $e = err_of(sub { $ks->get_or_create_key('525400aabb01', $bad) });
    is(ref $e && $e->kind, 'usage', "name '$bad' refused");
}
my $e = err_of(sub { $ks->get_or_create_key('nonsense', 'x') });
is($e->kind, 'usage', 'bad MAC is a usage error');

# refusal on bad permissions, no silent chmod
chmod 0750, "$dir/525400aabb01";
$e = err_of(sub { $ks->get_or_create_key('525400aabb01', 'zfs-enc') });
is($e && $e->kind, 'perms', 'group-accessible host dir is refused');
is(mode("$dir/525400aabb01"), '0750', 'the refusal did not chmod');
chmod 0700, "$dir/525400aabb01";

chmod 0640, "$dir/525400aabb01/zfs-enc.key";
$e = err_of(sub { $ks->get_or_create_key('525400aabb01', 'zfs-enc') });
is($e && $e->kind, 'perms', 'group-readable key file is refused');
like($e->message, qr/0640/, 'message names the mode');
unlike($e->message, qr/\Q$k\E/, 'message carries no key bytes');
is(mode("$dir/525400aabb01/zfs-enc.key"), '0640', 'still not chmod\'ed');

chmod 0707, $dir;
$e = err_of(sub { $ks->cluster_secret('approval') });
is($e && $e->kind, 'perms', 'world-accessible keysafe dir is refused');
$e = err_of(sub { $ks->list('525400aabb01') });
is($e && $e->kind, 'perms', 'list refuses too');

# repair
my @fixed = $ks->repair_permissions;
ok(scalar(@fixed) >= 2, 'repair reports what it changed');
is(mode($dir), '0700', 'repair: dir');
is(mode("$dir/525400aabb01/zfs-enc.key"), '0600', 'repair: key file');
is($ks->get_or_create_key('525400aabb01', 'zfs-enc'), $k, 'key intact after repair');
is_deeply([ $ks->repair_permissions ], [], 'second repair changes nothing');

# a symlinked key is refused; a corrupt (wrong-size) key is refused without leaking it
unlink "$dir/525400aabb01/link.key";
symlink "$dir/525400aabb01/zfs-enc.key", "$dir/525400aabb01/link.key";
$e = err_of(sub { $ks->get_or_create_key('525400aabb01', 'link') });
is($e && $e->kind, 'perms', 'symlinked key refused');
open(my $fh, '>', "$dir/525400aabb01/short.key"); print {$fh} 'SECRETSECRET'; close $fh; chmod 0600, "$dir/525400aabb01/short.key";
$e = err_of(sub { $ks->get_or_create_key('525400aabb01', 'short') });
is($e && $e->kind, 'perms', 'wrong-size key refused');
unlike($e->message, qr/SECRETSECRET/, 'corrupt key content is not echoed');

# symlinked keysafe dir refused
my $b2 = tempdir(CLEANUP => 1);
my $r2 = HPS::Registry->new(config_base => $b2, system_registry => "$b2/system.db");
make_path("$b2/clusters/lab/cluster.db", "$b2/real");
chmod 0700, "$b2/real";
symlink "$b2/real", "$b2/clusters/lab/keysafe";
$r2->system_set('ACTIVE_CLUSTER', 'lab');
$e = err_of(sub { HPS::Keysafe->new(registry => $r2)->cluster_secret('approval') });
is($e && $e->kind, 'perms', 'symlinked keysafe dir refused');

# no cluster directory
my $r3 = HPS::Registry->new(config_base => tempdir(CLEANUP => 1), system_registry => "$b2/s3.db");
$r3->system_set('ACTIVE_CLUSTER', 'ghost');
$e = err_of(sub { HPS::Keysafe->new(registry => $r3)->cluster_secret('approval') });
is($e && $e->kind, 'notfound', 'missing cluster dir is not created');

done_testing;
