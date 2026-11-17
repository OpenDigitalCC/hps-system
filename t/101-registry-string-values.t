#!/usr/bin/env perl
# A registry value is stored and returned as the string that was given: a
# number-looking value (5254000870e4, 8187e907, 007) is never turned into a float.
# Also the read-only check (hps-registry-keys --check) that lists values already mangled.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Registry::Check;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db", lock_timeout => 1);
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $mac = 'aabbccddee01';

sub raw { my ($f) = @_; open(my $fh, '<', $f) or die "$f: $!"; local $/; my $t = <$fh>; $t =~ s/\s+\z//; return $t }
my $hdir = "$base/clusters/lab/hosts/$mac.db";

for my $v ('5254000870e4', '8187e907', '007', '1e5', '12', 'true', 'null', '1.50', '123456789012345678901234', 'plain text') {
    $reg->host_set($mac, 'probe', $v);
    is($reg->host_get($mac, 'probe'), $v, "host_get returns '$v' as given");
    is(raw("$hdir/probe.json"), "\"$v\"", "'$v' is stored as a JSON string");
}

# structures stay JSON
$reg->host_set($mac, 'nets', '["a","b"]');
is_deeply($reg->host_get_json($mac, 'nets'), [qw(a b)], 'an array given as text stays an array');
$reg->host_set($mac, 'bmc_options', { outlet => 'pdu1:7' });
is_deeply($reg->host_get_json($mac, 'bmc_options'), { outlet => 'pdu1:7' }, 'a reference stays an object');

# typed readers still work on stored strings
$reg->host_set($mac, 'ctrl_exec_paired_at', '1794321826');
is($reg->host_get_epoch($mac, 'ctrl_exec_paired_at'), 1794321826, 'an epoch stored as a string reads as a number');
$reg->host_set($mac, 'storage_trim_ok', 'true');
is($reg->host_get_bool($mac, 'storage_trim_ok'), 1, 'a bool stored as a string reads as a bool');

# the other scopes
$reg->cluster_set('lab', 'probe', '8187e907');
is(raw("$base/clusters/lab/cluster.db/probe.json"), '"8187e907"', 'cluster value stored as a string');
$reg->system_set('PROBE', '5254000870e4');
is(raw("$base/system.db/PROBE.json"), '"5254000870e4"', 'system value stored as a string');

# --- the check
$reg->host_unset($mac, $_) for qw(probe nets bmc_options ctrl_exec_paired_at storage_trim_ok);
$reg->host_set($mac, 'boot_mac_last', '5254000870e4');
$reg->host_set($mac, 'zfs_hostid', '8187e907');
my @none = HPS::Registry::Check::scan($base, "$base/system.db");
is(scalar @none, 0, 'values stored as strings are clean (hex text with an e is not flagged)');

sub plant { my ($f, $body) = @_; open(my $fh, '>', $f) or die; print {$fh} $body; close $fh }
plant("$hdir/boot_mac_last.json", "5.254000870E+13\n");
plant("$hdir/zfs_hostid.json",    "\"8.187E+907\"\n");
plant("$hdir/STATE.json",         "12345678\n");
plant("$hdir/pair_reboots.json",  "2\n");
plant("$hdir/scratch.json",       "1E+5\n");
plant("$hdir/note.json",          "\"2e3\"\n");
my %by = map { $_->{key} => $_ } HPS::Registry::Check::scan($base, "$base/system.db");
is($by{boot_mac_last}{value}, '5.254000870E+13', 'a mangled mac is found with its stored value');
is($by{boot_mac_last}{owner}, $mac, 'host named');
is($by{zfs_hostid}{reason}, 'text in float-exponent form', 'exponent text in a string is found');
ok($by{STATE}, 'a number where the key is text is found');
ok(!$by{pair_reboots}, 'a number where the key is a number is fine');
ok($by{scratch}, 'an uncatalogued number with an exponent is found');
ok(!$by{note}, 'plain lower-case digit-e-digit text (no sign) is not flagged');

my $before = join ',', map { raw("$hdir/$_.json") } sort qw(boot_mac_last zfs_hostid STATE);
my $tool = "$Bin/../bin/hps-registry-keys";
my $out = qx{$^X -I$Bin/../lib/perl $tool --check --config-base $base 2>/dev/null};
my $rc = $? >> 8;
is($rc, 1, 'the check exits 1 when it finds something');
like($out, qr/^host \Q$mac\E boot_mac_last 5\.254000870E\+13 /m, 'prints host, key and stored value');
is(join(',', map { raw("$hdir/$_.json") } sort qw(boot_mac_last zfs_hostid STATE)), $before, 'the check changed nothing');

done_testing;
