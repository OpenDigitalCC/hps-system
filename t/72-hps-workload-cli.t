#!/usr/bin/env perl
# CS-3.6: bin/hps-workload: exit codes, --json, --dry-run, against a shim hps-run.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

$StorageFixture::NOW = time;
my $f   = StorageFixture::setup_workload();
my $mac = $StorageFixture::MAC;
my $tmp = tempdir(CLEANUP => 1);

# A stand-in for scripts/hps-run.sh: records its arguments; in --input --json
# mode (the storage zvol-destroy) it answers like ctrl-exec-cli would.
open(my $sh, '>', "$tmp/hps-run") or die;
print {$sh} <<'SHIM';
#!/usr/bin/env bash
echo "$*" >> "$SHIM_DIR/args"
if [[ "$1" == "--input" ]]; then
  cat > /dev/null
  jq -n --argjson e "${FAKE_NODE_EXIT:-0}" '{ok:1,results:[{host:"h",exit:$e,stdout:"node says hi\n",stderr:"node complains\n"}]}'
  exit 0
fi
case "$2" in
  vm-status) echo "VM ${3} running" ;;
  mirror-status) echo "MIRROR ${3} clean" ;;
  *) echo "plain output of $2" ;;
esac
exit "${FAKE_RUN_RC:-0}"
SHIM
close $sh;
chmod 0755, "$tmp/hps-run";

local $ENV{HPS_CONFIG_BASE}         = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY}     = "$f->{base}/system.db";
local $ENV{HPS_RUN_CMD}             = "$tmp/hps-run";
local $ENV{HPS_RESOURCES}           = $f->{base};
local $ENV{HPS_WORKLOAD_NO_SYSLOG}  = 1;
local $ENV{HPS_STORAGE_NO_SYSLOG}   = 1;
local $ENV{SHIM_DIR}                = $tmp;
local $ENV{SUDO_USER}               = 'tester';

sub cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_);
    my $out = qx(@cmd 2>$tmp/stderr);
    my $rc = $? >> 8;
    open(my $e, '<', "$tmp/stderr") or die;
    local $/;
    my $err = <$e>;
    return ($rc, $out . $err, $out);
}
sub calls { return -e "$tmp/args" ? do { open(my $h, '<', "$tmp/args") or die; my @l = <$h>; @l } : () }
sub reset_shim { unlink "$tmp/args" }
sub rec { return $f->{reg}->cluster_get_json('lab', 'workload_t0') }

# --- usage
my ($rc, $out) = cli();
is($rc, 2, 'no arguments: usage (2)');
($rc, $out) = cli('create');
is($rc, 2, 'operation only: usage');
($rc, $out) = cli('explode', 't0');
is($rc, 2, 'unknown operation: usage');
like($out, qr/unknown operation 'explode'/, 'says so');
($rc, $out) = cli('create', 't0', 'extra');
is($rc, 2, 'extra argument: usage');
($rc, $out) = cli('create', 't0', '--vm', 't0-app');
is($rc, 2, '--vm on create: usage');
($rc, $out) = cli('start', 't0', '--resume');
is($rc, 2, '--resume on start: usage');
($rc, $out) = cli('start', 't0', '--allow-any-pool-name');
is($rc, 2, '--allow-any-pool-name on start: usage');
($rc, $out) = cli('create', 'Bad Name');
is($rc, 2, 'bad workload name: usage');
is(scalar(() = calls()), 0, 'usage errors send nothing');

# --- not found
($rc, $out) = cli('create', 'ghost');
is($rc, 4, 'no definition: not found (4)');
like($out, qr/no workload definition/, 'says so');

# --- dry run
($rc, $out) = cli('create', 't0', '--dry-run');
is($rc, 0, 'create --dry-run exits 0');
like($out, qr/Dry run: create t0; nothing is sent or changed/, 'dry-run header');
like($out, qr/\[$mac\] storage-zvol-create lab\/enc\/vm\/t0-t0-app-root 20G/, 'dry-run lists the node calls');
like($out, qr/vm-define t0-db --memory 4096 --vcpus 4 --disk \/dev\/md\/t0-db-root --net br-mgmt --net br-db/, 'dry-run lists vm-define');
is(scalar(() = calls()), 0, 'dry run runs nothing');
ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'dry run records nothing');
($rc, $out, my $o2) = cli('create', 't0', '--dry-run', '--json');
is($rc, 0, 'dry-run --json exits 0');
my $j = decode_json($o2);
ok($j->{dry_run}, 'json: dry_run');
is($j->{op}, 'create', 'json: op');
is($j->{plan}[0]{script}, 'storage-zvol-create', 'json: plan[0]');
is(scalar @{ $j->{plan} }, 11, 'json: whole plan');

# --- refusals: exit 3
{
    my $saved = $f->{reg}->cluster_get_json('lab', 'network_layout');
    $f->{reg}->cluster_set('lab', 'network_layout', { mgmt => $saved->{mgmt} });
    ($rc, $out) = cli('create', 't0');
    is($rc, 3, 'net not in the layout: refused (3)');
    like($out, qr/net 'db' is not in the cluster's network_layout/, 'names the network');
    $f->{reg}->cluster_set('lab', 'network_layout', $saved);
    is(scalar(() = calls()), 0, 'nothing was sent');
}
($rc, $out) = cli('start', 't0');
is($rc, 4, 'start before create: not found (4)');

# --- create, start, status, stop
($rc, $out) = cli('create', 't0');
is($rc, 0, 'create exits 0') or diag $out;
like($out, qr/create ok: workload t0/, 'create prints its result');
is(rec()->{state}, 'created', 'registry: created');
my @c = calls();
like($c[0], qr/^\Q--input --json $mac storage-zvol-create\E|^$mac storage-zvol-create/, 'zvol create went through the runner') or diag @c;
ok((grep { /^\Q$mac\E image-fetch debian-13-generic-amd64 --from http:\/\/192\.0\.2\.1\/images\// } @c), 'image-fetch called');

($rc, $out) = cli('create', 't0');
is($rc, 3, 'second create: refused (3)');
like($out, qr/already exists/, 'says so');

reset_shim();
($rc, $out) = cli('start', 't0', '--vm', 't0-db');
is($rc, 0, 'start --vm exits 0');
is_deeply([ map { s/^\S+ //r =~ s/\s+\z//r } calls() ], [ 'mirror-assemble t0-db-root --leg local:lab/enc/vm/t0-t0-db-root --leg iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-db', 'vm-start t0-db' ], 'start --vm: only that VM');
is(rec()->{vms}{'t0-db'}{state}, 'running', 'registry: running');

($rc, $out) = cli('status', 't0');
is($rc, 0, 'status exits 0');
like($out, qr/Workload t0: partial/, 'status: workload state');
like($out, qr/t0-db\s+host sch-001\s+recorded running\s+node running/, 'status: VM line');
like($out, qr/mirror t0-db-root: clean/, 'status: mirror line');
($rc, $out, $o2) = cli('status', 't0', '--json', '--vm', 't0-app');
$j = decode_json($o2);
is($j->{vms}[0]{vm}, 't0-app', 'status --json --vm: that VM');
is($j->{vms}[0]{mirrors}[0]{state}, 'clean', 'status --json: mirror state');

reset_shim();
($rc, $out) = cli('stop', 't0', '--dry-run');
is($rc, 0, 'stop --dry-run exits 0');
is(scalar(() = calls()), 0, 'nothing sent');
($rc, $out) = cli('stop', 't0');
is($rc, 0, 'stop exits 0');
is(rec()->{vms}{'t0-db'}{state}, 'stopped', 'registry: stopped');

# --- node failures
{
    local $ENV{FAKE_RUN_RC} = 1;
    ($rc, $out) = cli('start', 't0', '--vm', 't0-db');
    is($rc, 1, 'a failing node call: exit 1');
    like($out, qr/step 1\/2 mirror-assemble exited 1/, 'names the step');
    local $ENV{FAKE_RUN_RC} = 3;
    ($rc, $out) = cli('start', 't0', '--vm', 't0-db');
    is($rc, 3, 'a node refusal: exit 3');
    local $ENV{FAKE_RUN_RC} = 1;
    ($rc, $out) = cli('status', 't0');
    is($rc, 1, 'status with a failing node call: exit 1');
}

# --- destroy
($rc, $out) = cli('destroy', 't0');
is($rc, 3, 'destroy without approval: refused (3)');
like($out, qr/hps-approve workload-destroy/, 'tells a human what to run');
ok(-e $f->{reg}->workload_dir('lab') . '/t0.json', 'definition still there');
StorageFixture::approve($f, 'workload-destroy', pool => 't0', expires => $StorageFixture::NOW + 7200);
($rc, $out) = cli('destroy', 't0', '--dry-run');
is($rc, 0, 'destroy --dry-run with an approval exits 0');
ok($f->{reg}->cluster_exists('lab', 'workload_t0'), 'dry run removes nothing');
($rc, $out) = cli('destroy', 't0');
is($rc, 0, 'destroy exits 0') or diag $out;
ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'registry key gone');
ok(!-e $f->{reg}->workload_dir('lab') . '/t0.json', 'definition gone');

done_testing;
