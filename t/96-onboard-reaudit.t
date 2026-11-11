#!/usr/bin/env perl
# hps-onboard reaudit (IPS-14): marks a held host's audit stale; refusals.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
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

my ($held, $bare, $other) = ('52:54:00:00:00:01', '52:54:00:00:00:02', '52:54:00:00:00:03');
$reg->host_set($held, 'STATE', 'HELD');
$reg->host_set($held, 'audit', { schema => 'hps-audit/1' });
$reg->host_set($bare, 'STATE', 'HELD');
$reg->host_set($other, 'STATE', 'NETWORK_BOOT');

my $ob = HPS::Onboard->new(registry => $reg);
sub err_of { my ($code) = @_; eval { $code->(); 1 } and return; return ref $@ ? $@ : undef }

my $r = $ob->reaudit($held);
is($r->{mac}, '525400000001', 'reaudit returns the normalised MAC');
is($r->{had_audit}, 1, 'reports a stored audit');
is($reg->host_get($held, 'audit_stale'), 'true', 'audit_stale is set to true');
ok($reg->host_exists($held, 'audit'), 'the stored audit is kept');

is($ob->reaudit($bare)->{had_audit}, 0, 'a held host without an audit is accepted and reported');

my $e = err_of(sub { $ob->reaudit($other) });
is($e && $e->kind, 'refused', 'an assigned host is refused');
like($e->message, qr/NETWORK_BOOT/, 'the refusal names the state');
ok(!$reg->host_exists($other, 'audit_stale'), 'a refused host is untouched');
$e = err_of(sub { $ob->reaudit('52:54:00:99:99:99') });
is($e && $e->kind, 'notfound', 'unknown host');
$e = err_of(sub { $ob->reaudit('zz') });
is($e && $e->kind, 'usage', 'bad MAC');

# CLI
sub run_cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}
$reg->host_unset($held, 'audit_stale');
my ($rc, $out) = run_cli('reaudit', $held);
is($rc, 0, 'CLI reaudit exits 0');
like($out, qr/marked stale/, 'CLI says what happened');
is($reg->host_get($held, 'audit_stale'), 'true', 'CLI set the mark');
($rc) = run_cli('reaudit', $other);
is($rc, 3, 'CLI exits 3 for an assigned host');
($rc) = run_cli('reaudit');
is($rc, 2, 'CLI exits 2 without a MAC');

# assign moves the host out of HELD, so the hold path no longer applies
$reg->os_set('x86_64:nixos:26.05', 'kernel', 'bzImage');
$ob->assign($held, { type => 'TCH', profile => 'CONVERGED', os => 'x86_64:nixos:26.05', pin => 'nixos-26.05.20261109' });
is($reg->host_get($held, 'STATE'), 'NETWORK_BOOT', 'assign sets STATE=NETWORK_BOOT (the role boot path)');

done_testing;
