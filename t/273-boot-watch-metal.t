#!/usr/bin/env perl
# Layer 2 (docs/BOOT-RELIABILITY.md): HPS::BootWatch on a metal node the IPS powered on
# through its BMC (host key bmc_power_on_at, written by HPS::BMC on on and reset),
# and the BMC record itself.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use HPS::Registry;
use HPS::Issues;
use HPS::BMC;
use HPS::BootWatch;

my $T = 1_800_000_000;
my $clock = sub { $T };
my $MAC = 'aabbccddee01';

package FakeBMC {
    sub new { my ($c, %o) = @_; return bless { calls => [], rc => $o{rc} || {}, reg => $o{reg}, now => $o{now} }, $c }
    sub run {
        my ($s, $mac, $action) = @_;
        push @{ $s->{calls} }, $action;
        my $rc = $s->{rc}{$action} // 0;
        $s->{reg}->host_set($mac, 'bmc_power_on_at', $s->{now}->()) if !$rc && ($action eq 'reset' || $action eq 'on');
        return { rc => $rc, stdout => '', stderr => '' };
    }
}

sub fixture {
    my (%o) = @_;
    my $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
    $reg->host_set($MAC, 'HOSTNAME', 'tch-001');
    $reg->host_set($MAC, 'bmc_power_on_at', $T) unless $o{no_power_on};
    my $bmc = FakeBMC->new(reg => $reg, now => $clock, rc => $o{rc});
    my @log;
    my $issues = HPS::Issues->new(registry => $reg, now => $clock, logger => sub { });
    my $bw = HPS::BootWatch->new(registry => $reg, issues => $issues, bmc => $bmc, now => $clock, ready => sub { 'ready' },
        logger => sub { push @log, "$_[0] $_[1]" }, settings => { window => 180, max => 2, metal => ($o{metal} // 0), warnings => [] });
    return { reg => $reg, bmc => $bmc, issues => $issues, bw => $bw, log => \@log };
}
sub tick_at { my ($f, $dt) = @_; $T += $dt; return $f->{bw}->tick }
sub issues_of { my ($f, $kind) = @_; return grep { $_->{kind} eq $kind } $f->{issues}->list }

#=== metal reset off (the default): detect and report, never touch the node
{
    my $f = fixture();
    is(tick_at($f, 100), 0, 'within the window: nothing');
    is(tick_at($f, 100), 1, 'past it: acted on');
    is_deeply($f->{bmc}{calls}, [], 'the BMC is not touched');
    my ($i) = issues_of($f, 'boot-stalled');
    ok($i, 'a boot-stalled issue is open');
    is_deeply($i->{fields}, { host => 'tch-001' }, 'naming the node (the register keeps the short name)');
    like($i->{summary}, qr/node tch-001\.hps\.test did not reach iPXE.*hps-bmc console tch-001\.hps\.test/, 'and the console hint');
    like($i->{trail}[0]{detail}, qr/automatic reset is off for this node/, 'saying why it did not reset');
    tick_at($f, 100);
    is(scalar(issues_of($f, 'boot-stalled')), 1, 'once');
    $f->{reg}->host_set($MAC, 'last_boot_at', $T);
    tick_at($f, 20);
    is($f->{issues}->get($i->{id})->{state}, 'resolved', 'the node netboots: resolved');
    ok(!$f->{reg}->host_exists($MAC, 'boot_watch'), 'state cleared');
}

#=== metal reset on: BMC reset up to the limit, then the issue
{
    my $f = fixture(metal => 1);
    is(tick_at($f, 200), 1, 'stalled: a BMC reset');
    is_deeply($f->{bmc}{calls}, ['reset'], 'the call is reset');
    my $w = $f->{reg}->host_get_json($MAC, 'boot_watch');
    is($w->{tries}, 1, 'one try recorded on the host');
    is($w->{expect}, $f->{reg}->host_get($MAC, 'bmc_power_on_at'), 'tied to the new power-on time');
    is(tick_at($f, 100), 0, 'inside the window after the reset: nothing');
    is(tick_at($f, 100), 1, 'a window later: reset 2');
    is_deeply($f->{bmc}{calls}, [ 'reset', 'reset' ], 'two resets');
    is(scalar(issues_of($f, 'boot-stalled')), 0, 'no issue yet');
    is(tick_at($f, 200), 1, 'at the limit: the issue');
    is_deeply($f->{bmc}{calls}, [ 'reset', 'reset' ], 'no third reset');
    like((issues_of($f, 'boot-stalled'))[0]{summary}, qr/2 reset\(s\) tried/, 'naming the tries');
}

#=== a reset that the BMC refuses falls back to power on, and a double failure gives up
{
    my $f = fixture(metal => 1, rc => { reset => 1 });
    tick_at($f, 200);
    is_deeply($f->{bmc}{calls}, [ 'reset', 'on' ], 'reset refused: power on');
    is($f->{reg}->host_get_json($MAC, 'boot_watch')->{tries}, 1, 'counted as one try');
    ok(!issues_of($f, 'boot-stalled'), 'no issue: the node was powered on');
    $f = fixture(metal => 1, rc => { reset => 1, on => 1 });
    tick_at($f, 200);
    my ($i) = issues_of($f, 'boot-stalled');
    ok($i, 'both refused: the issue at once');
    like($i->{trail}[0]{detail}, qr/BMC reset and power on failed: exit 1/, 'saying what failed');
}

#=== not watched, unreadable
{
    my $f = fixture(no_power_on => 1, metal => 1);
    is(tick_at($f, 1000), 0, 'a node with no recorded power-on (never powered by the IPS, or powered off): not watched');
    is_deeply($f->{bmc}{calls}, [], 'no call');
    $f = fixture(metal => 1);
    $f->{reg}->host_set($MAC, 'last_boot_at', 'junk');
    tick_at($f, 1000);
    is_deeply($f->{bmc}{calls}, [], 'unreadable last_boot_at: never a power cycle');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/tch-001\.hps\.test.*last_boot_at 'junk'/, 'reported');
    $f = fixture(metal => 1);
    $f->{reg}->host_set($MAC, 'bmc_power_on_at', 'yesterday');
    tick_at($f, 1000);
    is_deeply($f->{bmc}{calls}, [], 'unreadable power-on time: never a power cycle');
    like((issues_of($f, 'boot-watch-blind'))[0]{summary}, qr/no usable start time/, 'reported');
}

#=== the BMC record: on and reset set bmc_power_on_at, off clears it
{
    my $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set($MAC, 'HOSTNAME', 'tch-001');
    my $bmc = HPS::BMC->new(registry => $reg, logger => sub { });
    $bmc->_record($MAC, { action => 'status', rc => 0, status => { power => 'on' } });
    ok(!$reg->host_exists($MAC, 'bmc_power_on_at'), 'status does not set it');
    $bmc->_record($MAC, { action => 'on', rc => 1 });
    ok(!$reg->host_exists($MAC, 'bmc_power_on_at'), 'a failed on does not set it');
    $bmc->_record($MAC, { action => 'on', rc => 0 });
    ok($reg->host_get($MAC, 'bmc_power_on_at') =~ /\A[0-9]{10}\z/, 'on sets it to an epoch');
    $reg->host_set($MAC, 'bmc_power_on_at', 1);
    $bmc->_record($MAC, { action => 'reset', rc => 0 });
    cmp_ok($reg->host_get($MAC, 'bmc_power_on_at'), '>', 1_000_000_000, 'reset sets it again');
    $bmc->_record($MAC, { action => 'pxe-once', rc => 0 });
    ok($reg->host_exists($MAC, 'bmc_power_on_at'), 'pxe-once leaves it');
    $bmc->_record($MAC, { action => 'off', rc => 1 });
    ok($reg->host_exists($MAC, 'bmc_power_on_at'), 'a failed off leaves it');
    $bmc->_record($MAC, { action => 'off', rc => 0 });
    ok(!$reg->host_exists($MAC, 'bmc_power_on_at'), 'off clears it');
    $bmc->_record($MAC, { action => 'reset', rc => 0 });
    $bmc->_record($MAC, { action => 'force-off', rc => 0 });
    ok(!$reg->host_exists($MAC, 'bmc_power_on_at'), 'force-off clears it');
}

#=== a node powered on before the watch was enabled is baselined; an old-rules state is cleared
{
    my $f = fixture(metal => 1);
    $f->{bw}{enabled_at} = $T + 1000;
    is(tick_at($f, 5000), 0, 'powered on before the watch was enabled, never booted: not judged');
    is_deeply($f->{bmc}{calls}, [], 'the BMC is not touched');
    is(scalar(issues_of($f, 'boot-stalled')), 0, 'and no issue');
}
{
    my $f = fixture(metal => 1);
    $f->{reg}->host_set($MAC, 'boot_watch', { tries => 2, expect => $f->{reg}->host_get($MAC, 'bmc_power_on_at'), gave_up => 1 });
    is(tick_at($f, 20), 1, 'a boot_watch state without the rule-set marker: cleared');
    ok(!$f->{reg}->host_exists($MAC, 'boot_watch'), 'the host key is gone');
    ok((grep { /state=cleared/ } @{ $f->{log} }), 'with a clearing line');
}

done_testing;
