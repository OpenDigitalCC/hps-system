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

# A runner shim: records its arguments and stdin, exits with $FAKE_RC. Called for
# osvc-ca-export (no --input) it prints a CA line (IPS-12; see 91-hps-osvc-ca.t).
my $shim = "$base/hps-run.sh";
open(my $s, '>', $shim) or die $!;
print $s "#!/bin/sh\nif [ \"\$1\" = --input ]; then\necho \"\$*\" > '$base/args'\ncat > '$base/stdin'\nexit \${FAKE_RC:-0}\nfi\necho \"\$*\" > '$base/export-args'\necho '1700000000 W0RFRkFVTFRdCg=='\n";
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
isnt($hex, unpack('H*', $ks->cluster_secret('example')), 'it is not the secret of another purpose');

($rc, $out) = hps_osvc('deliver', 'node01');
is(slurp("$base/stdin"), "$hex\n1700000000 W0RFRkFVTFRdCg==\n", 'a second delivery sends the same secret and the captured CA');

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

# status: the read-only node script, output and exit passed through (scale test,
# 2026-11-12: om3 membership had no operator view).
{
    my $st = "$base/status-run.sh";
    open(my $fh, '>', $st) or die $!;
    print $fh "#!/bin/sh\necho \"\$*\" > '$base/status-args'\necho 'OSVC tch-001 peers=5 beating=5 stale=- frozen=no'\nexit \${FAKE_RC:-0}\n";
    close $fh;
    chmod 0755, $st;
    local $ENV{HPS_OSVC_RUN} = $st;
    ($rc, $out) = hps_osvc('status', 'tch-001');
    is($rc, 0, 'status: exit 0 when healthy');
    is(slurp("$base/status-args"), "tch-001 osvc-status\n", 'status: the runner gets the host and osvc-status, no --input');
    like($out, qr/^OSVC tch-001 peers=5 beating=5/m, 'status: the summary line is printed');
    local $ENV{FAKE_RC} = 2;
    ($rc, $out) = hps_osvc('status', 'tch-001');
    is($rc, 2, 'status: a stale peer (2) is passed through');
    ($rc, $out) = hps_osvc('status');
    is($rc, 2, 'status: host required');
    ($rc, $out) = hps_osvc('status', 'tch-001', '--dry-run');
    is($rc, 2, 'status: --dry-run is refused (deliver only)');
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
is(length($ks->cluster_secret('example')), 32, 'keysafe: the default length stays 32');

done_testing;
