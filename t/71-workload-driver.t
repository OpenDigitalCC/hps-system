#!/usr/bin/env perl
# CS-3.6: HPS::Workload driver on a fake runner: plans, order of node calls,
# registry state after each operation, refusals, --resume, destroy approvals.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $MAC  = $StorageFixture::MAC;
my $SUM  = 'ab' x 32;
my $DB   = 'lab/enc/vm/t0-t0-db-root';
my $APP  = 'lab/enc/vm/t0-t0-app-root';

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }
sub script_list { my ($f) = @_; return map { "$_->{script}" } $f->{ce}->calls }
sub rec { my ($f, $n) = @_; return $f->{reg}->cluster_get_json('lab', "workload_$n") }
sub nodecalls { my ($f) = @_; return scalar(() = $f->{ce}->calls) }

my @CREATE_APP = ('storage-zvol-create', 'image-fetch', 'mirror-create', 'vm-image-write', 'net-bridge-ensure', 'vm-define');
my @CREATE_DB = ('storage-zvol-create', 'mirror-create', 'vm-image-write', 'net-bridge-ensure', 'vm-define');

#--- plan create
{
    my $f = StorageFixture::setup_workload();
    my $wl = $f->{wl}->();
    my $plan = $wl->plan('create', 't0');
    is_deeply([ map { $_->{script} } @$plan ], [ @CREATE_APP, @CREATE_DB ],
        'create plan: zvol, image once per host, mirror, write, bridge when the node lacks the network, define, per VM in definition order')
        or diag join ' ', map { $_->{script} } @$plan;
    my ($z) = @$plan;
    is_deeply($z->{args}, [ $APP, '20G' ], 'zvol dataset <pool>/enc/<workload>-<vm>-<disk> and size');
    is($z->{host}, $MAC, 'steps are addressed by MAC');
    is($z->{n}, 1, 'steps are numbered');
    is(nodecalls($f), 0, 'plan sends nothing');
    ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'plan records nothing');
    ok(!$f->{reg}->host_exists($MAC, 'nets'), 'plan does not attach networks');

    my %by = map { $_->{script} . ($_->{args}[0] // '') => $_ } @$plan;
    is_deeply($by{'mirror-createt0-app-root'}{args},
        [ 't0-app-root', '--leg', "local:$APP", '--leg', 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-root' ],
        'mirror-create: name <vm>-<disk>, local leg then iSCSI leg');
    is_deeply($by{'image-fetchdebian-13-generic-amd64'}{args},
        [ 'debian-13-generic-amd64', '--from', 'http://192.0.2.1/images/debian-13-generic-amd64.qcow2',
          '--sha256', $SUM, '--dest', '/lab/enc/images' ], 'image-fetch: IPS url, checksum from the IPS file, images dataset');
    is_deeply($by{'vm-image-writet0-app'}{args},
        [ 't0-app', '--disk', '/dev/md/t0-app-root', '--image', '/lab/enc/images/debian-13-generic-amd64.qcow2' ],
        'vm-image-write: base image onto the mirror');
    is_deeply($by{'vm-definet0-app'}{args},
        [ 't0-app', '--memory', 2048, '--vcpus', 2, '--disk', '/dev/md/t0-app-root', '--net', 'br-mgmt',
          '--image', '/lab/enc/images/debian-13-generic-amd64.qcow2' ], 'vm-define: sizes, disk, bridge per net, image');
    is_deeply([ @{ $by{'vm-definet0-db'}{args} }[ 7 .. 10 ] ], [ '--net', 'br-mgmt', '--net', 'br-db' ], 'vm-define: one --net per net in order');
}

#--- run create
my $f = StorageFixture::setup_workload();
{
    my $wl = $f->{wl}->();
    my $r = $wl->run('create', 't0');
    ok($r->{ok}, 'create ok');
    my @s = script_list($f);
    my @expect = (@CREATE_APP, @CREATE_DB);
    is_deeply(\@s, \@expect, 'node calls in plan order');
    for my $i (grep { $s[$_] eq 'net-bridge-ensure' } 0 .. $#s) {
        is($s[$i + 1], 'vm-define', 'net-bridge-ensure comes right before the vm-define that needs the bridge');
    }
    is_deeply($f->{reg}->host_get_json($MAC, 'nets'), [ 'mgmt', 'db' ], 'host nets key lists the attached networks');

    my $rec = rec($f, 't0');
    is($rec->{state}, 'created', 'registry: workload created');
    is($rec->{by}, 'tester', 'registry: by');
    like($rec->{created_at}, qr/UTC$/, 'registry: created_at');
    ok(!exists $rec->{done}, 'registry: progress list dropped when done');
    is($rec->{vms}{'t0-app'}{state}, 'defined', 'registry: vm defined');
    is($rec->{vms}{'t0-app'}{host}, 'sch-001', 'registry: vm host');
    is($rec->{vms}{'t0-app'}{disks}{root}{md}, '/dev/md/t0-app-root', 'registry: md device');
    is_deeply($rec->{vms}{'t0-app'}{disks}{root}{legs},
        [ "local:$APP", 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-root' ], 'registry: legs');

    # the zvol went through HPS::Storage (its own log line and registry-free call)
    ok((grep { /^info call storage-zvol-create \Q$APP\E 20G/ } @{ $f->{log} }), 'zvol created through HPS::Storage');
    ok((grep { /^info call mirror-create/ } @{ $f->{log} }), 'node calls are logged');

    my $e = err_of(sub { $wl->plan('create', 't0') });
    is($e->kind, 'refused', 'a second create is refused');
    like($e->message, qr/already exists \(state created\)/, 'second create: reason named');
    my $before = nodecalls($f);
    $e = err_of(sub { $wl->run('create', 't0', resume => 1) });
    like($e->message, qr/already created/, '--resume on a finished create is refused too');
    is(nodecalls($f), $before, 'refused create sends nothing');
}

#--- start / stop / status
{
    my $wl = $f->{wl}->();
    $f->{ce}{calls} = [];
    my $r = $wl->run('start', 't0');
    my @c = map { [ $_->{script}, $_->{args}[0] ] } $f->{ce}->calls;
    is_deeply(\@c, [ [ 'mirror-assemble', 't0-db-root' ], [ 'vm-start', 't0-db' ], [ 'mirror-assemble', 't0-app-root' ], [ 'vm-start', 't0-app' ] ],
        'start: priority order (1 first), mirror assembled before each vm-start');
    my ($ma) = $f->{ce}->calls;
    is_deeply($ma->{args}, [ 't0-db-root', '--leg', "local:$DB", '--leg', 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-db' ], 'mirror-assemble legs');
    my $rec = rec($f, 't0');
    is($rec->{state}, 'running', 'registry: running');
    is($rec->{vms}{'t0-db'}{state}, 'running', 'registry: vm running');
    is($rec->{vms}{'t0-db'}{last_owner}, 'sch-001', 'registry: last_owner');
    like($rec->{vms}{'t0-db'}{started_at}, qr/UTC$/, 'registry: started_at');

    $f->{ce}{calls} = [];
    $wl->run('stop', 't0', vm => 't0-db');
    @c = map { [ $_->{script}, $_->{args}[0] ] } $f->{ce}->calls;
    is_deeply(\@c, [ [ 'vm-stop', 't0-db' ], [ 'mirror-stop', 't0-db-root' ] ], 'stop --vm: vm-stop then mirror-stop, that VM only');
    $rec = rec($f, 't0');
    is($rec->{vms}{'t0-db'}{state}, 'stopped', 'registry: vm stopped');
    is($rec->{state}, 'partial', 'registry: one VM running, one stopped = partial');

    $f->{ce}{calls} = [];
    $wl->run('start', 't0', vm => 't0-db');
    is(rec($f, 't0')->{state}, 'running', 'start --vm brings the workload back to running');

    $f->{ce}{calls} = [];
    $wl->run('stop', 't0');
    @c = map { [ $_->{script}, $_->{args}[0] ] } $f->{ce}->calls;
    is_deeply(\@c, [ [ 'vm-stop', 't0-app' ], [ 'mirror-stop', 't0-app-root' ], [ 'vm-stop', 't0-db' ], [ 'mirror-stop', 't0-db-root' ] ],
        'stop: reverse priority');
    is(rec($f, 't0')->{state}, 'stopped', 'registry: stopped');

    my $e = err_of(sub { $wl->plan('start', 't0', vm => 'ghost') });
    is($e->kind, 'notfound', 'unknown --vm: notfound');
    $e = err_of(sub { $wl->plan('create', 't0', vm => 't0-app') });
    is($e->kind, 'usage', '--vm on create: usage');
    $e = err_of(sub { $wl->plan('start', 't0', resume => 1) });
    is($e->kind, 'usage', '--resume on start: usage');
    $e = err_of(sub { $wl->plan('explode', 't0') });
    is($e->kind, 'usage', 'unknown operation: usage');

    # a failing node call stops the run and keeps the registry as it was
    $f->{ce}{calls} = [];
    $f->{ce}{rc}{'vm-start'} = 1;
    $e = err_of(sub { $wl->run('start', 't0') });
    is($e->kind, 'failed', 'node failure: failed');
    like($e->message, qr/step 2\/4 vm-start exited 1: boom from vm-start/, 'failure names step, script and node stderr');
    is(rec($f, 't0')->{state}, 'stopped', 'failed start leaves the state');
    is(scalar(() = $f->{ce}->calls), 2, 'nothing runs after the failing call');
    $f->{ce}{rc}{'vm-start'} = 3;
    $e = err_of(sub { $wl->run('start', 't0') });
    is($e->kind, 'refused', 'node refusal (3): refused');
    delete $f->{ce}{rc}{'vm-start'};
    $f->{ce}{rc}{'vm-stop'} = 4;
    $e = err_of(sub { $wl->run('stop', 't0') });
    is($e->kind, 'notfound', 'node not-found (4): notfound');
    delete $f->{ce}{rc}{'vm-stop'};
}

{
    my $wl = $f->{wl}->(storage => sub { $f->{mk}->(host => $_[0]) });
    my $ce = $f->{ce};
    $ce->{calls} = [];
    $ce->{out} = { 'vm-status' => "dominfo\nVM t0-db running\n", 'mirror-status' => "detail\nMIRROR t0-db-root clean\n" };
    my $r = $wl->run('status', 't0', vm => 't0-db');
    ok($r->{ok}, 'status ok');
    is($r->{state}, 'stopped', 'status: recorded state');
    is_deeply([ map { $_->{script} } $ce->calls ], [ 'vm-status', 'mirror-status' ], 'status asks the node for the VM and its mirror');
    is($r->{vms}[0]{state}, 'running', 'status: node-reported VM state');
    is($r->{vms}[0]{recorded_state}, 'stopped', 'status: recorded VM state alongside');
    is($r->{vms}[0]{mirrors}[0]{state}, 'clean', 'status: mirror state');
    $ce->{rc}{'mirror-status'} = 3;
    $r = $wl->run('status', 't0');
    ok(!$r->{ok}, 'status: a failing node call makes ok false, no exception');
    delete $ce->{rc}{'mirror-status'};
    $ce->{out} = {};
}

#--- destroy
{
    my $wl = $f->{wl}->();
    $f->{ce}{calls} = [];
    my $e = err_of(sub { $wl->plan('destroy', 't0') });
    is($e->kind, 'refused', 'destroy without an approval is refused');
    like($e->message, qr/no workload-destroy approval for workload 't0' on host \Q$MAC\E .*hps-approve workload-destroy/, 'the refusal says what a human runs');
    is(nodecalls($f), 0, 'refused destroy sends nothing');
    $e = err_of(sub { $wl->run('destroy', 't0') });
    is($e->kind, 'refused', 'run is refused as well');
    ok((grep { /refused/ } @{ $f->{log} }), 'the refusal is logged');

    # an approval for another workload, another host action: not accepted
    StorageFixture::approve($f, 'workload-destroy', pool => 'other');
    $e = err_of(sub { $wl->plan('destroy', 't0') });
    like($e->message, qr/no workload-destroy approval for workload 't0'/, 'an approval for another workload does not count');
    StorageFixture::approve($f, 'pool-destroy');
    $e = err_of(sub { $wl->plan('destroy', 't0') });
    like($e->message, qr/no workload-destroy approval/, 'a pool-destroy approval does not count');

    my $doc = StorageFixture::approve($f, 'workload-destroy', pool => 't0');
    my $plan = $wl->plan('destroy', 't0');
    is_deeply([ map { $_->{script} } @$plan ],
        [ qw(vm-stop vm-undefine mirror-stop vm-stop vm-undefine mirror-stop storage-zvol-destroy storage-zvol-destroy) ],
        'destroy plan: per VM (reverse priority) stop, undefine, mirror-stop; then the zvols');
    is_deeply([ map { $_->{args}[0] } @$plan[ 0 .. 2 ] ], [ 't0-app', 't0-app', 't0-app-root' ], 'last-started VM goes first');
    like($plan->[-1]{input}, qr/redacted/, 'the zvol destroy input is redacted in the plan');
    unlike(join('', map { $_->{input} // '' } @$plan), qr/[0-9a-f]{64}/, 'no signature in the plan');
    is(nodecalls($f), 0, 'plan sends nothing');
    ok($f->{reg}->cluster_exists('lab', 'workload_t0'), 'plan removes nothing');

    my $r = $wl->run('destroy', 't0');
    ok($r->{ok}, 'destroy ok');
    my @s = script_list($f);
    is_deeply(\@s, [ qw(vm-stop vm-undefine mirror-stop vm-stop vm-undefine mirror-stop storage-zvol-destroy storage-zvol-destroy) ],
        'destroy node calls');
    my @zv = grep { $_->{script} eq 'storage-zvol-destroy' } $f->{ce}->calls;
    is_deeply([ map { $_->{args}[0] } @zv ], [ $APP, $DB ], 'both zvols destroyed');
    ok(defined $zv[0]{input} && length $zv[0]{input}, 'the zvol destroy carries its approval document');
    ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'registry key removed');
    ok(!-e $f->{reg}->workload_dir('lab') . '/t0.json', 'definition file removed last');
    is($f->{ap}->get($MAC, 'workload-destroy', 't0'), undef, 'the workload approval is spent');
    is($f->{ap}->get($MAC, 'zvol-destroy', $APP), undef, 'the derived zvol approvals are revoked');
    is($f->{ap}->get($MAC, 'zvol-destroy', $DB), undef, '... all of them');
    is(scalar(grep { /approval|zvol-destroy/ && /[0-9a-f]{64}/ } @{ $f->{log} }), 0, 'no secret or signature in the log');

    $e = err_of(sub { $wl->plan('status', 't0') });
    is($e->kind, 'notfound', 'the definition is gone: notfound');
}

#--- a failing destroy keeps the record and the definition; derived approvals are revoked
{
    my $g = StorageFixture::setup_workload();
    my $wl = $g->{wl}->();
    $wl->run('create', 't0');
    StorageFixture::approve($g, 'workload-destroy', pool => 't0');
    $g->{ce}{rc}{'storage-zvol-destroy'} = 1;
    $g->{ce}{calls} = [];
    my $e = err_of(sub { $wl->run('destroy', 't0') });
    ok($e, 'destroy fails when the zvol destroy fails');
    ok($g->{reg}->cluster_exists('lab', 'workload_t0'), 'record kept');
    ok(-e $g->{reg}->workload_dir('lab') . '/t0.json', 'definition kept');
    is($g->{ap}->get($MAC, 'zvol-destroy', $APP), undef, 'the derived zvol approval is revoked after the failure');
    ok($g->{ap}->get($MAC, 'workload-destroy', 't0'), 'the workload approval stays for a retry');
}

#--- refusals before any node call
{
    my $g = StorageFixture::setup_workload();
    $g->{reg}->cluster_set('lab', 'network_layout', { mgmt => StorageFixture::layout()->{mgmt} });
    my $wl = $g->{wl}->();
    my $e = err_of(sub { $wl->run('create', 't0') });
    is($e->kind, 'refused', 'a net missing from the layout: refused');
    like($e->message, qr/net 'db' is not in the cluster's network_layout/, 'the missing network is named');
    is(nodecalls($g), 0, 'no node call before the refusal');
    ok(!$g->{reg}->cluster_exists('lab', 'workload_t0'), 'no record');

    $g = StorageFixture::setup_workload();
    unlink "$g->{images}/debian-13-generic-amd64.qcow2";
    $e = err_of(sub { $g->{wl}->()->run('create', 't0') });
    is($e->kind, 'refused', 'image missing on the IPS: refused');
    like($e->message, qr/image 'debian-13-generic-amd64' is not on the IPS/, 'image named');
    is(nodecalls($g), 0, 'no node call');

    $g = StorageFixture::setup_workload();
    unlink "$g->{images}/debian-13-generic-amd64.sha256";
    $e = err_of(sub { $g->{wl}->()->run('create', 't0') });
    like($e->message, qr/has no checksum file/, 'checksum file missing: refused');

    $g = StorageFixture::setup_workload();
    open(my $fh, '>', "$g->{images}/debian-13-generic-amd64.sha256") or die;
    print {$fh} "not a sum\n";
    close $fh;
    $e = err_of(sub { $g->{wl}->()->run('create', 't0') });
    like($e->message, qr/64-hex sha256/, 'malformed checksum file: refused');

    $g = StorageFixture::setup_workload();
    $g->{reg}->cluster_unset('lab', 'network_dhcp_ip');
    $e = err_of(sub { $g->{wl}->()->run('create', 't0') });
    like($e->message, qr/network_dhcp_ip/, 'no IPS address: refused');

    $g = StorageFixture::setup_workload();
    my $d = $g->{def};
    $d->{vms}[0]{disks}[0]{legs}[0]{host} = 'ghost-host';
    StorageFixture::write_def($g, $d);
    $e = err_of(sub { $g->{wl}->()->run('create', 't0') });
    is($e->kind, 'notfound', 'a leg host that is not in the registry: notfound');
    is(nodecalls($g), 0, 'no node call');

    $g = StorageFixture::setup_workload(no_def => 1);
    $e = err_of(sub { $g->{wl}->()->run('start', 't0') });
    is($e->kind, 'notfound', 'no definition: notfound');

    $g = StorageFixture::setup_workload();
    $e = err_of(sub { $g->{wl}->()->run('start', 't0') });
    is($e->kind, 'notfound', 'defined but never created: notfound');
    like($e->message, qr/has not been created/, 'says so');
}

#--- dry run
{
    my $g = StorageFixture::setup_workload();
    my $r = $g->{wl}->()->run('create', 't0', dry_run => 1);
    ok($r->{dry_run}, 'dry run flagged');
    is(scalar @{ $r->{plan} }, 11, 'dry run carries the plan');
    is(nodecalls($g), 0, 'dry run sends nothing');
    ok(!$g->{reg}->cluster_exists('lab', 'workload_t0'), 'dry run records nothing');
    my $e = err_of(sub { $g->{wl}->()->run('destroy', 't0', dry_run => 1) });
    is($e->kind, 'notfound', 'dry run applies the same refusals');
}

#--- --resume
{
    my $g = StorageFixture::setup_workload();
    my $wl = $g->{wl}->();
    $g->{ce}{rc}{'mirror-create'} = [ 0, 1 ];    # the first VM's mirror works, the second VM's fails
    my $e = err_of(sub { $wl->run('create', 't0') });
    is($e->kind, 'failed', 'create fails on a node call');
    my $rec = rec($g, 't0');
    is($rec->{state}, 'creating', 'registry: creating');
    is($rec->{vms}{'t0-db'}{state}, 'creating', 'registry: vm creating');
    is_deeply($rec->{done}, [ "zvol:$APP", "image:$MAC:debian-13-generic-amd64", 'mirror:t0-app-root', 'write:t0-app', "nets:$MAC:mgmt", 'define:t0-app', "zvol:$DB" ],
        'progress recorded step by step') or diag explain $rec->{done};

    $e = err_of(sub { $wl->run('create', 't0') });
    like($e->message, qr/already exists \(state creating\); --resume continues/, 'create without --resume refuses and names --resume');
    $e = err_of(sub { $wl->run('start', 't0') });
    like($e->message, qr/not fully created \(state creating\)/, 'start on an unfinished create is refused');

    my $plan = $wl->plan('create', 't0', resume => 1);
    is(scalar @$plan, 10, 'the plan no longer lists the bridge step for the network already attached');

    delete $g->{ce}{rc}{'mirror-create'};
    $g->{ce}{calls} = [];
    my $r = $wl->run('create', 't0', resume => 1);
    ok($r->{ok}, 'resume ok');
    is_deeply([ script_list($g) ], [ qw(mirror-create vm-image-write net-bridge-ensure vm-define) ],
        'resume re-runs only the steps not recorded as done') or diag join ' ', script_list($g);
    is(scalar(grep { $_->{skipped} } @{ $r->{steps} }), 6, 'the other six are reported as skipped');
    $rec = rec($g, 't0');
    is($rec->{state}, 'created', 'registry: created');
    is($rec->{vms}{'t0-db'}{state}, 'defined', 'registry: second vm defined');
    ok(!exists $rec->{done}, 'progress list dropped');

    # a failed net-bridge-ensure puts the host's nets key back, so a resume runs it again
    my $k = StorageFixture::setup_workload();
    $k->{reg}->host_set($MAC, 'nets', ['mgmt']);
    $k->{ce}{rc}{'net-bridge-ensure'} = 1;
    $e = err_of(sub { $k->{wl}->()->run('create', 't0') });
    like($e->message, qr/net-bridge-ensure exited 1/, 'bridge step failure reported');
    is_deeply($k->{reg}->host_get_json($MAC, 'nets'), ['mgmt'], 'nets key restored to what it was');
    delete $k->{ce}{rc}{'net-bridge-ensure'};
    $k->{ce}{calls} = [];
    $k->{wl}->()->run('create', 't0', resume => 1);
    ok((grep { $_ eq 'net-bridge-ensure' } script_list($k)), 'resume runs the bridge step again');
    is_deeply($k->{reg}->host_get_json($MAC, 'nets'), ['mgmt', 'db'], 'nets attached after the resume');

    # resume with no record at all is a plain create
    my $h = StorageFixture::setup_workload();
    ok($h->{wl}->()->run('create', 't0', resume => 1)->{ok}, '--resume without a record starts from scratch');
}

#--- the real runner (HpsRun) on a shim hps-run: the script's own refusal reaches the operator
{
    use File::Temp qw(tempdir);
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{SHIM_DIR} = $tmp;
    my $g = StorageFixture::setup_workload();
    my $runner = HPS::Storage::Runner::HpsRun->new(hps_run => "$tmp/hps-run");
    my $wl = $g->{wl}->(runner => $runner, storage => sub { $g->{mk}->(host => $_[0], runner => $runner) });
    local $ENV{FAKE_NODE_EXIT} = 3;
    local $ENV{FAKE_NODE_STDERR} = "+ test -d /lab/enc/images\n[image-fetch] refused: --dest '/lab/enc/images' is not an existing directory";
    my $e = err_of(sub { $wl->run('create', 't0') });
    is($e->kind, 'refused', 'the script\'s exit 3 is a refusal');
    like($e->message, qr/step 1\/11 storage-zvol-create: .*storage-zvol-create exited 3: \[image-fetch\] refused: --dest '\/lab\/enc\/images' is not an existing directory/,
        'the script\'s own last stderr line is in the message') or diag $e->message;
    unlike($e->message, qr/-> agent/, 'not hps-run\'s banner');
    ok((grep { /^--json \d+ storage-zvol-create / } do { open(my $a, '<', "$tmp/args") or die; <$a> }), 'the runner always asks for --json');
    local $ENV{FAKE_NODE_EXIT} = 0;
    local $ENV{FAKE_RUN_RC} = 4;
    $e = err_of(sub { $wl->run('create', 't0', resume => 1) });
    like($e->message, qr/not a run result \(hps-run exit 4\)/, 'a reply that is not a run result is rc 1 with the reason');
}

#--- a compute-only node: both legs remote, compute_host given
{
    my $g = StorageFixture::setup_workload();
    $g->{reg}->host_set($StorageFixture::MAC2, 'STATE', 'NETWORK_BOOT');
    $g->{reg}->host_set($StorageFixture::MAC2, 'HOSTNAME', 'cmp-001');
    $g->{reg}->host_set($StorageFixture::MAC2, 'TYPE', 'TCH');
    $g->{reg}->host_set($StorageFixture::MAC2, 'nets', ['mgmt']);
    my $d = $g->{def};
    $d->{vms} = [ $d->{vms}[0] ];
    $d->{vms}[0]{compute_host} = 'cmp-001';
    $d->{vms}[0]{disks}[0]{legs} = [
        { host => 'sch-001', iqn => 'iqn.2026-01.lab.sch:hpslab-t0-root' },
        { host => 'nas', iqn => 'iqn.2026-01.lab.nas:hpslab-t0-root', portal => '192.0.2.50' } ];
    StorageFixture::write_def($g, $d);
    $g->{reg}->host_set($MAC, 'IP', '192.0.2.10');
    my $plan = $g->{wl}->()->plan('create', 't0');
    is_deeply([ map { $_->{script} } @$plan ], [ qw(image-fetch mirror-create vm-image-write vm-define) ],
        'compute-only: no zvol, no bridge step when the node already has the network');
    is($plan->[0]{host}, $StorageFixture::MAC2, 'steps go to the compute host');
    is_deeply($plan->[1]{args}, [ 't0-app-root', '--leg', 'iscsi:192.0.2.10:iqn.2026-01.lab.sch:hpslab-t0-root',
        '--leg', 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-root' ], 'the portal of a registry host comes from its IP');
    $g->{reg}->host_set($MAC, 'storage_exports', [ { zvol => 'lab/enc/x', iqn => 'iqn.2026-01.lab.sch:hpslab-t0-root',
        initiator => 'iqn.2026-01.lab.cmp:init', portal => '192.0.2.11' } ]);
    $plan = $g->{wl}->()->plan('create', 't0');
    like($plan->[1]{args}[2], qr/^iscsi:192\.0\.2\.11:/, 'an export recorded on the storage host decides the portal');
}

done_testing;
