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
$ENV{HPS_CONFIG_BASE}     = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

# A runner shim: records its arguments and stdin, exits with $FAKE_RC.
my $shim = "$base/hps-run.sh";
open(my $s, '>', $shim) or die $!;
print $s "#!/bin/sh\necho \"\$*\" > '$base/args'\ncat > '$base/stdin'\nexit \${FAKE_RC:-0}\n";
close $s;
chmod 0755, $shim;
$ENV{HPS_OSVC_RUN} = $shim;

sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub hps_osvc { my $out = `perl $Bin/../bin/hps-osvc @_ 2>&1`; return ($? >> 8, $out) }

my ($rc, $out) = hps_osvc('deliver', 'node01');
is($rc, 0, 'deliver succeeds');
is(slurp("$base/args"), "--input node01 osvc-secret-set\n", 'the runner gets --input, the host and the node script');
my $ks  = HPS::Keysafe->new(registry => $reg);
my $hex = unpack('H*', $ks->cluster_secret('opensvc-cluster', 16));
is(slurp("$base/stdin"), "$hex\n", 'stdin is the keysafe opensvc-cluster secret as hex');
like($hex, qr/^[0-9a-f]{32}$/, 'the secret is 16 random bytes: 32 characters, a valid AES key size for om3');
unlike($out, qr/\Q$hex\E/, 'the secret is not printed');
isnt($hex, unpack('H*', $ks->cluster_secret('approval')), 'it is not the approval secret');

($rc, $out) = hps_osvc('deliver', 'node01');
is(slurp("$base/stdin"), "$hex\n", 'a second delivery sends the same secret');

unlink "$base/args", "$base/stdin";
($rc, $out) = hps_osvc('deliver', 'node01', '--dry-run');
is($rc, 0, 'dry run exits 0');
ok(!-e "$base/args", 'dry run runs nothing');
unlike($out, qr/\Q$hex\E/, 'dry run does not print the secret');

{
    local $ENV{FAKE_RC} = 4;
    ($rc, $out) = hps_osvc('deliver', 'nosuch');
    is($rc, 4, 'the runner exit status is passed through');
}

($rc, $out) = hps_osvc('deliver');
is($rc, 2, 'host required');
($rc, $out) = hps_osvc('frobnicate', 'node01');
is($rc, 2, 'unknown operation');
($rc, $out) = hps_osvc('deliver', '"a;b"');
is($rc, 2, 'a host with shell characters is refused');

is(length($ks->cluster_secret('lenprobe', 16)), 16, 'keysafe: a 16-byte secret is created at 16 bytes');
is($ks->cluster_secret('lenprobe', 16), $ks->cluster_secret('lenprobe', 16), 'keysafe: and read back the same');
ok(!eval { $ks->cluster_secret('lenprobe', 32); 1 }, 'keysafe: a file of another length is refused, not truncated');
is(length($ks->cluster_secret('approval')), 32, 'keysafe: the default length stays 32');

done_testing;
