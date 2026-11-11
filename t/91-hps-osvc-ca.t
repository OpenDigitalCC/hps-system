#!/usr/bin/env perl
# IPS-12: hps-osvc and the one cluster CA (capture, send, forget; CA bytes never
# in argv, output or errors).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use MIME::Base64 qw(encode_base64);
use HPS::Registry;
use HPS::Keysafe;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$ENV{HPS_CONFIG_BASE}     = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

my $b64  = encode_base64("[DEFAULT]\nca_marker_zzz = crypt:abc\n", '');
my $line = "1700000123 $b64";

# Stub runner: logs every argv line; --input calls keep stdin; the export call
# prints noise, then (unless FAKE_EXPORT_RC is set) the CA line from $base/export.
my $shim = "$base/hps-run.sh";
open(my $s, '>', $shim) or die $!;
print $s <<"SH";
#!/bin/sh
echo "\$*" >> '$base/argv.log'
if [ "\$1" = --input ]; then
  cat > '$base/stdin'
  exit 0
fi
echo "noise line"
cat '$base/export'
exit \${FAKE_EXPORT_RC:-0}
SH
close $s;
chmod 0755, $shim;
$ENV{HPS_OSVC_RUN} = $shim;
open(my $e, '>', "$base/export") or die $!;
print $e "$line\n";
close $e;

sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub hps_osvc { my $out = `perl $Bin/../bin/hps-osvc @_ 2>&1`; return ($? >> 8, $out) }

my $ks = HPS::Keysafe->new(registry => $reg);

# Export fails: the secret is delivered, nothing is stored, exit 1.
{
    local $ENV{FAKE_EXPORT_RC} = 1;
    my ($rc, $out) = hps_osvc('deliver', 'node01');
    is($rc, 1, 'export failure: exit 1');
    like($out, qr/delivered.*CA could not be read/, 'export failure: a warning says so');
    ok(!$ks->has_secret('opensvc-ca'), 'export failure: nothing stored');
}

# Capture path.
my ($rc, $out) = hps_osvc('deliver', 'node01');
is($rc, 0, 'capture: exit 0');
like($out, qr/cluster CA captured from node01 into the keysafe/, 'capture: reported');
is($ks->get_secret('opensvc-ca'), $line, 'capture: the line is in the keysafe');
my $hex = unpack('H*', $ks->cluster_secret('opensvc-cluster', 16));
is(slurp("$base/stdin"), "$hex\n", 'capture: the secret alone was sent first');
like(slurp("$base/argv.log"), qr/^node01 osvc-ca-export$/m, 'capture: osvc-ca-export ran without --input');
unlike($out, qr/ca_marker|\Q$b64\E/, 'capture: the CA is not printed');
ok(index(slurp("$base/argv.log"), $b64) < 0, 'capture: the CA is in no argv');
is(((stat "$base/clusters/lab/keysafe/credentials/opensvc-ca.cred")[2] & 07777), 0600, 'capture: stored mode 0600');

# Send path.
unlink "$base/stdin", "$base/argv.log";
($rc, $out) = hps_osvc('deliver', 'node02');
is($rc, 0, 'send: exit 0');
is(slurp("$base/stdin"), "$hex\n$line\n", 'send: line 2 is the stored CA');
unlike(slurp("$base/argv.log"), qr/osvc-ca-export/, 'send: no export call');
ok(index(slurp("$base/argv.log"), $b64) < 0, 'send: the CA is in no argv');
unlike($out, qr/\Q$b64\E|ca_marker/, 'send: the CA is not printed');

# A damaged stored line is refused without sending.
$ks->put_secret('opensvc-ca', 'garbage');
unlink "$base/stdin";
($rc, $out) = hps_osvc('deliver', 'node02');
is($rc, 1, 'bad stored CA: refused');
ok(!-e "$base/stdin", 'bad stored CA: nothing sent');
unlike($out, qr/garbage/, 'bad stored CA: its content is not echoed');
$ks->put_secret('opensvc-ca', $line);

# Dry run.
unlink "$base/stdin", "$base/argv.log";
($rc, $out) = hps_osvc('deliver', 'node02', '--dry-run');
is($rc, 0, 'dry run: exit 0');
ok(!-e "$base/argv.log", 'dry run: nothing run');
like($out, qr/osvc-ca-export/, 'dry run: describes the export call');

# ca-forget.
($rc, $out) = hps_osvc('ca-forget');
is($rc, 0, 'ca-forget: exit 0');
like($out, qr/deleted the stored cluster CA/, 'ca-forget: says what it did');
ok(!$ks->has_secret('opensvc-ca'), 'ca-forget: the keysafe has none');
($rc, $out) = hps_osvc('ca-forget');
like($out, qr/nothing deleted/, 'ca-forget: again is a no-op');
($rc, $out) = hps_osvc('ca-forget', 'node01');
is($rc, 2, 'ca-forget takes no host');

done_testing;
