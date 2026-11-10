#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Node;

# A scripted BMC: statuses are consumed in order (the last one repeats); every
# call is recorded.
package FakeBmc {
    sub new { my ($c, %o) = @_; return bless { status => $o{status} || ['off'], rc => $o{rc} || {}, calls => [], missing => $o{missing} }, $c }
    sub run {
        my ($s, $action, $host, @x) = @_;
        push @{ $s->{calls} }, join ' ', $action, $host, @x;
        return { rc => 127, stdout => '', stderr => '', missing => 1 } if $s->{missing};
        my $rc = $s->{rc}{$action} // 0;
        return { rc => $rc, stdout => '', stderr => '', missing => 0 } if $rc;
        if ($action eq 'status') {
            my $p = @{ $s->{status} } > 1 ? shift @{ $s->{status} } : $s->{status}[0];
            return { rc => 0, stdout => qq({"power":"$p"}\n), stderr => '', missing => 0 };
        }
        return { rc => 0, stdout => '', stderr => '', missing => 0 };
    }
    sub calls { return @{ $_[0]{calls} } }
}

my $mac = $StorageFixture::MAC;
sub res { return JSON::PP::decode_json($_[0]{reg}->host_get($mac, "poweroff_last"))->{result} }

sub node {
    my (%o) = @_;
    my $f = StorageFixture::setup(ce => $o{ce});
    my $bmc = $o{bmc} // FakeBmc->new;
    my $clock = 1_800_000_000;
    my @log;
    my $storage = $f->{mk}->();
    my $n = HPS::Node->new(host => 'sch-001', registry => $f->{reg}, storage => $storage, runner => $f->{ce},
        bmc => $bmc, logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $clock }, sleep => sub { $clock += $_[0] }, poll => 5);
    return ($n, $f, $bmc, \@log);
}

# --- clean path: storage down, node-poweroff, BMC says off
{
    my ($n, $f, $bmc, $log) = node(bmc => FakeBmc->new(status => [ 'on', 'on', 'off' ]));
    my $r = $n->power_off;
    is($r->{result}, 'off', 'clean path: off');
    is(join(',', $f->{ce}->scripts), 'node-poweroff', 'node-poweroff is called');
    is($f->{reg}->host_get($mac, 'storage_state'), 'down', 'storage down was run first (state recorded)');
    is(scalar(grep { /^force-off/ } $bmc->calls), 0, 'no force-off when the node goes off in time');
    is(scalar(grep { /^status sch-001 --json/ } $bmc->calls), 3, 'polled until off');
    is(res($f), 'off', 'outcome recorded');
}

# --- order: storage down (iscsi-unexport) before node-poweroff
{
    my ($n, $f) = node();
    $f->{reg}->host_set($mac, 'storage_exports', [ { zvol => 'lab/enc/vm/a', iqn => 'iqn.2026-11.hps.lab:a', initiator => 'iqn.2026-11.hps:x', portal => '192.0.2.5' } ]);
    $n->power_off;
    is(join(',', $f->{ce}->scripts), 'iscsi-unexport,node-poweroff', 'storage down runs before the node script');
}

# --- storage down fails: nothing is powered off
{
    my ($n, $f, $bmc, $log) = node(ce => { rc => { 'iscsi-unexport' => 1 } });
    $f->{reg}->host_set($mac, 'storage_exports', [ { zvol => 'lab/enc/vm/a', iqn => 'iqn.2026-11.hps.lab:a', initiator => 'iqn.2026-11.hps:x', portal => '192.0.2.5' } ]);
    my $r = $n->power_off;
    is($r->{result}, 'failed', 'storage failure: failed');
    like($r->{message}, qr/storage down failed/, 'says which step');
    is(join(',', $f->{ce}->scripts), 'iscsi-unexport', 'node-poweroff not called');
    is(scalar($bmc->calls), 0, 'the BMC is not touched');
    is(res($f), 'failed', 'recorded as failed');
}

# --- node-poweroff fails
{
    my ($n, $f, $bmc) = node(ce => { rc => { 'node-poweroff' => 1 } });
    my $r = $n->power_off;
    is($r->{result}, 'failed', 'node script failure: failed');
    like($r->{message}, qr/node-poweroff exited 1/, 'says so');
    is(scalar($bmc->calls), 0, 'no BMC call, no force');
}

# --- force path: never reports off; force-off only after force_after
{
    my ($n, $f, $bmc, $log) = node(bmc => FakeBmc->new(status => ['on']));
    my $r = $n->power_off(force_after => 20);
    is($r->{result}, 'forced', 'force path: forced');
    my @c = $bmc->calls;
    is($c[-1] // '', 'status sch-001 --json', 'status checked once more after the force-off');
    is((grep { /^force-off sch-001$/ } @c), 1, 'force-off sent once');
    my @status_before = grep { /^status/ } @c[ 0 .. ((grep { $c[$_] =~ /^force-off/ } 0 .. $#c)[0] - 1) ];
    cmp_ok(scalar(@status_before), '>=', 4, 'it waited (polling at 5 s up to 20 s) before forcing');
    ok((grep { /^error .*FAULT .*forcing/ } @$log), 'the force is logged as a fault');
    is(res($f), 'forced', 'recorded as forced');
}

# --- force-off fails
{
    my ($n, $f, $bmc) = node(bmc => FakeBmc->new(status => ['on'], rc => { 'force-off' => 4 }));
    my $r = $n->power_off(force_after => 5);
    is($r->{result}, 'failed', 'force-off failure: failed');
    like($r->{message}, qr/force-off failed/, 'says so');
}

# --- BMC unreachable at status: polled as unknown, then forced after the wait
{
    my ($n, $f, $bmc) = node(bmc => FakeBmc->new(rc => { status => 4 }));
    my $r = $n->power_off(force_after => 10);
    is($r->{result}, 'forced', 'unreachable BMC is not the no-BMC path: waits, then tries force-off');
}

# --- no BMC: command missing, and exit 5
for my $case ([ 'command missing', FakeBmc->new(missing => 1) ], [ 'exit 5', FakeBmc->new(rc => { status => 5 }) ]) {
    my ($label, $bmc) = @$case;
    my ($n, $f, undef, $log) = node(bmc => $bmc);
    my $r = $n->power_off;
    is($r->{result}, 'no-bmc', "no BMC driver ($label): stops after the node script");
    like($r->{message}, qr/not confirmed/, 'reports that power state is not confirmed');
    is(join(',', $f->{ce}->scripts), 'node-poweroff', 'node script was still called');
    is(scalar(grep { /^force-off/ } $bmc->calls), 0, 'never forces without a driver');
    is(res($f), 'no-bmc', 'recorded');
}

# --- the real BMC command wrapper: missing command, and a shim
{
    my $tmp = tempdir(CLEANUP => 1);
    my $b = HPS::Node::Bmc->new(cmd => "$tmp/nope");
    my $r = $b->run('status', 'h', '--json');
    ok($r->{missing}, 'a command that does not exist is reported missing');
    open(my $s, '>', "$tmp/bmc") or die;
    print {$s} qq(#!/bin/sh\necho "\$*" >> "$tmp/log"\necho '{"power":"off"}'\nexit 0\n);
    close $s;
    chmod 0755, "$tmp/bmc";
    $r = HPS::Node::Bmc->new(cmd => "$tmp/bmc")->run('status', 'h', '--json');
    is($r->{rc}, 0, 'shim runs');
    like($r->{stdout}, qr/"power":"off"/, 'stdout captured');
}

# --- the CLI end to end: hps-run shim, hps-bmc shim (HPS_BMC_CMD)
{
    my $fx  = StorageFixture::setup();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    open(my $s, '>', "$tmp/bmc") or die;
    print {$s} <<'BMC';
#!/usr/bin/env bash
echo "$*" >> "$SHIM_DIR/bmc"
case "$1" in
  status) [[ "${FAKE_BMC_RC:-0}" -eq 0 ]] || exit "$FAKE_BMC_RC"; echo "{\"power\":\"${FAKE_POWER:-off}\"}" ;;
esac
exit 0
BMC
    close $s;
    chmod 0755, "$tmp/bmc";
    local $ENV{HPS_CONFIG_BASE}     = $fx->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$fx->{base}/system.db";
    local $ENV{HPS_RUN_CMD}         = "$tmp/hps-run";
    local $ENV{HPS_BMC_CMD}         = "$tmp/bmc";
    local $ENV{HPS_NODE_NO_SYSLOG}  = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG} = 1;
    local $ENV{HPS_NODE_POLL}       = 0;
    local $ENV{SHIM_DIR}            = $tmp;
    my $run = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-node", @_);
        my $out = qx(@cmd 2>&1);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $run->();
    is($rc, 2, 'cli: no arguments: usage');
    ($rc, $out) = $run->('reboot', 'sch-001');
    is($rc, 2, 'cli: unknown operation: usage');
    ($rc, $out) = $run->('power-off', 'sch-001', '--force-after', '-3');
    is($rc, 2, 'cli: negative --force-after: usage');
    ($rc, $out) = $run->('power-off', 'no-such-host');
    is($rc, 4, 'cli: unknown host: not found');
    ($rc, $out) = $run->('power-off', 'sch-001');
    is($rc, 0, 'cli: power-off, BMC reports off: 0');
    like($out, qr/node is off/, 'cli: says off');
    open(my $a, '<', "$tmp/args") or die;
    my @args = <$a>;
    like(join('', @args), qr/node-poweroff/, 'cli: node-poweroff went through hps-run');
    local $ENV{FAKE_POWER} = 'on';
    ($rc, $out) = $run->('power-off', 'sch-001', '--force-after', '0');
    is($rc, 6, 'cli: never off: forced, exit 6');
    like($out, qr/FAULT/, 'cli: fault is logged');
    open(my $b, '<', "$tmp/bmc") or die;
    like(join('', <$b>), qr/^force-off sch-001$/m, 'cli: force-off sent to the BMC command');
    local $ENV{HPS_BMC_CMD} = "$tmp/no-such-bmc";
    ($rc, $out) = $run->('power-off', 'sch-001');
    is($rc, 0, 'cli: no BMC driver: 0');
    like($out, qr/not confirmed/, 'cli: says power state not confirmed');
    local $ENV{FAKE_NODE_EXIT} = 1;
    ($rc, $out) = $run->('power-off', 'sch-001');
    is($rc, 1, 'cli: node script fails: 1');
}

done_testing;
