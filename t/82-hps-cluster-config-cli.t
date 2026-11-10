#!/usr/bin/env perl
# bin/hps-cluster-config end to end against a temp registry.
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
local $ENV{HPS_CLUSTER_CONFIG_NO_SYSLOG} = 1;
my $reg = HPS::Registry->new;
make_path("$base/clusters/lab/cluster.db");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

sub run_cli {
    my ($stdin, @args) = @_;
    my $in = "$base/stdin.txt";
    open(my $fh, '>', $in) or die $!;
    print {$fh} $stdin // '';
    close $fh;
    my $cmd = join ' ', map { quotemeta } $^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-cluster-config", @args;
    my $out = qx($cmd < $in 2>$base/stderr.txt);
    my $rc = $? >> 8;
    open($fh, '<', "$base/stderr.txt") or die $!;
    my $err = do { local $/; <$fh> };
    close $fh;
    return ($rc, $out, $err);
}

my $good = <<'CFG';
# a cluster
DESCRIPTION = Lab cluster
network_dns_domain = lab.example
network_dhcp_iface = eth0
network_dhcp_cidr = 10.99.1.1/24
network_dhcp_rangesize = 50
network_storage_count = 2
network_storage_base_vlan = 31
network_storage_subnet_cidr = 24
network_syslog_server = 10.99.1.1
osvc_hb_type = multicast
CFG

# --- questions
my ($rc, $out, $err) = run_cli('', 'questions', '--json');
is($rc, 0, 'questions --json exits 0');
my $qs = decode_json($out);
is($qs->[0]{key}, 'DESCRIPTION', 'the catalogue starts at the first menu question');
ok((grep { $_->{key} eq 'osvc_hb_type' } @$qs), 'and holds the last');
($rc, $out) = run_cli('', 'questions');
like($out, qr/\[opensvc\]/, 'questions text groups the keys');

# --- dry run writes nothing
($rc, $out, $err) = run_cli($good, 'apply', '-', '--dry-run');
is($rc, 0, 'dry run exits 0');
like($out, qr/dry run, nothing written/, 'dry run says so');
like($out, qr/network_storage_vlan32_subnet: \(unset\) -> '10\.31\.1\.0\/24'  \[derived\]/, 'dry run shows derived keys');
is($reg->cluster_get('lab', 'DESCRIPTION'), undef, 'nothing was written');

# --- all or nothing
my $broken = $good . "osvc_listener_port = 80\nnetwork_storage_mtu = 1400\nnot a pair\n";
($rc, $out, $err) = run_cli($broken, 'apply', '-');
is($rc, 3, 'validation errors exit 3');
like($err, qr/line 12: osvc_listener_port: must be a whole number from 1024 to 65535/, 'error names the line and key');
like($err, qr/line 13: network_storage_mtu/, 'a second error is reported too');
like($err, qr/line 14: .*key = value/, 'a syntax error is reported too');
is($reg->cluster_get('lab', 'DESCRIPTION'), undef, 'the valid lines were not written either');
is($reg->cluster_get('lab', 'network_dns_domain'), undef, 'nothing at all was written');

# --- real apply
($rc, $out, $err) = run_cli($good, 'apply', '-');
is($rc, 0, 'apply exits 0');
like($out, qr/DESCRIPTION: \(unset\) -> 'Lab cluster'/, 'apply prints old -> new');
is($reg->cluster_get('lab', 'network_dhcp_ip'), '10.99.1.1', 'derived dhcp ip written');
is($reg->cluster_get('lab', 'network_cidr'), '10.99.1.0/24', 'derived network written');
is($reg->cluster_get('lab', 'network_storage_vlan31_gateway'), '10.31.0.1', 'derived storage gateway written');
is($reg->cluster_get('lab', 'network_storage_vlan32_domain'), 'storage2.lab.example', 'derived storage domain written');
is($reg->cluster_get('lab', 'network_storage_vlan31_allocated'), 'false', 'allocated initialised');
is($reg->cluster_get('lab', 'network_dhcp_rangesize'), '50', 'a number is stored as given');
like($out, qr/Still unset and required:/, 'remaining unset required keys are named')
    if 0;   # all required keys are set by $good

# --- second apply: everything unchanged
($rc, $out) = run_cli($good, 'apply', '-', '--json');
my $p = decode_json($out);
is($rc, 0, 'repeat apply exits 0');
is(scalar @{ $p->{changes} }, 0, 'repeat apply changes nothing');
ok(scalar @{ $p->{unchanged} } > 10, 'and lists the unchanged keys');
is($p->{ok}, JSON::PP::true, '--json ok is true');

# --- get / set / show
($rc, $out) = run_cli('', 'get', 'DESCRIPTION');
is($out, "Lab cluster\n", 'get prints the value');
($rc) = run_cli('', 'get', 'osvc_log_level');
is($rc, 4, 'get of an unset key exits 4');
($rc, $out) = run_cli('', 'set', 'osvc_log_level', 'debug');
is($rc, 0, 'set exits 0');
is($reg->cluster_get('lab', 'osvc_log_level'), 'debug', 'set wrote the key');
($rc, $out, $err) = run_cli('', 'set', 'osvc_log_level', 'loud');
is($rc, 3, 'set of an invalid value exits 3');
is($reg->cluster_get('lab', 'osvc_log_level'), 'debug', 'and left the value alone');
($rc, $out) = run_cli('', 'set', 'network_storage_count', '3');
is($reg->cluster_get('lab', 'network_storage_vlan33_subnet'), '10.31.2.0/24', 'set recomputes the derived keys');
$reg->cluster_set('lab', 'legacy_extra', 'keepme');
($rc, $out) = run_cli('', 'show', '--json');
my $s = decode_json($out);
is($s->{cluster}, 'lab', 'show names the cluster');
my ($row) = grep { $_->{key} eq 'network_syslog_server' } @{ $s->{keys} };
is($row->{value}, '10.99.1.1', 'show has the value');
($row) = grep { $_->{key} eq 'network_name_server' } @{ $s->{keys} };
is($row->{set}, JSON::PP::false, 'an unset key is shown as unset');
is_deeply([ map { $_->{key} } @{ $s->{other} } ], ['legacy_extra'], 'registry keys outside the catalogue are listed separately');
ok((grep { $_->{key} eq 'network_dhcp_ip' } @{ $s->{derived} }), 'derived keys are listed');
($rc, $out) = run_cli('', 'show');
like($out, qr/network_name_server\s+\(unset\)/, 'show text marks unset keys');

# --- export / apply round trip
($rc, $out) = run_cli('', 'export');
is($rc, 0, 'export exits 0');
like($out, qr/^# Enter descriptive name for this cluster \(required\)\nDESCRIPTION = Lab cluster$/m, 'export puts the prompt above each key');
like($out, qr/^# network_name_server = $/m, 'an unset key is exported commented out');
unlike($out, qr/network_dhcp_ip|vlan31_/, 'derived keys are not exported');
my $exported = $out;
($rc, $out) = run_cli($exported, 'apply', '-', '--json');
is($rc, 0, 'the export applies');
is(scalar @{ decode_json($out)->{changes} }, 0, 'export then apply changes nothing');
($rc, $out) = run_cli('', 'export', '--json');
is(decode_json($out)->{osvc_hb_type}, 'multicast', 'export --json is a key/value object');
my $json_cfg = $out;
($rc, $out) = run_cli($json_cfg, 'apply', '-', '--json');
is(scalar @{ decode_json($out)->{changes} }, 0, 'a JSON file applies and round trips');

# --- bootstrap keys and the layout through the CLI
my $boot = <<'CFG';
network_static_start = 10.99.1.200
network_static_end = 10.99.1.220
network_reserved = 10.99.1.5 10.99.1.6
network_time_upstream = pool.ntp.org
network_layout = {"prod":{"cidr":"10.50.0.0/24","vlan":50,"bridge":"br-prod","purpose":"workload"}}
CFG
($rc, $out, $err) = run_cli($boot, 'apply', '-');
is($rc, 0, 'static range, reserved, upstream and a one-line JSON layout apply');
like($reg->cluster_get('lab', 'network_layout'), qr/"prod"/, 'the layout is stored as a JSON object');
is($reg->cluster_get_json('lab', 'network_layout')->{prod}{vlan}, 50, 'with its fields');
is($reg->cluster_get('lab', 'network_reserved'), '10.99.1.5 10.99.1.6', 'a space-separated list is stored as given');
($rc, $out) = run_cli($boot, 'apply', '-', '--json');
is(scalar @{ decode_json($out)->{changes} }, 0, 'applying the layout again changes nothing');
($rc, $out) = run_cli('', 'export');
like($out, qr/^network_layout = \{"prod":\{[^\n]*\}\}$/m, 'export writes the layout on one line');
($rc, $out) = run_cli($out, 'apply', '-', '--json');
is(scalar @{ decode_json($out)->{changes} }, 0, 'the export with a layout round-trips');
($rc, $out) = run_cli('', 'export', '--json');
is(ref decode_json($out)->{network_layout}, 'HASH', 'export --json carries the layout as an object');
($rc, $out) = run_cli($out, 'apply', '-', '--json');
is(scalar @{ decode_json($out)->{changes} }, 0, 'and it round-trips');
($rc, $out, $err) = run_cli("network_layout = {\"x\":{\"cidr\":\"10.1.0.0/24\",\"bridge\":\"x\",\"purpose\":\"w\"}}\nnetwork_static_end = 10.1.1.1\n", 'apply', '-');
is($rc, 3, 'a bad layout and an outside static address exit 3');
like($err, qr/line 1: network_layout: network 'x': bridge must match/, 'the layout error names the network and field');
like($err, qr/line 2: network_static_end: 10\.1\.1\.1 is not inside/, 'the static range error is reported too');

# --- usage and not found
($rc) = run_cli('', 'frobnicate');
is($rc, 2, 'unknown command exits 2');
($rc) = run_cli('');
is($rc, 2, 'no command exits 2');
($rc) = run_cli('', '--cluster', 'nosuch', 'show');
is($rc, 4, 'unknown cluster exits 4');
($rc) = run_cli('', 'apply', "$base/missing.cfg");
is($rc, 4, 'missing file exits 4');
($rc, $out, $err) = run_cli("api_secret_key = x\n", 'apply', '-');
is($rc, 3, 'a secret-looking key is refused');
($rc, $out) = run_cli($broken, 'apply', '-', '--json');
is($rc, 3, '--json errors exit 3');
is(decode_json($out)->{ok}, JSON::PP::false, 'with ok false');
is(decode_json($out)->{errors}[0]{line}, 12, 'and the error line');

done_testing;
