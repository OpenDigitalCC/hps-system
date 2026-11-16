#!/usr/bin/env perl
# hps-onboard assign --profile STARTER: a host is given the distribution's
# stock starter (hps-starter) instead of a built, pinned image. It takes no
# pin; every other profile still needs one (docs/STARTER.md).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Onboard;

$ENV{HPS_ONBOARD_NETCONF_CMD} = '';

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->os_set('x86_64:nixos:26.05', 'kernel', 'bzImage');
my $ob = HPS::Onboard->new(registry => $reg, resources => "$base/res");

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return; my $e = $@; return ref $e ? $e : undef }

my ($h1, $h2, $h3) = ('52:54:00:00:01:01', '52:54:00:00:01:02', '52:54:00:00:01:03');
$reg->host_set($_, 'STATE', 'HELD') for $h1, $h2, $h3;

my %starter = (type => 'TCH', profile => 'STARTER', os => 'x86_64:nixos:26.05');

my $e = err_of(sub { $ob->assign($h1, { %starter, pin => 'nixos-26.05.20261109' }) });
is($e && $e->kind, 'usage', 'STARTER with a pin is a usage error');
like($e && $e->message, qr/takes no pin/, 'the message says why');
is($reg->host_get($h1, 'STATE'), 'HELD', 'a refused assign leaves the host HELD');

$e = err_of(sub { $ob->assign($h1, { type => 'TCH', profile => 'CONVERGED', os => 'x86_64:nixos:26.05' }) });
is($e && $e->kind, 'usage', 'any other profile still needs a pin');

$e = err_of(sub { $ob->assign($h1, { %starter, os => 'x86_64:nixos:99.99' }) });
is($e && $e->kind, 'notfound', 'the OS must be in the OS registry');

my $r = $ob->assign($h1, {%starter});
is($r->{state}, 'NETWORK_BOOT', 'STARTER assign: network boot');
is($reg->host_get('525400000101', 'HOST_PROFILE'), 'STARTER', 'HOST_PROFILE is STARTER');
is($reg->host_get('525400000101', 'os_id'), 'x86_64:nixos:26.05', 'os_id names the release');
is($reg->host_get('525400000101', 'TYPE'), 'TCH', 'TYPE recorded');
ok(!$reg->host_exists('525400000101', 'system_pin'), 'no system_pin is recorded');

# A host that was pinned before and is HELD again carries no pin into the starter.
$reg->host_set($h2, 'system_pin', 'oldpin');
$ob->assign($h2, {%starter});
ok(!$reg->host_exists('525400000102', 'system_pin'), 'a leftover system_pin is removed by the STARTER assign');

# repin has nothing to change on a starter host
$e = err_of(sub { $ob->repin($h1, { pin => 'nixos-26.05.20261109' }) });
is($e && $e->kind, 'refused', 'repin of a starter host is refused');
like($e && $e->message, qr/stock starter/, 'repin says the host boots the stock starter');

# a built-image assign is as before
$r = $ob->assign($h3, { type => 'SCH,TCH', profile => 'CONVERGED', os => 'x86_64:nixos:26.05', pin => 'nixos-26.05.20261109' });
is($reg->host_get('525400000103', 'system_pin'), 'nixos-26.05.20261109', 'CONVERGED assign still pins');

done_testing;
