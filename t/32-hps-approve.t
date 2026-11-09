#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;

my $base = tempdir(CLEANUP => 1);
local $ENV{HPS_CONFIG_BASE}     = $base;
local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
local $ENV{SUDO_USER}           = 'op1';
my $reg = HPS::Registry->new;
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->host_set('52:54:00:00:00:01', 'STATE', 'NETWORK_BOOT');
$reg->host_set('52:54:00:00:00:02', 'STATE', 'HELD');

sub run_cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-approve", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}

my $mac = '52:54:00:00:00:01';
my ($rc, $out) = run_cli('pool-create', $mac, '--pool', 'lab', '--disk', 'ata-A', '--disk', 'ata-B');
is($rc, 0, 'pool-create exits 0');
like($out, qr/Approved pool-create for host 525400000001/, 'names the action and host');
like($out, qr/^\s+ata-A$/m, 'prints each by-id path');
like($out, qr/^\s+ata-B$/m, 'prints the second path');
like($out, qr/Wipe:\s+no/, 'states wipe no');
like($out, qr/Expires: \d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC \(epoch \d+\)/, 'prints the expiry');
like($out, qr/By:\s+op1/, 'prints who approved');
unlike($out, qr/[0-9a-f]{64}/, 'text output carries no 64-hex value');
ok($reg->host_exists($mac, 'approval_pool-create_lab'), 'stored in the registry');

($rc, $out) = run_cli('pool-create', $mac, '--pool', 'lab', '--disk', 'ata-C', '--wipe', '--expires', '600', '--json');
is($rc, 0, '--wipe --json exits 0');
my $j = decode_json($out);
is($j->{wipe}, 1, 'json wipe');
is_deeply($j->{disks}, ['ata-C'], 'json replaces the earlier approval');
ok($j->{expires} - time <= 600 && $j->{expires} - time > 590, '--expires is seconds from now');

($rc, $out) = run_cli('list', $mac);
is($rc, 0, 'list exits 0');
like($out, qr/pool-create\s+valid\s+lab\s+yes/, 'list shows the valid approval');
($rc, $out) = run_cli('list', $mac, '--json');
is(decode_json($out)->[0]{status}, 'valid', 'list --json');

# pool-name ruling
($rc, $out) = run_cli('pool-create', $mac, '--pool', 'tank', '--disk', 'ata-A');
is($rc, 3, 'a pool not named after the cluster is refused');
like($out, qr/active cluster name 'lab'/, 'message gives the ruling');
($rc) = run_cli('pool-create', $mac, '--pool', 'tank', '--disk', 'ata-A', '--allow-any-pool-name');
is($rc, 0, '--allow-any-pool-name overrides');

# pool-destroy
($rc, $out) = run_cli('pool-destroy', $mac, '--pool', 'zp03');
is($rc, 3, 'destroy of zp03 needs the override');
($rc, $out) = run_cli('pool-destroy', $mac, '--pool', 'zp03', '--allow-any-pool-name');
is($rc, 0, 'destroy with the override');
like($out, qr/Approved pool-destroy/, 'destroy printed');
($rc) = run_cli('pool-destroy', $mac, '--pool', 'lab', '--disk', 'ata-A');
is($rc, 2, 'destroy takes no disks');

# HELD / unknown
($rc, $out) = run_cli('pool-create', '52:54:00:00:00:02', '--pool', 'lab', '--disk', 'ata-A');
is($rc, 3, 'a HELD host is refused');
like($out, qr/not assigned/, 'message says so');
ok(!$reg->host_exists('525400000002', 'approval_pool-create_lab'), 'nothing stored for the HELD host');
($rc) = run_cli('pool-create', '52:54:00:00:00:77', '--pool', 'lab', '--disk', 'ata-A');
is($rc, 4, 'unknown host exits 4');

# usage
($rc) = run_cli('pool-create', $mac, '--pool', 'lab');
is($rc, 2, 'no disk exits 2');
($rc) = run_cli('pool-create', $mac, '--disk', 'ata-A');
is($rc, 2, 'no pool exits 2');
($rc) = run_cli('pool-create', $mac, '--pool', 'lab', '--disk', '../x');
is($rc, 2, 'bad disk id exits 2');
($rc) = run_cli('pool-create', $mac, '--pool', 'lab', '--disk', 'a', '--expires', '-5');
is($rc, 2, 'bad expiry exits 2');
($rc) = run_cli('frobnicate');
is($rc, 2, 'unknown command exits 2');
($rc) = run_cli();
is($rc, 2, 'no command exits 2');
($rc) = run_cli('pool-create', 'nonsense', '--pool', 'lab', '--disk', 'a');
is($rc, 2, 'bad MAC exits 2');

# revoke
($rc, $out) = run_cli('revoke', $mac, 'pool-destroy', 'zp03');
is($rc, 0, 'revoke exits 0');
like($out, qr/Revoked pool-destroy/, 'revoke printed');
($rc) = run_cli('revoke', $mac, 'pool-destroy', 'zp03');
is($rc, 4, 'revoke of nothing exits 4');
($rc) = run_cli('revoke', $mac, 'pool-destroy');
is($rc, 2, 'revoke arguments');

# bad permissions on the keysafe: refused (3), never repaired
chmod 0755, "$base/clusters/lab/keysafe";
($rc, $out) = run_cli('pool-create', $mac, '--pool', 'lab', '--disk', 'ata-A');
is($rc, 3, 'group/world accessible keysafe exits 3');
like($out, qr/repair/, 'message points at the repair');
is(sprintf('%04o', (stat "$base/clusters/lab/keysafe")[2] & 07777), '0755', 'not chmod\'ed');

done_testing;
