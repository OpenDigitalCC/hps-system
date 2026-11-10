#!/usr/bin/env perl
# Rules, derived keys (compared with what 050-set-storage-network.sh computes)
# and the all-or-nothing plan.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::ClusterConfig;

$ENV{HPS_CLUSTER_CONFIG_NO_SYSLOG} = 1;
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db");
my @log;
my $cc = HPS::ClusterConfig->new(registry => $reg, cluster => 'lab', logger => sub { push @log, [@_] });

my %q = map { $_->{key} => $_ } HPS::ClusterConfig::questions();
sub bad  { my ($k, $v, $label) = @_; ok(defined HPS::ClusterConfig::validate_value($q{$k}, $v), "$k rejects $label") }
sub good { my ($k, $v, $label) = @_; is(HPS::ClusterConfig::validate_value($q{$k}, $v), undef, "$k accepts $label") }

# --- rules
good('DESCRIPTION', 'Lab cluster', 'text');
bad('DESCRIPTION', '', 'empty');
bad('DESCRIPTION', "a\nb", 'a newline');
good('network_dns_domain', 'prod.example.com', 'a domain');
bad('network_dns_domain', '-bad.example', 'a leading hyphen');
bad('network_dns_domain', ('a' x 64) . '.local', 'a 64-character label');
good('network_dhcp_enabled', 'false', 'false');
bad('network_dhcp_enabled', 'yes', 'yes for a bool');
good('network_dhcp_cidr', '10.99.1.1/24', 'ip/prefix');
bad('network_dhcp_cidr', '10.99.1.1', 'no prefix');
bad('network_dhcp_cidr', '10.99.1.1/33', 'prefix 33');
bad('network_dhcp_cidr', '10.99.1.300/24', 'octet 300');
good('network_dhcp_range_start', '', 'empty (optional)');
bad('network_dhcp_range_start', '10.99.1', 'a short address');
good('network_dhcp_rangesize', '100', 'a size');
bad('network_dhcp_rangesize', '0', 'zero');
bad('network_dhcp_rangesize', '1x', 'text');
good('network_storage_count', '0', 'zero networks');
good('network_storage_count', '10', 'ten');
bad('network_storage_count', '11', 'eleven');
good('network_storage_base_vlan', '99', 'vlan 99');
bad('network_storage_base_vlan', '30', 'vlan 30');
good('network_storage_subnet_base', '10.31', 'X.Y');
bad('network_storage_subnet_base', '10.31.0', 'X.Y.Z');
bad('network_storage_subnet_base', '10.256', 'octet 256');
good('network_storage_subnet_cidr', '28', '/28');
bad('network_storage_subnet_cidr', '29', '/29');
good('network_storage_mtu', '9000', '9000');
bad('network_storage_mtu', '1400', '1400');
good('network_time_server', 'pool.ntp.org', 'a host name');
good('network_time_server', '10.99.1.1', 'an ip');
bad('network_time_server', '10.99.1', 'a malformed ip');
good('network_time_server', '', 'empty (optional)');
bad('network_syslog_server', 'host', 'a name for an ip rule');
good('osvc_log_level', 'warn', 'warn');
bad('osvc_log_level', 'trace', 'trace');
good('osvc_listener_port', '1024', 'port 1024');
bad('osvc_listener_port', '1023', 'port 1023');
bad('osvc_listener_port', '65536', 'port 65536');
good('osvc_web_ui', 'no', 'no');
bad('osvc_web_ui', 'true', 'true for yes/no');
bad('osvc_hb_interval', '61', 'interval 61');
bad('osvc_hb_timeout', '4', 'timeout 4');
bad('osvc_hb_type', 'broadcast', 'broadcast');
good('osvc_templates_url', '', 'empty url');

# --- derived DHCP keys
is_deeply(HPS::ClusterConfig::derive_dhcp('10.99.1.77/24'),
    { network_dhcp_ip => '10.99.1.77', network_cidr => '10.99.1.0/24' }, 'dhcp network derived');
is_deeply(HPS::ClusterConfig::derive_dhcp('172.16.5.9/20'),
    { network_dhcp_ip => '172.16.5.9', network_cidr => '172.16.0.0/20' }, 'dhcp network on a non-octet prefix');

# --- derived storage keys equal what 050 computes (the shell functions it calls)
my $netfn = "$Bin/../lib/functions.d/network-functions.sh";
sub shell_050 {
    my ($count, $base_vlan, $sbase, $prefix, $dom) = @_;
    my $script = <<"SH";
source "$netfn"
for ((i=0; i<$count; i++)); do
  vlan=\$((  $base_vlan + i ))
  subnet=\$(network_calculate_subnet "$sbase" "\$i" "$prefix")
  network_addr="\${subnet%/*}"
  gateway="\${network_addr%.*}.1"
  netmask=\$(cidr_to_netmask "$prefix")
  echo "network_storage_vlan\${vlan}_subnet=\$subnet"
  echo "network_storage_vlan\${vlan}_gateway=\$gateway"
  echo "network_storage_vlan\${vlan}_netmask=\$netmask"
  echo "network_storage_vlan\${vlan}_domain=storage\$((i+1)).$dom"
done
SH
    open(my $p, '-|', 'bash', '-c', $script) or die $!;
    my %h = map { chomp; split /=/, $_, 2 } <$p>;
    close $p;
    return \%h;
}
for my $s ([ 3, 31, '10.31', 24 ], [ 2, 40, '10.40', 16 ], [ 4, 31, '10.31', 26 ], [ 5, 50, '192.168', 28 ], [ 1, 99, '10.99', 25 ]) {
    my ($derived, $e) = HPS::ClusterConfig::derive_storage(@$s, 'lab.example');
    is($e, undef, "storage derive count=$s->[0] /$s->[3]: no error");
    is_deeply($derived, shell_050(@$s, 'lab.example'), "storage derive count=$s->[0] /$s->[3] equals 050");
}
my (undef, $e) = HPS::ClusterConfig::derive_storage(3, 98, '10.98', 24, 'x');
like($e, qr/exceed 99/, 'VLAN range past 99 is an error');
(undef, $e) = HPS::ClusterConfig::derive_storage(1, 31, '10.31', 20, 'x');
like($e, qr/Unsupported CIDR/, 'a prefix the shell cannot lay out is an error');

# --- plan: derivation, allocated state, cross rules
my $cfg = [ map { { key => $_->[0], value => $_->[1], line => $_->[2] } }
    [ network_dns_domain => 'lab.example', 1 ],
    [ network_dhcp_cidr => '10.99.1.1/24', 2 ],
    [ network_storage_count => 2, 3 ],
    [ network_storage_base_vlan => 31, 4 ],
    [ network_storage_subnet_base => '10.31', 5 ],
    [ network_storage_subnet_cidr => 24, 6 ],
];
my $plan = $cc->plan($cfg);
is(scalar @{ $plan->{errors} }, 0, 'a consistent set plans without errors');
my %new = map { $_->{key} => $_->{new} } @{ $plan->{changes} };
is($new{network_dhcp_ip}, '10.99.1.1', 'plan derives network_dhcp_ip');
is($new{network_cidr}, '10.99.1.0/24', 'plan derives network_cidr');
is($new{network_storage_vlan32_subnet}, '10.31.1.0/24', 'plan derives the second VLAN subnet');
is($new{network_storage_vlan31_allocated}, 'false', 'allocated starts false');
is($new{network_storage_vlan31_domain}, 'storage1.lab.example', 'domain from the dns domain');

$cc->apply($cfg);
$reg->cluster_set('lab', 'network_storage_vlan31_allocated', 'true');
$plan = $cc->plan($cfg);
is(scalar @{ $plan->{changes} }, 0, 'planning again changes nothing');
ok((grep { $_ eq 'network_storage_vlan31_allocated' } @{ $plan->{unchanged} }), 'allocated=true is kept, not reset');
$cc->apply($cfg);
is($reg->cluster_get('lab', 'network_storage_vlan31_allocated'), 'true', 'apply does not reset allocated state');

$plan = $cc->plan([ { key => 'network_dhcp_ip', value => '10.99.1.2', line => 7 } ]);
like($plan->{errors}[0]{message}, qr/expected 10\.99\.1\.1/, 'a given derived key must agree');
is($plan->{errors}[0]{line}, 7, 'the error carries its line');
$plan = $cc->plan([ { key => 'osvc_web_port', value => '1215', line => 1 } ]);
like($plan->{errors}[0]{message}, qr/same as the listener/, 'web port equal to the listener port is refused');
$plan = $cc->plan([ { key => 'osvc_hb_timeout', value => '5', line => 1 } ]);
like($plan->{errors}[0]{message}, qr/greater than interval/, 'timeout not above interval is refused');
$plan = $cc->plan([ { key => 'bogus', value => '1', line => 9 }, { key => 'network_storage_mtu', value => 'x', line => 10 } ]);
is(scalar @{ $plan->{errors} }, 2, 'every error is reported');
$plan = $cc->plan([ { key => 'api_secret_key', value => '1', line => 1 } ]);
like($plan->{errors}[0]{message}, qr/secrets/, 'a secret-looking key is refused with a reason');
$plan = $cc->plan([ { key => 'network_storage_vlan33_subnet', value => '10.31.2.0/24', line => 1 } ]);
like($plan->{errors}[0]{message}, qr/outside/, 'a VLAN key outside the range is refused');

# --- parse_file
my ($entries, $errors) = HPS::ClusterConfig::parse_file("# c\n\nDESCRIPTION = a b\nosvc_hb_type=multicast\n");
is_deeply([ map { "$_->{key}=$_->{value}\@$_->{line}" } @$entries ], [ 'DESCRIPTION=a b@3', 'osvc_hb_type=multicast@4' ], 'key = value lines parse with line numbers');
is(scalar @$errors, 0, 'no parse errors');
($entries, $errors) = HPS::ClusterConfig::parse_file("a = 1\nnonsense\na = 2\n");
is(scalar @$errors, 2, 'a bad line and a duplicate are both reported');
($entries, $errors) = HPS::ClusterConfig::parse_file('{"osvc_hb_interval": 7, "network_dhcp_enabled": true}');
is_deeply({ map { $_->{key} => $_->{value} } @$entries }, { osvc_hb_interval => '7', network_dhcp_enabled => 'true' }, 'JSON object parses, booleans become true/false');

done_testing;
