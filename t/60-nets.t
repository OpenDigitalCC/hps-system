#!/usr/bin/env perl
# CS-3.1: hps-onboard nets (HPS::Onboard attach_nets / nets), validated against
# the cluster key network_layout.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Onboard;

my $base = tempdir(CLEANUP => 1);
local $ENV{HPS_CONFIG_BASE}         = $base;
local $ENV{HPS_SYSTEM_REGISTRY}     = "$base/system.db";
local $ENV{HPS_ONBOARD_NETCONF_CMD} = '';
my $reg = HPS::Registry->new;
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $mac = '52:54:00:00:00:01';
$reg->host_set($mac, 'STATE', 'INSTALLED');

sub run_cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $pid = open(my $fh, "-|") // die "fork: $!";
    if (!$pid) { open STDERR, ">&", \*STDOUT; exec @cmd or exit 127 }
    my $out = do { local $/; <$fh> };
    close $fh;
    return ($? >> 8, $out);
}

# no layout at all
my ($rc, $out) = run_cli('nets', $mac, '--attach', 'odoo');
is($rc, 4, 'attach with no layout: not found (4)');
like($out, qr/no network layout/, 'says there is no layout');
ok(!$reg->host_exists($mac, 'nets'), 'nothing written');
($rc, $out) = run_cli('nets', $mac);
is($rc, 0, 'listing with nothing attached exits 0');
like($out, qr/No networks attached/, 'says none');

my $layout = {
    odoo => { cidr => '10.40.0.0/24', vlan => 40,    bridge => 'br-odoo', purpose => 'workload' },
    db   => { cidr => '10.41.0.0/24', vlan => 41,    bridge => 'br-db',   purpose => 'storage' },
    flat => { cidr => '10.42.0.0/24', vlan => undef, bridge => 'br-flat', purpose => 'workload' },
};
$reg->cluster_set('lab', 'network_layout', $layout);

($rc, $out) = run_cli('nets', $mac, '--attach', 'odoo,db');
is($rc, 0, 'attach two exits 0');
like($out, qr/odoo, db/, 'prints the list');
is_deeply($reg->host_get_json($mac, 'nets'), [ 'odoo', 'db' ], 'host key nets is a JSON list in order');

($rc, $out) = run_cli('nets', $mac);
is($rc, 0, 'list exits 0');
like($out, qr/odoo\s+10\.40\.0\.0\/24\s+vlan 40\s+bridge br-odoo\s+workload/, 'list shows the layout fields');
like($out, qr/flat|db\s+10\.41/, 'second network listed');
($rc, $out) = run_cli('nets', $mac, '--json');
my $j = decode_json($out);
is($j->[1]{bridge}, 'br-db', 'list --json carries the layout fields');

($rc, $out) = run_cli('show', $mac);
like($out, qr/Networks attached: odoo, db/, 'show prints the attached networks');
unlike($out, qr/^\s+nets:/m, 'nets is not duplicated in the identity block');
($rc, $out) = run_cli('show', $mac, '--json');
is_deeply(decode_json($out)->{nets}, [ 'odoo', 'db' ], 'show --json has nets');

# replacement, not append
($rc) = run_cli('nets', $mac, '--attach', 'flat');
is($rc, 0, 'replace');
is_deeply($reg->host_get_json($mac, 'nets'), ['flat'], 'the list was replaced');

# refusals leave the previous value alone
($rc, $out) = run_cli('nets', $mac, '--attach', 'flat,nosuch');
is($rc, 4, 'a network not in the layout: not found (4)');
like($out, qr/'nosuch' is not in the network layout \(db, flat, odoo\)/, 'names it and the choices');
is_deeply($reg->host_get_json($mac, 'nets'), ['flat'], 'previous value kept after a refusal');
($rc, $out) = run_cli('nets', $mac, '--attach', 'provisioning');
is($rc, 2, 'provisioning is implicit: usage (2)');
($rc) = run_cli('nets', $mac, '--attach', 'Odoo');
is($rc, 2, 'bad name: usage (2)');
($rc) = run_cli('nets', $mac, '--attach', 'odoo,odoo');
is($rc, 2, 'duplicate: usage (2)');
($rc) = run_cli('nets', '52:54:00:00:00:99', '--attach', 'odoo');
is($rc, 4, 'unknown host: 4');
($rc) = run_cli('nets', 'zz', '--attach', 'odoo');
is($rc, 2, 'bad MAC: 2');
($rc) = run_cli('nets');
is($rc, 2, 'no MAC: usage');

# clearing
($rc, $out) = run_cli('nets', $mac, '--attach', '');
is($rc, 0, 'empty --attach clears');
ok(!$reg->host_exists($mac, 'nets'), 'key removed');

# the Bash side reads what Perl wrote: a pretty JSON array that jq parses
$reg->host_set($mac, 'nets', [ 'odoo', 'db' ]);
my $file = "$base/clusters/lab/hosts/525400000001.db/nets.json";
my $text = do { open my $fh, '<', $file or die; local $/; <$fh> };
is_deeply(decode_json($text), [ 'odoo', 'db' ], 'stored file is a plain JSON array');

done_testing;
