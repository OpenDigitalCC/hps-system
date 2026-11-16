#!/usr/bin/env perl
# hps-workload resume-paused (HPS::Workload; docs/WORKLOADS.md): a guest the
# hypervisor paused on a disk I/O error, resumed with vm-resume on its compute
# host. Not `resume` (vm-restore of a suspended guest). Proves: the op and its
# plan; no --vm: vm-status first and vm-resume only for the paused VMs, the others
# noted; --vm: vm-resume as asked, its refusal (3) the answer; --any-reason passed
# on; a suspended VM and a draining host refused; --any-reason only for this op;
# the record untouched; status shows the pause reason; and the CLI: usage,
# --dry-run, exit codes.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

$StorageFixture::NOW = time;
sub calls { my ($f) = @_; return [ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ] }
sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }

sub running {
    my %ce = @_;
    my $f = StorageFixture::setup_workload(ce => { out => { 'vm-define' => "VM x defined mac=52:54:00:aa:00:01\n" } });
    my $wl = $f->{wl}->();
    $wl->run('create', 't0');
    $wl->run('start', 't0');
    # the answers asked for apply from here on, not to the create and start above
    $f->{ce}{calls} = [];
    $f->{ce}{out}{$_} = $ce{out}{$_} for keys %{ $ce{out} // {} };
    $f->{ce}{rc}{$_} = $ce{rc}{$_} for keys %{ $ce{rc} // {} };
    return ($f, $wl);
}

ok(scalar(grep { $_ eq 'resume-paused' } HPS::Workload::ops()), 'resume-paused is an op');
ok(scalar(grep { $_ eq 'resume' } HPS::Workload::ops()), '... and resume still is another');

#--- the plan: both VMs, vm-status then a conditional vm-resume each
{
    my ($f, $wl) = running();
    my $plan = $wl->plan('resume-paused', 't0');
    is_deeply([ map { join ' ', $_->{script}, @{ $_->{args} } } @$plan ],
        [ 'vm-status t0-db', 'vm-resume t0-db', 'vm-status t0-app', 'vm-resume t0-app' ], 'plan: per VM, vm-status then vm-resume, in start order (priority 1 first)') or diag explain $plan;
    like($plan->[1]{only}, qr/only if vm-status reports t0-db paused/, 'the resume is conditional');
    $plan = $wl->plan('resume-paused', 't0', vm => 't0-db', any_reason => 1);
    is_deeply([ map { join ' ', $_->{script}, @{ $_->{args} } } @$plan ], ['vm-resume t0-db --any-reason'], 'with --vm: only vm-resume, with --any-reason passed on');
    is(scalar(() = $f->{ce}->calls), 0, 'planning sends nothing');
    my $r = $wl->run('resume-paused', 't0', dry_run => 1);
    ok($r->{dry_run}, 'dry run');
    is(scalar(() = $f->{ce}->calls), 0, 'a dry run sends nothing');
}

#--- no --vm: only the paused VM is resumed; the other is noted
{
    my ($f, $wl) = running(out => { 'vm-status' => [ "PAUSED t0-db reason=ioerror\nVM t0-db paused\n", "VM t0-app running\n" ], 'vm-resume' => "VM t0-db running\n" });
    my $r = $wl->run('resume-paused', 't0');
    ok($r->{ok}, 'ok');
    is_deeply(calls($f), [ [ 'vm-status', 't0-db' ], [ 'vm-resume', 't0-db' ], [ 'vm-status', 't0-app' ] ], 'vm-resume only for the paused VM') or diag explain calls($f);
    ok((grep { $_->{skipped} && $_->{script} eq 'vm-resume' } @{ $r->{steps} }), 'the other VM\'s resume is shown as skipped');
    is_deeply($r->{notes}, ['VM t0-app is running, not paused: not resumed'], 'and noted');
    is(rec($f)->{vms}{'t0-app'}{state}, 'running', 'the record is as it was (running)');
}
{
    my ($f, $wl) = running(out => { 'vm-status' => "VM x running\n" });
    my $r = $wl->run('resume-paused', 't0');
    ok($r->{ok}, 'nothing paused: ok, nothing resumed');
    is(scalar(grep { $_->[0] eq 'vm-resume' } @{ calls($f) }), 0, 'no vm-resume call');
    is(scalar @{ $r->{notes} }, 2, 'a note for each VM');
}
{
    my ($f, $wl) = running(rc => { 'vm-status' => [ 4, 0 ] }, out => { 'vm-status' => [ "", "VM t0-app running\n" ] });
    my $r = $wl->run('resume-paused', 't0');
    ok($r->{ok}, 'a VM the host does not have defined (vm-status 4) does not stop the others');
    like($r->{notes}[0], qr/VM t0-db is not defined, not paused/, 'noted');
}

#--- --vm: vm-resume as asked; its refusal is the answer
{
    my ($f, $wl) = running(rc => { 'vm-resume' => 3 }, out => { 'vm-resume' => "REFUSED disk mirror t0-db-root is clean, failed\n" });
    my $e = eval { $wl->run('resume-paused', 't0', vm => 't0-db'); undef } // $@;
    ok(ref $e && $e->isa('HPS::Keysafe::Error'), 'a refusing node dies with an error');
    is($e->kind, 'refused', 'refused (exit 3 of the CLI)');
    like($e->message, qr/resume-paused: step 1\/1 vm-resume exited 3/, 'names the step');
    is_deeply(calls($f), [ [ 'vm-resume', 't0-db' ] ], 'only the vm-resume call');
    ok((grep { /kind=workload subject=t0 state=refused / } @{ $f->{log} }), 'a refused event line');
}
{
    my ($f, $wl) = running(out => { 'vm-resume' => "VM t0-db running\n" });
    my $r = $wl->run('resume-paused', 't0', vm => 't0-db', any_reason => 1);
    ok($r->{ok}, 'ok');
    is_deeply(calls($f), [ [ 'vm-resume', 't0-db', '--any-reason' ] ], '--any-reason reaches the node script');
    ok((grep { /kind=workload subject=t0 state=done .*resume-paused t0 ok/ } @{ $f->{log} }), 'a done event line');
}
{
    my ($f, $wl) = running();
    my $e = eval { $wl->run('resume-paused', 't0', vm => 'nosuch'); undef } // $@;
    ok(ref $e, 'an unknown VM is an error');
    is(scalar(() = $f->{ce}->calls), 0, 'nothing sent');
    $e = eval { $wl->run('start', 't0', any_reason => 1); undef } // $@;
    is($e->kind, 'usage', '--any-reason on another op: usage');
    like($e->message, qr/--any-reason is only for resume-paused/, 'says so');
}

#--- refusals as for start and resume
{
    my ($f, $wl) = running();
    $f->{reg}->cluster_set('lab', 'workload_t0', do { my $r = rec($f); $r->{vms}{'t0-app'}{state} = 'suspended'; $r->{vms}{'t0-app'}{state_file} = '/lab/enc/state/t0-app.save'; $r });
    my $e = eval { $wl->run('resume-paused', 't0'); undef } // $@;
    is($e->kind, 'refused', 'a suspended VM is refused');
    like($e->message, qr/resume-paused: VM t0-app is suspended .*run resume/, 'and pointed to resume');
    is(scalar(() = $f->{ce}->calls), 0, 'nothing sent');
}
{
    my ($f, $wl) = running();
    $f->{reg}->host_set($StorageFixture::MAC, 'drain', '1');
    my $e = eval { $wl->run('resume-paused', 't0'); undef } // $@;
    is($e->kind, 'refused', 'a draining host is refused');
    like($e->message, qr/resume-paused: compute host sch-001 is draining/, 'and says why');
    my $e2 = eval { $wl->run('resume-paused', 'nosuchworkload'); undef } // $@;
    is($e2->kind, 'notfound', 'a workload never created: not found');
}

#--- status shows the pause reason
{
    my ($f, $wl) = running(out => { 'vm-status' => [ "VM t0-db running\n", "PAUSED t0-app reason=ioerror\nVM t0-app paused\n" ], 'mirror-status' => "MIRROR x clean\n" });
    my $r = $wl->run('status', 't0');
    my %v = map { $_->{vm} => $_ } @{ $r->{vms} };
    is($v{'t0-app'}{state}, 'paused', 'status: the node state stays paused (what a reader of it has always seen)');
    is($v{'t0-app'}{pause_reason}, 'ioerror', 'status: the reason, as a field');
    ok(!exists $v{'t0-db'}{pause_reason}, 'a running VM has none');
}
{
    my ($f, $wl) = running(out => { 'vm-status' => [ "VM t0-db running\n", "VM t0-app paused\n" ], 'mirror-status' => "MIRROR x clean\n" });
    my $r = $wl->run('status', 't0');
    my %v = map { $_->{vm} => $_ } @{ $r->{vms} };
    is($v{'t0-app'}{state}, 'paused', 'an older node image (no PAUSED line): paused');
    ok(!defined $v{'t0-app'}{pause_reason}, '... with no reason: unknown, not guessed');
}

#--- the CLI
{
    my $tmp = tempdir(CLEANUP => 1);
    my $f = StorageFixture::setup_workload();
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
        my $err = <$e>;
        return ($rc, $out . $err, $out);
    };
    my $args = sub { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () };
    my ($rc, $out) = $cli->('create', 't0');
    is($rc, 0, 'setup: create') or diag $out;
    $rc = ($cli->('start', 't0'))[0];
    unlink "$tmp/args";

    ($rc, $out) = $cli->('resume-paused');
    is($rc, 2, 'no name: usage');
    ($rc, $out) = $cli->('resume-paused', 't0', 'extra');
    is($rc, 2, 'extra argument: usage');
    ($rc, $out) = $cli->('start', 't0', '--any-reason');
    is($rc, 2, '--any-reason on start: usage');
    like($out, qr/--any-reason is only for resume-paused/, 'says so');
    ($rc, $out) = $cli->('resume-paused', 't0', '--force');
    is($rc, 2, '--force on resume-paused: usage');
    ($rc, $out) = $cli->('resume-paused', 't0', '--resume');
    is($rc, 2, '--resume on resume-paused: usage');
    ($rc, $out) = $cli->('drain', 'h1', '--any-reason');
    is($rc, 2, '--any-reason on drain: usage');
    is(scalar(() = $args->()), 0, 'usage errors send nothing');

    ($rc, $out) = $cli->('resume-paused', 't0', '--dry-run');
    is($rc, 0, '--dry-run: 0');
    like($out, qr/vm-status t0-app.*vm-resume t0-app.*only if vm-status reports t0-app paused/s, 'prints the plan');
    is(scalar(() = $args->()), 0, '--dry-run sends nothing');
    ($rc, $out) = $cli->('resume-paused', 't0', '--vm', 't0-app', '--any-reason', '--dry-run', '--json');
    is($rc, 0, '--dry-run --json: 0');
    is_deeply([ map { join ' ', $_->{script}, @{ $_->{args} } } @{ decode_json($out)->{plan} } ], ['vm-resume t0-app --any-reason'], 'the plan as JSON');

    ($rc, $out) = $cli->('resume-paused', 't0');
    is($rc, 0, 'a workload whose guests run: ok, nothing resumed') or diag $out;
    like($out, qr/note: VM t0-app is running, not paused: not resumed/, 'with the note');
    like($out, qr/resume-paused ok: workload t0/, 'and the usual last line');
    unlink "$tmp/args";
    ($rc, $out) = $cli->('resume-paused', 't0', '--vm', 't0-app');
    is($rc, 0, '--vm: vm-resume as asked');
    like(join('', $args->()), qr/vm-resume t0-app/, 'the node script was called');
    {
        local $ENV{FAKE_NODE_EXIT} = 3;
        ($rc, $out) = $cli->('resume-paused', 't0', '--vm', 't0-app');
        is($rc, 3, 'the node refuses (3): exit 3');
        like($out, qr/vm-resume exited 3/, 'and the message says which step');
    }
    {
        local $ENV{FAKE_NODE_EXIT} = 1;
        ($rc, $out) = $cli->('resume-paused', 't0', '--vm', 't0-app');
        is($rc, 1, 'the node fails (1): exit 1');
    }
    ($rc, $out) = $cli->('resume-paused', 'nosuch');
    is($rc, 4, 'an unknown workload: 4');

    # status: a paused guest is shown with its reason
    open(my $in, '<', "$tmp/hps-run") or die;
    my $shim = do { local $/; <$in> };
    close $in;
    $shim =~ s/vm-status\) out="VM \$\{3\} running" ;;/vm-status) out="PAUSED \${3} reason=ioerror\nVM \${3} paused" ;;/ or die 'shim has changed';
    open(my $o, '>', "$tmp/hps-run-paused") or die;
    print {$o} $shim;
    close $o;
    chmod 0755, "$tmp/hps-run-paused";
    local $ENV{HPS_RUN_CMD} = "$tmp/hps-run-paused";
    ($rc, $out) = $cli->('status', 't0', '--vm', 't0-app');
    like($out, qr/recorded running\s+node paused \(ioerror\)/, 'status: node paused (ioerror) in the text');
    (undef, undef, $out) = $cli->('status', 't0', '--vm', 't0-app', '--json');
    is(decode_json($out)->{vms}[0]{pause_reason}, 'ioerror', 'status --json: pause_reason');
}

done_testing;
