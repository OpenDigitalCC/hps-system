#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

$StorageFixture::NOW = time;
my $f   = StorageFixture::setup();
my $mac = $StorageFixture::MAC;
my $tmp = tempdir(CLEANUP => 1);

# A stand-in for scripts/hps-run.sh: records its arguments and stdin; in
# --input --json mode answers like ctrl-exec-cli would.
StorageFixture::write_hps_run_shim("$tmp/hps-run");

local $ENV{HPS_CONFIG_BASE}     = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
local $ENV{HPS_RUN_CMD}         = "$tmp/hps-run";
local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
local $ENV{SHIM_DIR}            = $tmp;
local $ENV{SUDO_USER}           = 'tester';

sub cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-storage", @_);
    my $out = qx(@cmd 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    my $err = <$e>;
    return ($rc, $out . $err, $out);
}
sub ncalls { my @c = calls(); return scalar @c }
sub calls { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () }
sub reset_shim { unlink "$tmp/args", glob("$tmp/stdin.*") }
sub stdins { return map { open(my $h, '<', $_) or die; local $/; scalar <$h> } glob("$tmp/stdin.*") }

# --- usage
my ($rc, $out) = cli();
is($rc, 2, 'no arguments: usage (2)');
($rc, $out) = cli($mac);
is($rc, 2, 'host only: usage');
($rc, $out) = cli($mac, 'explode');
is($rc, 2, 'unknown operation: usage');
($rc, $out) = cli($mac, 'create');
is($rc, 2, 'create without a pool: usage');
like($out, qr/needs a pool name/, 'says so');
($rc, $out) = cli($mac, 'up', 'lab');
is($rc, 2, 'up takes no pool: usage');
($rc, $out) = cli($mac, 'up', '--allow-any-pool-name');
is($rc, 2, '--allow-any-pool-name only for create/destroy');
($rc, $out) = cli($mac, 'up', '--yes');
is($rc, 2, '--yes only for forget-key');
($rc, $out) = cli($mac, 'up', '--bogus');
is($rc, 2, 'unknown option: usage');
is(ncalls(), 0, 'usage errors call nothing');

# --- not found
($rc, $out) = cli('52:54:00:00:00:99', 'status');
is($rc, 4, 'unknown MAC: not found (4)');
($rc, $out) = cli('no-such-host', 'up');
is($rc, 4, 'unknown HOSTNAME: not found');
($rc, $out) = cli('sch-001', 'up');
is($rc, 4, 'up without a key: not found (4)');
like($out, qr/pool not created by HPS/, 'message');
is(ncalls(), 0, 'nothing called');

# --- dry run, text and json
$f->{ks}->get_or_create_key($mac, 'enc');
($rc, $out) = cli('sch-001', 'up', '--dry-run');
is($rc, 0, 'up --dry-run: 0');
like($out, qr/Dry run: up on host $mac, pool lab; nothing is sent or changed/, 'says nothing is sent');
like($out, qr/1\. storage-pool-import lab\n\s+2\. dataset-unlock lab\/enc\n\s+input: \{"key_hex":"<redacted/, 'lists the calls with redacted input');
unlike($out, qr/[0-9a-f]{64}/, 'no 64-hex in the output');
is(ncalls(), 0, 'dry run called nothing');
($rc, $out, my $so) = cli($mac, 'up', '--dry-run', '--json');
is($rc, 0, '--json dry-run: 0');
my $j = decode_json($so);
is($j->{dry_run}, 1, 'json dry_run');
is_deeply([ map { $_->{script} } @{ $j->{plan} } ], [ 'storage-pool-import', 'dataset-unlock' ], 'json plan');

# --- the pool-name ruling
StorageFixture::approve($f, 'pool-create', pool => 'zp03', expires => time + 3600);
($rc, $out) = cli($mac, 'create', 'zp03');
is($rc, 3, 'create zp03: refused (3)');
like($out, qr/not the active cluster name 'lab'/, 'says why');
is(ncalls(), 0, 'nothing called');
($rc, $out) = cli($mac, 'create', 'zp03', '--allow-any-pool-name', '--dry-run');
is($rc, 0, '--allow-any-pool-name lets it through (dry run)');
($rc, $out) = cli($mac, 'destroy', 'zp03');
is($rc, 3, 'destroy zp03: refused by the ruling');

# --- create without approval, then with
($rc, $out) = cli($mac, 'create', 'lab', '--dry-run');
is($rc, 3, 'create without an approval: refused (3)');
like($out, qr/no pool-create approval/, 'says so');
StorageFixture::approve($f, 'pool-create', expires => time + 3600);
($rc, $out) = cli($mac, 'create', 'lab', '--dry-run');
is($rc, 0, 'create --dry-run with approval: 0');
like($out, qr{/dev/disk/by-id/ata-SSD1\n\s+/dev/disk/by-id/ata-SSD2}, 'the approved by-id disks are printed');
like($out, qr/storage-pool-create lab --disk ata-SSD1 --disk ata-SSD2 --approval-file -/, 'create call shown');
unlike($out, qr/[0-9a-f]{64}/, 'no 64-hex');
is(ncalls(), 0, 'dry run called nothing');

reset_shim();
($rc, $out) = cli($mac, 'create', 'lab');
is($rc, 0, 'create runs: 0');
my $disks_at = index($out, '/dev/disk/by-id/ata-SSD1');
my $run_at   = index($out, '== 1. storage-pool-create');
ok($disks_at >= 0 && $run_at > $disks_at, 'by-id disks are printed before the first call result');
my @c = calls();
like($c[0], qr/^--input --json $mac storage-pool-create lab --disk ata-SSD1 --disk ata-SSD2 --approval-file -$/, 'hps-run called with --input --json and the MAC');
my @in = stdins();
is(scalar(@in), 2, 'two calls carried input (create, unlock)');
my ($create_in) = grep { /"approval"/ } @in;
my $doc = decode_json($create_in);
is_deeply([ sort keys %$doc ], [ 'approval', 'key_hex', 'secret' ], 'create stdin document');
my ($unlock_in) = grep { !/"approval"/ } @in;
like($unlock_in, qr/^\{"key_hex":"[0-9a-f]{64}"\}$/, 'unlock stdin document');
like($out, qr/node says hi/, 'node stdout shown');
is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'registry says up');

# --- json run output carries no secret
reset_shim();
($rc, $out, $so) = cli($mac, 'up', '--json');
is($rc, 0, 'up --json: 0');
$j = decode_json($so);
is($j->{ok}, 1, 'json ok');
my $key_hex = unpack('H*', $f->{ks}->get_or_create_key($mac, 'enc'));
ok(index($out, $key_hex) < 0, 'the key is not in the output');

# --- node refusal and failure map to exit codes
reset_shim();
{
    local $ENV{FAKE_NODE_EXIT} = 3;
    ($rc, $out) = cli($mac, 'up');
    is($rc, 3, 'node exit 3: refused (3)');
    like($out, qr/storage-pool-import exited 3: node complains/, 'node stderr in the message');
    unlike($out, qr/-> agent/, 'hps-run banner is not taken for the reason');
}
{
    local $ENV{FAKE_NODE_EXIT}   = 3;
    local $ENV{FAKE_NODE_STDERR} = "+ test -d /lab/enc/images\n[image-fetch] refused: --dest is not an existing directory";
    ($rc, $out) = cli($mac, 'status');
    is($rc, 3, 'node exit 3 on a call without input: refused (3), not the client\'s 1');
    like($out, qr/storage-status exited 3: \[image-fetch\] refused: --dest is not an existing directory/, 'the script\'s last stderr line is the reason');
}
{
    local $ENV{FAKE_NODE_EXIT} = 1;
    ($rc, $out) = cli($mac, 'up');
    is($rc, 1, 'node exit 1: failed (1)');
}
{
    local $ENV{FAKE_RUN_RC} = 4;
    ($rc, $out) = cli($mac, 'status');
    is($rc, 1, 'hps-run failing (no agent) is a failure (1)');
    like($out, qr/not a run result.*\n?|no registered agent/, 'and says why');
}

# --- status / trim-check output
reset_shim();
($rc, $out) = cli($mac, 'trim-check');
is($rc, 0, 'trim-check: 0');
like($out, qr/== 1\. storage-trim-check lab \(exit 0\)\nnode says hi/, 'call output shown');
unlike(join('', calls()), qr/--input/, 'a call without input does not use --input');
like(join('', calls()), qr/^--json $mac storage-trim-check lab$/m, 'a call without input still asks for --json');

# --- forget-key
($rc, $out) = cli($mac, 'forget-key');
is($rc, 3, 'forget-key while a pool is recorded: refused');
ok($f->{ks}->has_key($mac, 'enc'), 'key kept');
($rc, $out) = cli($mac, 'forget-key', '--yes', '--dry-run');
is($rc, 0, 'dry run ok');
ok($f->{ks}->has_key($mac, 'enc'), 'dry run keeps the key');
($rc, $out) = cli($mac, 'forget-key', '--yes');
is($rc, 0, 'forget-key --yes: 0');
like($out, qr/Deleted the 'enc' key/, 'says so');
ok(!$f->{ks}->has_key($mac, 'enc'), 'key gone');

# --- destroy
StorageFixture::approve($f, 'pool-destroy', expires => time + 3600);
reset_shim();
($rc, $out) = cli($mac, 'destroy', 'lab');
is($rc, 0, 'destroy with approval: 0');
ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'storage_state cleared');
done_testing;
