#!/usr/bin/env perl
# hps-storage: create measures unless --no-measure, the measure verb (and its
# --dry-run text), status prints the recorded I/O budget.
use strict;
use warnings;
use Test::More;
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
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-storage", @_);
    my $out = qx(@cmd 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    return ($rc, $out . <$e>);
}
sub calls { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () }
sub reset_shim { unlink "$tmp/args", glob("$tmp/stdin.*") }

my @D = ('--disk', 'ata-SSD1');

# --- create: measures by default, --no-measure skips
my ($rc, $out) = cli($mac, 'create', 'lab', @D, '--dry-run');
is($rc, 0, 'create --dry-run: 0');
like($out, qr/storage-pool-create lab --disk ata-SSD1 --measure\n/, 'default: --measure on the pool create');
like($out, qr/\n  4\. storage-io-measure lab\n/, 'default: the zvol test is the last call');
($rc, $out) = cli($mac, 'create', 'lab', @D, '--no-measure', '--dry-run');
is($rc, 0, '--no-measure --dry-run: 0');
like($out, qr/storage-pool-create lab --disk ata-SSD1\n/, '--no-measure: no flag on the pool create');
unlike($out, qr/storage-io-measure/, '--no-measure: no zvol test');
($rc, $out) = cli($mac, 'up', '--no-measure');
is($rc, 2, '--no-measure is only for create');
like($out, qr/--no-measure is only for create/, 'says so');

reset_shim();
($rc, $out) = cli($mac, 'create', 'lab', @D);
is($rc, 0, 'create runs: 0');
my @c = calls();
like($c[0], qr/storage-pool-create lab --disk ata-SSD1 --measure$/, 'node call carries --measure');
like($c[-1], qr/storage-io-measure lab$/, 'and the zvol test runs last');
is($f->{reg}->host_get($mac, 'storage_write_mbps'), 450, 'the raw write figure from the node stdout is recorded');
is($f->{reg}->host_get($mac, 'storage_pool_write_mbps'), 321, 'the pool figure too');

reset_shim();
($rc, $out) = cli($mac, 'create', 'lab', @D, '--no-measure');
is($rc, 0, 'create --no-measure runs: 0');
unlike(join('', calls()), qr/storage-io-measure|--measure/, 'nothing measured');

# --- status prints the budget
($rc, $out) = cli($mac, 'status');
is($rc, 0, 'status: 0');
like($out, qr/I\/O budget \(measured \d{4}-\d\d-\d\dT[\d:]+Z\):\n  disk read 600 MiB\/s, disk write 450 MiB\/s\n  fsync p50 0\.40 ms, max 1\.00 ms\n  pool \(zvol\) write 321 MiB\/s\n/, 'status prints the recorded figures');

# --- measure
reset_shim();
($rc, $out) = cli($mac, 'measure', '--dry-run');
is($rc, 0, 'measure --dry-run: 0');
like($out, qr/storage-io-measure lab\n/, 'shows the node call');
like($out, qr/create the zvol lab\/enc\/hps-measure \(1 GiB\).*destroy it\./, 'says what it would do');
{ my @n = calls(); is(scalar @n, 0, 'dry run called nothing'); }
($rc, $out) = cli($mac, 'measure');
is($rc, 0, 'measure: 0');
like($out, qr/storage-io-measure lab/, 'the call is shown');
like($out, qr/I\/O budget/, 'the budget is printed');
($rc, $out) = cli($mac, 'measure', 'lab');
is($rc, 2, 'measure takes no further arguments');
($rc, $out) = cli($mac, 'measure', '--wipe');
is($rc, 2, '--wipe is only for create');

# --- status on a host with nothing measured
my $g = StorageFixture::setup();
{
    local $ENV{HPS_CONFIG_BASE}     = $g->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$g->{base}/system.db";
    ($rc, $out) = cli($mac, 'status');
    like($out, qr/I\/O budget: not measured \(hps-storage <host> measure\)/, 'status: not measured says how to measure');
}

done_testing;
