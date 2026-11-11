#!/usr/bin/env perl
# The address rule for storage and transit networks (scale test phase 2): a
# host keeps the host part of its provisioning address inside the target
# subnet, modulo the subnet's size; network, broadcast and gateway refused.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::ClusterConfig;

sub addr { my @r = HPS::ClusterConfig::vlan_host_address(@_); return $r[0] }
sub why  { my @r = HPS::ClusterConfig::vlan_host_address(@_); return $r[1] // '' }

# --- /24 into /24: the last octet is kept (s1: sch-001 10.11.0.153)
is(addr('10.11.0.153', 24, '10.113.0.0/24', gateway => '10.113.0.1'), '10.113.0.153', 's1 storage A');
is(addr('10.11.0.153', 24, '10.113.1.0/24', gateway => '10.113.1.1'), '10.113.1.153', 's1 storage B');
is(addr('10.11.0.153', 24, '10.11.2.0/24'), '10.11.2.153', 's1 transit');
is(addr('10.11.0.153', 24, '10.113.0.77/24'), '10.113.0.153', 'a host bit in the target cidr is ignored');

# --- other prefixes: host part modulo the target size
is(addr('10.11.1.10', 23, '10.113.0.0/24'), '10.113.0.10', '/23 host 266 into a /24: 266 mod 256 = 10');
is(addr('10.11.0.153', 24, '10.113.0.64/26'), '10.113.0.89', '/24 host 153 into a /26: 153 mod 64 = 25, + 64');
is(addr('10.11.0.153', 24, '10.200.0.0/16'), '10.200.0.153', '/24 into a /16 keeps the host part');
is(addr('172.16.5.7', 16, '10.113.0.0/24'), '10.113.0.7', '/16 host 1287 into a /24: 1287 mod 256 = 7');

# --- refusals
like(why('10.11.0.1', 24, '10.113.0.0/24', gateway => '10.113.0.1'), qr/the gateway of 10\.113\.0\.0\/24/, 'the gateway is refused');
is(addr('10.11.0.1', 24, '10.11.2.0/24'), '10.11.2.1', 'no gateway given: .1 is a plain host');
like(why('10.11.1.0', 23, '10.113.0.0/24'), qr/the network address/, 'host 256 lands on the network address of a /24');
like(why('10.11.1.255', 23, '10.113.0.0/24'), qr/the broadcast address/, 'host 511 lands on the broadcast address of a /24');
like(why('10.11.0.128', 24, '10.113.0.0/25'), qr/network address/, 'host 128 mod 128 is the network address of a /25');
like(why('10.11.0.127', 24, '10.113.0.0/25'), qr/broadcast address/, 'host 127 is the broadcast of a /25');
like(why('10.11.0.300', 24, '10.113.0.0/24'), qr/not an IPv4 address/, 'a bad provisioning address');
like(why('10.11.0.5', 0, '10.113.0.0/24'), qr/not 1-32/, 'prefix 0');
like(why('10.11.0.5', 'x', '10.113.0.0/24'), qr/not 1-32/, 'a prefix that is not a number');
like(why('10.11.0.5', 24, '10.113.0.0'), qr/not IPv4\/prefix/, 'a target with no prefix');
like(why('10.11.0.5', 24, '10.113.0.0/31'), qr/prefix must be 8 to 30/, 'a /31 target');
like(why('10.11.0.5', 24, undef), qr/not IPv4\/prefix/, 'no target');

# --- prefix_of_netmask
is(HPS::ClusterConfig::prefix_of_netmask('255.255.255.0'), 24, '/24 mask');
is(HPS::ClusterConfig::prefix_of_netmask('255.255.254.0'), 23, '/23 mask');
is(HPS::ClusterConfig::prefix_of_netmask('255.0.255.0'), undef, 'a non-contiguous mask');
is(HPS::ClusterConfig::prefix_of_netmask('nope'), undef, 'not a mask');

done_testing;
