#!/usr/bin/env perl
# CS-2.5: the command lines. hps-storage zvol-create,
# zvol-destroy, zvol-list, export, unexport, status, with a stand-in for
# scripts/hps-run.sh.
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

StorageFixture::write_hps_run_shim("$tmp/hps-run");

local $ENV{HPS_CONFIG_BASE}       = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY}   = "$f->{base}/system.db";
local $ENV{HPS_RUN_CMD}           = "$tmp/hps-run";
local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
local $ENV{SHIM_DIR}              = $tmp;
local $ENV{SUDO_USER}             = 'tester';

sub cli {
    my ($tool, @args) = @_;
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/$tool", @args);
    my $out = qx(@cmd 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    my $err = <$e>;
    return ($rc, $out . $err, $out);
}
sub calls { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () }
sub reset_shim { unlink "$tmp/args", glob("$tmp/stdin.*") }

my $DS  = 'lab/enc/t0';
my $IQN = 'iqn.2026-11.example.lab:t0';
my $INI = 'iqn.2026-11.example.lab:ips';

# --- hps-storage usage
my ($rc, $out) = cli('hps-storage', $mac, 'zvol-create');
is($rc, 2, 'zvol-create without arguments: usage');
($rc, $out) = cli('hps-storage', $mac, 'zvol-create', $DS);
is($rc, 2, 'zvol-create without a size: usage');
($rc, $out) = cli('hps-storage', $mac, 'zvol-list', 'lab');
is($rc, 2, 'zvol-list takes none');
($rc, $out) = cli('hps-storage', $mac, 'export', $DS);
is($rc, 2, 'export without --iqn/--initiator: usage');
($rc, $out) = cli('hps-storage', $mac, 'up', '--iqn', $IQN);
is($rc, 2, '--iqn only for export');
($rc, $out) = cli('hps-storage', $mac, 'unexport');
is($rc, 2, 'unexport without an iqn: usage');
($rc, $out) = cli('hps-storage', $mac, 'zvol-create', 'lab/t0', '1G');
is($rc, 2, 'bad dataset: usage');
($rc, $out) = cli('hps-storage', $mac, 'zvol-create', $DS, '1g');
is($rc, 2, 'bad size: usage');
($rc, $out) = cli('hps-storage', $mac, 'create', 'lab', '--iqn', $IQN);
is($rc, 2, '--iqn on create: usage');
ok(!calls(), 'usage errors call nothing');

# --- dry runs
($rc, $out) = cli('hps-storage', $mac, 'zvol-create', $DS, '1G', '--dry-run');
is($rc, 0, 'zvol-create --dry-run: 0');
like($out, qr{1\. storage-zvol-create lab/enc/t0 1G}, 'the call is shown');
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', $DS, '--dry-run');
is($rc, 0, 'zvol-destroy --dry-run with no approval: 0');
like($out, qr{storage-zvol-destroy lab/enc/t0\n}, 'the call is shown, no --approval-file');
unlike($out, qr/input:/, 'no input');
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', 'zp03/enc/x', '--dry-run');
is($rc, 3, 'a pool not named after the cluster: refused');
like($out, qr/not the active cluster name 'lab'/, 'says why');
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', 'zp03/enc/x', '--allow-any-pool-name', '--dry-run');
is($rc, 0, '--allow-any-pool-name lets it through');
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', $DS, '--wipe');
is($rc, 2, '--wipe on zvol-destroy: usage');
($rc, $out) = cli('hps-storage', $mac, 'export', $DS, '--iqn', $IQN, '--initiator', $INI, '--portal', '192.0.2.10', '--dry-run');
is($rc, 0, 'export --dry-run: 0');
like($out, qr{iscsi-export lab/enc/t0 --iqn \Q$IQN\E --initiator \Q$INI\E --portal 192\.0\.2\.10}, 'the call is shown');
ok(!$f->{reg}->host_exists($mac, 'storage_exports'), 'dry run recorded nothing');
ok(!calls(), 'dry runs call nothing');

# --- real runs
reset_shim();
($rc, $out) = cli('hps-storage', $mac, 'zvol-create', $DS, '1G');
is($rc, 0, 'zvol-create runs');
like($out, qr/== 1\. storage-zvol-create lab\/enc\/t0 1G \(exit 0\)/, 'result shown');
($rc, $out) = cli('hps-storage', $mac, 'export', $DS, '--iqn', $IQN, '--initiator', $INI, '--portal', '192.0.2.10');
is($rc, 0, 'export runs');
is_deeply($f->{reg}->host_get_json($mac, 'storage_exports'), [ { zvol => $DS, iqn => $IQN, initiator => $INI, portal => '192.0.2.10' } ], 'recorded');
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', $DS);
is($rc, 3, 'zvol-destroy of an exported zvol: refused');
like($out, qr/exported/, 'says why');
($rc, $out) = cli('hps-storage', $mac, 'unexport', $IQN);
is($rc, 0, 'unexport runs');
ok(!$f->{reg}->host_exists($mac, 'storage_exports'), 'entry removed');
reset_shim();
($rc, $out) = cli('hps-storage', $mac, 'zvol-destroy', $DS);
is($rc, 0, 'zvol-destroy runs with no approval');
like(join('', calls()), qr{^--json $mac storage-zvol-destroy lab/enc/t0$}m, 'sent with --json and no input');
($rc, $out) = cli('hps-storage', $mac, 'status');
is($rc, 0, 'status runs');
like(join('', calls()), qr{^--json \Q$mac\E storage-status lab$}m, 'status is the single storage-status call');

done_testing;
