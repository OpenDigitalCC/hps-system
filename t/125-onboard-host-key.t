#!/usr/bin/env perl
# hps-onboard assign --host-key and set-key: the allowlist, refusals, written keys.
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
$reg->os_set('x86_64:nixos:26.05', 'kernel', 'bzImage');

my ($h1, $h2, $h3, $h4) = map { sprintf '52:54:00:00:01:%02x', $_ } 1 .. 4;
$reg->host_set($_, 'STATE', 'HELD') for ($h1, $h2, $h3);
$reg->host_set($h4, 'STATE', 'INSTALLED');

my $ob = HPS::Onboard->new(registry => $reg);
sub err_of { my ($code) = @_; eval { $code->(); 1 } and return; return ref $@ ? $@ : undef }
my %good = (type => 'TCH', profile => 'CONVERGED', os => 'x86_64:nixos:26.05', pin => 'nixos-26.05.20261109');

# assign
my $r = $ob->assign($h1, { %good, host_keys => ['boot_bridge=br-prov'] });
is($r->{state}, 'NETWORK_BOOT', 'assign with a host key succeeds');
is($reg->host_get($h1, 'boot_bridge'), 'br-prov', 'the key is written with the assignment');
is($reg->host_get($h1, 'STATE'), 'NETWORK_BOOT', 'state advanced');

$ob->assign($h2, {%good});
ok(!$reg->host_exists($h2, 'boot_bridge'), 'no --host-key writes no key');

for my $bad (
    [ 'ssh_key=x',          qr/'ssh_key' is not settable here; allowed: boot_bridge/ ],
    [ 'STATE=HELD',         qr/'STATE' is not settable here/ ],
    [ 'boot_bridge=prov',   qr/boot_bridge: value 'prov' must be br-NAME/ ],
    [ 'boot_bridge=br-a_b', qr/must be br-NAME/ ],
    [ 'boot_bridge=br-0123456789abc', qr/must be br-NAME/ ],
    [ 'boot_bridge=',       qr/must be br-NAME/ ],
    [ 'boot_bridge',        qr/must be name=value/ ],
) {
    my $e = err_of(sub { $ob->assign($h3, { %good, host_keys => [ $bad->[0] ] }) });
    is($e && $e->kind, 'usage', "refused: $bad->[0]");
    like($e && $e->message, $bad->[1], '  specific message');
}
my $e = err_of(sub { $ob->assign($h3, { %good, host_keys => [ 'boot_bridge=br-a', 'boot_bridge=br-b' ] }) });
like($e && $e->message, qr/given twice/, 'a repeated key is refused');
is($reg->host_get($h3, 'STATE'), 'HELD', 'a refused assign leaves the host HELD');
ok(!$reg->host_exists($h3, 'TYPE'), 'and writes nothing');
$e = err_of(sub { $ob->assign($h3, { %good, host_keys => ['bogus=1'] }) });
is($e && $e->kind, 'usage', 'an unknown key is refused even with everything else valid');

# set-key
$r = $ob->set_key($h4, ['boot_bridge=br-prov']);
is($reg->host_get($h4, 'boot_bridge'), 'br-prov', 'set-key writes the key on an assigned host');
like($r->{notes}[0], qr/reboot the node/, 'the note says a reboot is needed');
$e = err_of(sub { $ob->set_key($h4, ['foo=bar']) });
is($e && $e->kind, 'usage', 'set-key: same allowlist');
$e = err_of(sub { $ob->set_key($h4, []) });
like($e && $e->message, qr/at least one/, 'set-key needs a key');
$e = err_of(sub { $ob->set_key('52:54:00:99:99:99', ['boot_bridge=br-prov']) });
is($e && $e->kind, 'notfound', 'set-key: unknown host');

# show prints the key
my $s = $ob->show($h1);
is($s->{identity}{boot_bridge}, 'br-prov', 'show carries the host key');

# CLI
sub run_cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-onboard", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}
$reg->host_set($h3, 'STATE', 'HELD');
my ($rc, $out) = run_cli('assign', $h3, qw(--type TCH --profile CONVERGED --os x86_64:nixos:26.05 --pin nixos-26.05.20261109 --host-key boot_bridge=br-prov));
is($rc, 0, 'CLI assign --host-key exits 0') or diag $out;
is($reg->host_get($h3, 'boot_bridge'), 'br-prov', 'CLI wrote the key');
($rc, $out) = run_cli('show', $h3);
like($out, qr/boot_bridge: br-prov/, 'CLI show prints the host key');
($rc, $out) = run_cli('set-key', $h4, '--host-key', 'boot_bridge=br-lab');
is($rc, 0, 'CLI set-key exits 0');
like($out, qr/boot_bridge=br-lab/, 'CLI names the key set');
like($out, qr/reboot the node for it to take effect/, 'CLI prints the reboot note');
($rc, $out) = run_cli('set-key', $h4, '--host-key', 'x=y');
is($rc, 2, 'CLI refuses a key outside the allowlist with exit 2');
like($out, qr/not settable here/, 'CLI shows the refusal');
($rc) = run_cli('set-key', $h4);
is($rc, 2, 'set-key without a key is a usage error');

done_testing;
