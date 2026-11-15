#!/usr/bin/env perl
# Layer 3 (docs/BOOT-RELIABILITY.md): the CLIs of the readiness check - hps-boot-ready and
# hps-ips-check --boot-ready (exit 0 ready, 1 not ready, 3 cannot tell, 2 usage) and the gate
# of hps-bmc on and pxe-once (exit 3, --no-boot-wait).
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use BootFixture;

my ($http, $pid) = BootFixture::http_server(200, "hps.test\n");
END { kill 'TERM', $pid if $pid }

sub env_for {
    my ($f, %o) = @_;
    return (HPS_CONFIG_BASE => $f->{dir}, HPS_SYSTEM_REGISTRY => "$f->{dir}/system.db", HPS_BOOT_READY_PROC => $f->{proc},
        HPS_BOOT_READY_UDP => $f->{udp}, HPS_BOOT_READY_HTTP => ($o{http} // $http), HPS_BOOT_READY_SKIP => '');
}

# run_cli(\%env, @cmd): (exit code, stdout, stderr)
sub run_cli {
    my ($env, @cmd) = @_;
    local @ENV{ keys %$env } = values %$env;
    delete $ENV{HPS_BOOT_READY_SKIP};
    my $out = qx(@cmd 2>/tmp/br-t274-$$.err);
    my $rc = $? >> 8;
    open(my $h, '<', "/tmp/br-t274-$$.err") or die;
    local $/;
    my $err = <$h>;
    close $h;
    unlink "/tmp/br-t274-$$.err";
    return ($rc, $out, $err);
}

my $BIN = "$Bin/../bin";
my @perl = ($^X, "-I$Bin/../lib/perl");

for my $tool ([ 'hps-boot-ready', "$BIN/hps-boot-ready" ], [ 'hps-ips-check --boot-ready', "$BIN/hps-ips-check", '--boot-ready' ]) {
    my ($label, @cmd) = @$tool;
    @cmd = (@perl, @cmd) if $label eq 'hps-boot-ready';
    my $f = BootFixture::make();
    my %env = env_for($f);
    my ($rc, $out, $err) = run_cli(\%env, @cmd);
    is($rc, 0, "$label: ready is exit 0") or diag "$out$err";
    like($out, qr/^PASS dnsmasq:.*\nPASS dhcp:.*\nPASS tftp:.*\nPASS http:.*\nboot services: ready\n/, "$label: one line per check, then the verdict");

    ($rc, $out) = run_cli({ env_for($f), HPS_BOOT_READY_PROC => BootFixture::make(dnsmasq => 0)->{proc} }, @cmd);
    is($rc, 1, "$label: a failed check is exit 1");
    like($out, qr/^FAIL dnsmasq: dnsmasq is not running$/m, "$label: names what fails");
    like($out, qr/boot services: not_ready/, "$label: verdict not_ready");

    ($rc, $out) = run_cli({ env_for($f), HPS_BOOT_READY_UDP => '/no/such/udp' }, @cmd);
    is($rc, 3, "$label: nothing failed but a check could not be looked at is exit 3");
    like($out, qr/^UNKNOWN dhcp: cannot read/m, "$label: names what could not be looked at");

    ($rc, $out) = run_cli({ env_for($f), HPS_BOOT_READY_UDP => '/no/such/udp', HPS_BOOT_READY_PROC => BootFixture::make(dnsmasq => 0)->{proc} }, @cmd);
    is($rc, 1, "$label: a fail wins over cannot tell");

    ($rc, $out) = run_cli({ env_for($f, http => '127.0.0.1:9') }, @cmd);
    is($rc, 1, "$label: nothing answers over HTTP: exit 1");
    like($out, qr/^FAIL http: no HTTP answer from/m, "$label: names the url");

    ($rc, $out) = run_cli({ env_for($f) }, @cmd, '--json');
    is($rc, 0, "$label: --json, ready");
    my $j = eval { decode_json($out) };
    is($j->{verdict}, 'ready', "$label: --json carries the verdict");
    is(scalar @{ $j->{checks} }, 4, "$label: and the four checks");

    my $t0 = time;
    ($rc) = run_cli({ env_for($f), HPS_BOOT_READY_PROC => BootFixture::make(dnsmasq => 0)->{proc} }, @cmd, '--wait', '2');
    is($rc, 1, "$label: --wait 2 on a service that never comes up: exit 1");
    cmp_ok(time - $t0, '>=', 1, "$label: and it did wait");
    ($rc, $out, $err) = run_cli({ env_for($f) }, @cmd, '--wait', 'x');
    is($rc, 2, "$label: --wait x is usage (2)");
}

{
    my ($rc, $out, $err) = run_cli({ env_for(BootFixture::make()) }, @perl, "$BIN/hps-boot-ready", '--bogus');
    is($rc, 2, 'hps-boot-ready: an unknown option is usage (2)');
    like($err, qr/Usage: hps-boot-ready/, 'and prints the usage');
    ($rc) = run_cli({ env_for(BootFixture::make()) }, @perl, "$BIN/hps-boot-ready", 'extra');
    is($rc, 2, 'hps-boot-ready: an argument is usage (2)');
    ($rc) = run_cli({ env_for(BootFixture::make()) }, @perl, "$BIN/hps-boot-ready", '--wait', '601');
    is($rc, 2, 'hps-boot-ready: --wait 601 is usage (2)');
    ($rc, $out, $err) = run_cli({ env_for(BootFixture::make()) }, 'bash', "$BIN/hps-ips-check", '--boot-ready', '--bogus');
    is($rc, 2, 'hps-ips-check: an unknown option is usage (2)');
}

#=== the hps-bmc gate
{
    my $f = BootFixture::make(dnsmasq => 0);
    $f->{reg}->cluster_set('lab', 'boot_ready_wait_seconds', '0');
    my %env = env_for($f);
    my @bmc = (@perl, "$BIN/hps-bmc");
    for my $action (qw(on pxe-once)) {
        my ($rc, $out, $err) = run_cli(\%env, @bmc, $action, 'aa:bb:cc:dd:ee:01');
        is($rc, 3, "hps-bmc $action with the boot services down: refused (3)");
        like($err, qr/hps-bmc: refused: this IPS's boot services do not answer after 0 s \(dnsmasq: dnsmasq is not running\)/, "hps-bmc $action: names what does not answer");
        ($rc, $out, $err) = run_cli(\%env, @bmc, $action, 'aa:bb:cc:dd:ee:01', '--no-boot-wait');
        is($rc, 1, "hps-bmc $action --no-boot-wait: the gate is skipped (the host is not in the registry: 1)");
        like($err, qr/No such host/, "hps-bmc $action --no-boot-wait: it got as far as the host lookup");
    }
    for my $action (qw(status off reset)) {
        my ($rc, $out, $err) = run_cli(\%env, @bmc, $action, 'aa:bb:cc:dd:ee:01');
        is($rc, 1, "hps-bmc $action is not gated (host lookup fails: 1)");
        like($err, qr/No such host/, "hps-bmc $action: no refusal about boot services");
    }
    my ($rc, $out, $err) = run_cli(\%env, @bmc, 'off', 'aa:bb:cc:dd:ee:01', '--no-boot-wait');
    is($rc, 2, 'hps-bmc off --no-boot-wait: usage (2)');
    my $ok = BootFixture::make();
    ($rc, $out, $err) = run_cli({ env_for($ok) }, @bmc, 'on', 'aa:bb:cc:dd:ee:01');
    is($rc, 1, 'hps-bmc on with the boot services answering: through the gate to the host lookup (1)');
    like($err, qr/No such host/, 'and says so');
}

done_testing;
