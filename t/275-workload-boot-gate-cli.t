#!/usr/bin/env perl
# Layers 2 and 3 (docs/BOOT-RELIABILITY.md) in bin/hps-workload: start of a network-boot
# VM waits for the IPS boot services and refuses (exit 3) naming what does not answer;
# --no-boot-wait skips it; a disk-boot VM is never gated; status shows "no netboot seen
# since start (N s)".
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use BootFixture;

my $tmp = tempdir(CLEANUP => 1);
StorageFixture::write_hps_run_shim("$tmp/hps-run");
my $HOST = '525400123456';
my $MAC  = '52:54:00:12:34:56';

my $f = StorageFixture::setup_workload(ce => { out => { 'vm-define' => "VM n0-node defined mac=$MAC\n" } });
$f->{reg}->cluster_set('lab', 'network_layout', { %{ StorageFixture::layout() }, prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' } });
StorageFixture::write_def($f, { name => 'n0', project => 'lab', vms => [
    { name => 'n0-node', memory_mib => 4096, vcpus => 2, boot => 'network', nets => ['prov'], compute_host => 'sch-001' } ] });
$f->{wl}->()->run('create', 'n0');
$f->{wl}->()->run('create', 't0');    # the disk-boot workload of the fixture, for the not-gated case
$f->{reg}->cluster_set('lab', 'boot_ready_wait_seconds', '0');

# a fake /proc without dnsmasq, and a udp table; the HTTP side points at a closed port
my $dead = BootFixture::make(dnsmasq => 0);
my $live = BootFixture::make();
my ($http, $pid) = BootFixture::http_server(200, "hps.test\n");
END { kill 'TERM', $pid if $pid }

sub cli {
    my ($env, @args) = @_;
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}            = "$tmp/hps-run";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
    local $ENV{SHIM_DIR}               = $tmp;
    local $ENV{SUDO_USER}              = 'tester';
    local @ENV{ keys %$env } = values %$env;
    delete $ENV{HPS_BOOT_READY_SKIP};
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @args);
    my $out = qx(@cmd 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    my $err = <$e>;
    return ($rc, $out, $err);
}
sub calls { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () }

my %deaf = (HPS_BOOT_READY_PROC => $dead->{proc}, HPS_BOOT_READY_UDP => $dead->{udp}, HPS_BOOT_READY_HTTP => '127.0.0.1:9');
my %live = (HPS_BOOT_READY_PROC => $live->{proc}, HPS_BOOT_READY_UDP => $live->{udp}, HPS_BOOT_READY_HTTP => $http);
# the gate looks in <config_base>/tftp
for my $file (qw(snponly.efi undionly.kpxe)) { mkdir "$f->{base}/tftp"; BootFixture::write_file("$f->{base}/tftp/$file", 'x') }
$f->{reg}->cluster_set('lab', 'network_dhcp_ip', $BootFixture::IPS);

#--- refused
unlink "$tmp/args";
my ($rc, $out, $err) = cli(\%deaf, 'start', 'n0');
is($rc, 3, 'start of a network-boot VM with the boot services down: refused (3)') or diag "$out$err";
like($err, qr/hps-workload: start n0 refused: this IPS's boot services do not answer after 0 s \(dnsmasq: dnsmasq is not running; http: no HTTP answer/, 'naming what does not answer');
like($err, qr/--no-boot-wait/, 'and the way round');
is(scalar(() = $err =~ /start n0 refused:/g), 1, 'said once (the refusal is the event line, notice, kind workload)');
is(scalar(() = calls()), 0, 'nothing was sent to a node');
is(($f->{reg}->cluster_get_json('lab', 'workload_n0'))->{vms}{'n0-node'}{state}, 'defined', 'the record is unchanged');

#--- skipped
($rc, $out, $err) = cli(\%deaf, 'start', 'n0', '--no-boot-wait');
is($rc, 0, '--no-boot-wait: the start goes ahead') or diag "$out$err";
like($out, qr/start ok: workload n0/, 'and says so');
is(($f->{reg}->cluster_get_json('lab', 'workload_n0'))->{vms}{'n0-node'}{state}, 'running', 'running');

#--- allowed
$f->{wl}->()->run('stop', 'n0');
($rc, $out, $err) = cli(\%live, 'start', 'n0');
is($rc, 0, 'boot services answering: the start goes ahead') or diag "$out$err";

#--- dry run and other verbs are not gated
$f->{wl}->()->run('stop', 'n0');
($rc) = cli(\%deaf, 'start', 'n0', '--dry-run');
is($rc, 0, 'start --dry-run is not gated');
($rc) = cli(\%deaf, 'stop', 'n0');
is($rc, 0, 'stop is not gated');
($rc, $out, $err) = cli(\%deaf, 'stop', 'n0', '--no-boot-wait');
is($rc, 2, '--no-boot-wait on stop: usage (2)');
like($err, qr/--no-boot-wait is only for start/, 'says so');

#--- a disk-boot workload is never gated
{
    ok(-e $f->{reg}->workload_dir('lab') . '/t0.json', 'set up: the disk-boot definition exists');
    unlink "$tmp/args";
    ($rc, $out, $err) = cli(\%deaf, 'start', 't0');
    is($rc, 0, 'start of a disk-boot workload with the boot services down: not gated') or diag "$out$err";
}

#--- status
$f->{wl}->()->run('stop', 'n0');
{
    my $now = time;
    cli(\%live, 'start', 'n0');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_n0');
    my @t = gmtime($now - 120);
    $rec->{vms}{'n0-node'}{started_at} = sprintf('%04d-%02d-%02d %02d:%02d:%02d UTC', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
    $f->{reg}->cluster_set('lab', 'workload_n0', $rec);
    ($rc, $out, $err) = cli(\%live, 'status', 'n0');
    is($rc, 0, 'status ok') or diag "$out$err";
    like($out, qr/^    no netboot seen since start \((?:119|12[0-9]) s\)$/m, 'status: "no netboot seen since start (N s)" for a VM that has not reached iPXE');
    ($rc, $out) = cli(\%live, 'status', 'n0', '--json');
    like(decode_json($out)->{vms}[0]{netboot_note}, qr/^no netboot seen since start/, 'status --json carries it');
    $f->{reg}->host_set($HOST, 'last_boot_at', $now);
    ($rc, $out) = cli(\%live, 'status', 'n0');
    unlike($out, qr/no netboot seen/, 'once the node has netbooted, the line is gone');
}

done_testing;
