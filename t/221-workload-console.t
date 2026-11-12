#!/usr/bin/env perl
# hps-workload console <workload> [--vm <vm>] [--lines N]: vm-console-log on
# each VM's compute host, read-only (the scale board reads the probes' lines
# through it, over the operator API).
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

sub err_of {
    my ($code) = @_;
    return eval { $code->(); 1 } ? undef : $@;
}

ok(scalar(grep { $_ eq 'console' } HPS::Workload::ops()), 'console is an op');

#--- the driver
{
    my $f = StorageFixture::setup_workload(ce => { out => {
        'vm-console-log' => "boot\r\n\e[1mPROBE s1 tch-001 probe-tch-001 seq=7 disk_ok peers=3/3 isolated=yes\e[0m\r\n" } });
    my $wl = $f->{wl}->();
    my $e = err_of(sub { $wl->plan('console', 't0') });
    is($e && $e->kind, 'notfound', 'a workload never created: not found');
    ok($wl->run('create', 't0')->{ok}, 'create ok');
    $f->{ce}{calls} = [];

    my $plan = $wl->plan('console', 't0');
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } @$plan ],
        [ [ 'vm-console-log', 't0-db' ], [ 'vm-console-log', 't0-app' ] ], 'one vm-console-log per VM, start order, no options');
    $plan = $wl->plan('console', 't0', vm => 't0-app', lines => 20);
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } @$plan ], [ [ 'vm-console-log', 't0-app', '--lines', 20 ] ],
        '--vm and --lines narrow it');
    is(err_of(sub { $wl->plan('console', 't0', lines => 0) })->kind, 'usage', '--lines 0: usage');
    is(err_of(sub { $wl->plan('console', 't0', lines => 'x') })->kind, 'usage', '--lines x: usage');
    is(err_of(sub { $wl->plan('status', 't0', lines => 5) })->kind, 'usage', '--lines on another op: usage');
    is(err_of(sub { $wl->plan('console', 't0', vm => 'ghost') })->kind, 'notfound', 'an unknown --vm: not found');

    my $r = $wl->run('console', 't0', vm => 't0-app', lines => 20);
    is($r->{rc}, 0, 'rc 0');
    is(scalar @{ $r->{vms} }, 1, 'one VM');
    is($r->{vms}[0]{host}, 'sch-001', 'with its compute host');
    is($r->{vms}[0]{log}, "boot\nPROBE s1 tch-001 probe-tch-001 seq=7 disk_ok peers=3/3 isolated=yes\n",
        'the log, without carriage returns and escape sequences');
    ok(!exists $r->{steps}, 'the node steps are not repeated in the result');
    my @scripts = $f->{ce}->scripts;
    is_deeply(\@scripts, ['vm-console-log'], 'the only node call is vm-console-log (read-only)');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t0');
    is($rec->{state}, 'created', 'the record is unchanged');

    $f->{ce}{rc}{'vm-console-log'} = [ 4, 0 ];
    $r = $wl->run('console', 't0');
    is($r->{rc}, 1, 'one VM of two without a log: rc 1');
    is($r->{vms}[0]{rc}, 4, 'that VM says 4');
    is($r->{vms}[1]{rc}, 0, 'the other is still read');
    like($r->{vms}[0]{error}, qr/boom from vm-console-log/, 'with the node\'s last error line');
    $f->{ce}{rc}{'vm-console-log'} = 4;
    $r = $wl->run('console', 't0', vm => 't0-db');
    is($r->{rc}, 4, 'the one VM asked for has no log: rc 4');
}

#--- creating: console is read-only, so it works on an unfinished create too
{
    my $f = StorageFixture::setup_workload(ce => { rc => { 'vm-define' => 1 } });
    my $wl = $f->{wl}->();
    ok(err_of(sub { $wl->run('create', 't0') }), 'create stops');
    my $r = $wl->run('console', 't0', vm => 't0-db');
    is($r->{rc}, 0, 'console of a creating workload works');
}

#--- the CLI
{
    $StorageFixture::NOW = time;
    my $f = StorageFixture::setup_workload();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}            = "$tmp/hps-run";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{HPS_STORAGE_NO_SYSLOG}  = 1;
    local $ENV{SHIM_DIR}               = $tmp;
    local $ENV{SUDO_USER}              = 'tester';
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_);
        my $out = qx(@cmd 2>$tmp/stderr);
        my $rc = $? >> 8;
        open(my $e, '<', "$tmp/stderr") or die;
        local $/;
        return ($rc, $out, <$e> // '');
    };
    my ($rc) = $cli->('create', 't0');
    is($rc, 0, 'cli: create');
    unlink "$tmp/args";
    my ($out, $err);
    ($rc, $out) = $cli->('console', 't0', '--vm', 't0-app', '--lines', '20');
    is($rc, 0, 'cli: console --vm exits 0');
    is($out, "node says hi\n", 'cli: --vm prints the log alone');
    open(my $a, '<', "$tmp/args") or die;
    my @args = <$a>;
    close $a;
    like($args[0], qr/^--json \S+ vm-console-log t0-app --lines 20$/, 'cli: vm-console-log t0-app --lines 20, no input');
    ($rc, $out) = $cli->('console', 't0');
    is($rc, 0, 'cli: console of every VM');
    like($out, qr/^== t0-db on sch-001\nnode says hi\n== t0-app on sch-001\nnode says hi\n\z/, 'cli: each log under its heading');
    ($rc, $out) = $cli->('console', 't0', '--json');
    is(decode_json($out)->{vms}[0]{log}, "node says hi\n", 'cli: --json');
    local $ENV{FAKE_NODE_EXIT} = 4;
    ($rc, $out, $err) = $cli->('console', 't0', '--vm', 't0-app');
    is($rc, 4, 'cli: no log for the VM: exit 4');
    like($err, qr/console t0: t0-app on sch-001: node complains/, 'cli: says why on stderr');
    delete $ENV{FAKE_NODE_EXIT};
    ($rc) = $cli->('console', 't0', '--lines', '0');
    is($rc, 2, 'cli: --lines 0: usage');
    ($rc) = $cli->('status', 't0', '--lines', '5');
    is($rc, 2, 'cli: --lines on status: usage');
    ($rc, $out) = $cli->('console', 't0', '--dry-run');
    is($rc, 0, 'cli: console --dry-run');
    like($out, qr/vm-console-log t0-app/, 'cli: dry run lists the calls');
}

done_testing;
