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
local $ENV{HPS_CONFIG_BASE}      = $base;
local $ENV{HPS_SYSTEM_REGISTRY}  = "$base/system.db";
local $ENV{HPS_ONBOARD_NETCONF_CMD} = '';   # no hook (bin defaults to scripts/hps-netconf-hook.sh)
my $reg = HPS::Registry->new;
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->os_set('x86_64:nixos:26.05', 'kernel', 'bzImage');
$reg->host_set('52:54:00:00:00:01', 'STATE', 'HELD');
$reg->host_set('52:54:00:00:00:01', 'audit', { disks => [ { id => 'ata-FAKE_1' } ] });
$reg->host_set('52:54:00:00:00:02', 'STATE', 'INSTALLED');

sub run_cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}

my ($rc, $out) = run_cli('list');
is($rc, 0, 'list exits 0');
like($out, qr/525400000001/, 'list shows the held host');
unlike($out, qr/525400000002/, 'list hides the others');

($rc, $out) = run_cli('list', '--json');
is($rc, 0, 'list --json exits 0');
is(decode_json($out)->[0]{mac}, '525400000001', 'list --json parses');

($rc, $out) = run_cli('show', '52:54:00:00:00:01');
is($rc, 0, 'show exits 0');
like($out, qr/ata-FAKE_1/, 'show renders the audit');
($rc, $out) = run_cli('show', '52:54:00:00:00:01', '--json');
is(decode_json($out)->{audit}{disks}[0]{id}, 'ata-FAKE_1', 'show --json parses');
($rc) = run_cli('show', '52:54:00:00:00:77');
is($rc, 4, 'show unknown host exits 4');

my @good = ('--type', 'SCH', '--profile', 'CONVERGED', '--os', 'x86_64:nixos:26.05', '--pin', 'pin-1');
($rc, $out) = run_cli('assign', '52:54:00:00:00:02', @good);
is($rc, 3, 'assign non-HELD exits 3');
like($out, qr/INSTALLED/, 'message names the state');
($rc) = run_cli('assign', '52:54:00:00:00:01', '--type', 'XXX', @good[2 .. $#good]);
is($rc, 2, 'bad type exits 2');
($rc) = run_cli('frobnicate');
is($rc, 2, 'unknown command exits 2');
($rc) = run_cli();
is($rc, 2, 'no command exits 2');
($rc) = run_cli('assign', '52:54:00:00:00:01', @good, '--storage', 'note');
is($rc, 0, 'assign exits 0');
is($reg->host_get('52:54:00:00:00:01', 'STATE'), 'NETWORK_BOOT', 'state advanced');

done_testing;
