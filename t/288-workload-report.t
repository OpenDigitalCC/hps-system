#!/usr/bin/env perl
# hps-workload report <name> [--vm <vm>] [--no-probe] [--json] (HPS::Workload::Report):
# a VM's storage from the IPS records alone (every node off), the live facts beside them when
# a node answers, the last failed operation, the open issues, the last errors, the commands
# to assemble the mirror by hand; the JSON shape; and that it writes nothing and prints no secret.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find ();
use Digest::SHA ();
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Log;
use HPS::Workload::Report;

my %MAC = (sch2 => '525400000012', sch3 => '525400000013', tch1 => '525400000021');
my $IQN_A = 'iqn.2026-11.hps.lab:sch-002:t1-app-a';
my $IQN_B = 'iqn.2026-11.hps.lab:sch-003:t1-app-b';
my $NOW = 1_800_000_000;

{
    package FakeNodes;
    # up: {mac => 1}; out: {script => text}; calls recorded
    sub new { my ($c, %o) = @_; return bless { up => $o{up} || {}, out => $o{out} || {}, calls => [] }, $c }
    sub ping { return $_[0]{up}{ $_[1] } ? 1 : 0 }
    sub call {
        my ($s, %c) = @_;
        push @{ $s->{calls} }, "$c{mac} $c{script} @{ $c{args} }";
        my $o = $s->{out}{ $c{script} };
        $o = $o->($c{args}) if ref $o eq 'CODE';
        return { rc => 0, stdout => $o // '', stderr => '' };
    }
}

sub fixture {
    my (%o) = @_;
    my $f = StorageFixture::setup();
    my $reg = $f->{reg};
    my %host = (sch2 => ['sch-002', '10.0.0.12', $IQN_A, 'lab/enc/vm/t1-app-a'], sch3 => ['sch-003', '10.0.0.13', $IQN_B, 'lab/enc/vm/t1-app-b']);
    for my $k (sort keys %host) {
        my ($n, $ip, $iqn, $zvol) = @{ $host{$k} };
        $reg->host_set($MAC{$k}, 'HOSTNAME', $n);
        $reg->host_set($MAC{$k}, 'IP', $ip);
        $reg->host_set($MAC{$k}, 'storage_pool', 'lab');
        $reg->host_set($MAC{$k}, 'storage_exports', [ { zvol => $zvol, iqn => $iqn, initiator => 'iqn.2026-11.hps.lab:tch-001', portal => $ip } ]);
    }
    $reg->host_set($MAC{tch1}, 'HOSTNAME', 'tch-001');
    $reg->host_set($MAC{tch1}, 'IP', '10.0.0.21');
    StorageFixture::write_def($f, { name => 't1', project => 'lab', vms => [ { name => 't1-app', memory_mib => 2048, vcpus => 2, image => 'x',
        compute_host => 'tch-001', nets => ['mgmt'], disks => [ { name => 'root', size => '20G', legs => [
            { host => 'sch-002', iqn => $IQN_A }, { host => 'sch-003', iqn => $IQN_B } ] } ] } ] });
    $reg->cluster_set('lab', 'workload_t1', { state => 'created', class => 3, created_at => '2026-11-17 09:00:00 UTC', by => 'tester',
        vms => { 't1-app' => { host => 'tch-001', state => 'stopped', last_owner => 'tch-001', disks => { root => {
            md => '/dev/md/t1-app-root',
            legs => [ "iscsi:10.0.0.12:$IQN_A", "iscsi:10.0.0.13:$IQN_B" ],
            remote => [
                { host => 'sch-002', iqn => $IQN_A, dataset => 'lab/enc/vm/t1-app-a', portal => '10.0.0.12', pool => 'lab', mirror => 't1-app-root', size => '20G', chap_password => 'hunter2' },
                { host => 'sch-003', iqn => $IQN_B, dataset => 'lab/enc/vm/t1-app-b', portal => '10.0.0.13', pool => 'lab', mirror => 't1-app-root', size => '20G' } ] } } } } });
    return $f if $o{clean};    # nothing has failed: no events, issues or jobs
    # logs: events.log, one refusal; and an event whose text carries a secret
    my $log = "$f->{base}/log";
    make_path($log);
    open(my $e, '>', "$log/events.log") or die;
    print {$e} "2026-11-17T10:00:00Z tch-001 HPS-ALERT pri=warning kind=workload subject=t1 state=failed start t1: step 2/4 mirror-assemble exited 3: DIVERGED t1-app-root legA events=60 time=x legB events=58 time=y\n";
    print {$e} "2026-11-17T11:00:00Z ips HPS-EVENT pri=notice kind=workload subject=t1 state=refused start t1 refused: leg sch-003 password=hunter2\n";
    print {$e} "2026-11-17T12:00:00Z ips HPS-ALERT pri=warning kind=workload subject=t1/t1-app state=paused hps-guest-paused: guest t1-app on tch-001 is paused (ioerror); issue 20261117-001 is open\n";
    close $e;
    # an open issue, a failed job naming the workload only in its text (older record shape)
    make_path("$f->{base}/clusters/lab/issues", "$f->{base}/clusters/lab/jobs/failed");
    open(my $i, '>', "$f->{base}/clusters/lab/issues/20261117-001.json") or die;
    print {$i} JSON::PP->new->canonical->encode({ id => '20261117-001', kind => 'guest-paused', state => 'needs-human', severity => 'urgent',
        summary => 'guest-paused guest=t1-app host=tch-001', opened_at => '2026-11-17T12:00:00Z', last_seen_at => '2026-11-17T12:30:00Z',
        fields => { guest => 't1-app', host => 'tch-001', workload => 't1' },
        heal => { attempts => 2, last_at => '2026-11-17T12:20:00Z', last_result => 'failed: vm-reassemble t1-app exit 3: REFUSED legs leg(s) not present or not logged in: iscsi:10.0.0.12:' . $IQN_A . ' (mirror t1-app-root); t1-app is untouched' },
        trail => [ { at => '2026-11-17T12:20:00Z', event => 'heal', detail => 'attempt 2: failed; vm-reassemble t1-app exit 3: REFUSED legs leg(s) not present or not logged in: iscsi:10.0.0.12:' . $IQN_A . ' (mirror t1-app-root); t1-app is untouched' } ] }), "\n";
    close $i;
    open(my $j, '>', "$f->{base}/clusters/lab/jobs/failed/aaaaaaaa.result.json") or die;
    print {$j} JSON::PP->new->canonical->encode({ id => 'aaaaaaaa', kind => 'workload-start', exit => 3, args => ['t1'], finished_at => '2026-11-17T09:30:00Z', stdout => '', stderr => "hps-workload: start: step 1/3 mirror-assemble exited 3: REFUSED x\n" }), "\n";
    close $j;
    open($j, '>', "$f->{base}/clusters/lab/jobs/failed/bbbbbbbb.result.json") or die;
    print {$j} JSON::PP->new->canonical->encode({ id => 'bbbbbbbb', kind => 'workload-start', exit => 1, args => ['other'], finished_at => '2026-11-17T09:31:00Z', stdout => '', stderr => "unrelated\n" }), "\n";
    close $j;
    return $f;
}

sub reporter {
    my ($f, $nodes, %o) = @_;
    return HPS::Workload::Report->new(registry => $f->{reg}, runner => $nodes, now => $NOW, jobs_dir => "$f->{base}/clusters/lab/jobs",
        log => HPS::Log->new(log_dir => "$f->{base}/log", registry => $f->{reg}, domain => undef, now => $NOW), %o);
}

# every file under the tree: path => digest + mtime + size, and directories
sub snapshot {
    my ($base) = @_;
    my %s;
    File::Find::find({ no_chdir => 1, wanted => sub {
        my @st = lstat $File::Find::name;
        my $d = -f $File::Find::name ? Digest::SHA::sha256_hex(do { open(my $h, '<', $File::Find::name) or die; local $/; <$h> }) : 'dir';
        $s{ $File::Find::name } = "$d $st[9] $st[7]";
    } }, $base);
    return \%s;
}

my $ALL_UP = { map { $_ => 1 } values %MAC };
my $healthy = sub {
    return FakeNodes->new(up => $ALL_UP, out => {
        'storage-zvol-list' => "lab/enc/vm/t1-app-a 21474836480 1 1\nlab/enc/vm/t1-app-b 21474836480 1 1\n",
        'iscsi-status' => "o- iqn.2026-11.hps.lab:sch-002:t1-app-a\no- iqn.2026-11.hps.lab:sch-003:t1-app-b\n",
        'mirror-status' => "ARRAY t1-app-root array_state=clean\nLEGSTATE iscsi:10.0.0.12:$IQN_A session=logged-in device=running\nLEGSTATE iscsi:10.0.0.13:$IQN_B session=logged-in device=running\nMIRROR t1-app-root clean\n" });
};

#--- (a) healthy, every node answers
{
    my $f = fixture(clean => 1);
    my $nodes = $healthy->();
    my $before = snapshot($f->{base});
    my $r = reporter($f, $nodes)->report('t1');
    is_deeply($before, snapshot($f->{base}), 'the config tree is byte-identical (content, mtime, size, files) after a report with probing');
    my ($v) = @{ $r->{vms} };
    my ($d) = @{ $v->{storage} };
    is($v->{compute_host}{name}, 'tch-001', 'compute host');
    is($v->{compute_host}{address}, '10.0.0.21', '... and its address');
    is($d->{mirror}, 't1-app-root', 'mirror name');
    is($d->{size}, '20G', 'size');
    my ($l0, $l1) = @{ $d->{legs} };
    is($l0->{host}, 'sch-002', 'leg 0 storage host');
    is($l0->{address}, '10.0.0.12', '... its address');
    is($l0->{pool}, 'lab', '... pool');
    is($l0->{zvol}, 'lab/enc/vm/t1-app-a', '... zvol path');
    is($l0->{target}, $IQN_A, '... iSCSI target');
    is($l1->{target}, $IQN_B, 'leg 1 target');
    is($l0->{live}{zvol_exists}, 'yes', 'live: zvol exists');
    is($l0->{live}{target_exported}, 'yes', 'live: target exported');
    is($l0->{live}{session}, 'logged-in', 'live: session');
    is($l0->{live}{device_state}, 'running', 'live: device state');
    is($d->{live_mirror}{array_state}, 'clean', 'live: array_state');
    is($d->{live_mirror}{mirror_state}, 'clean', 'live: mirror state');
    ok(!exists $l0->{live}{error}, 'no error key for a healthy node');
    is($v->{why_it_will_not_start}{status}, 'none on record', 'a healthy VM: no failed operation on record');
    is(scalar @{ $v->{open_issues} }, 0, '... and no open issue');
    like(join("\n", @{ $v->{reconstruct} }), qr{mirror-assemble t1-app-root --leg iscsi:10\.0\.0\.12:\Q$IQN_A\E --leg iscsi:10\.0\.0\.13:\Q$IQN_B\E}, 'the reconstruct command carries this VM\'s legs');
    like(join("\n", @{ $v->{reconstruct} }), qr{hps-run\.sh tch-001 mirror-assemble}, '... on its compute host');
    my $text = HPS::Workload::Report::render($r);
    like($text, qr/STORAGE.*WHY IT WILL NOT START.*LAST ERRORS.*TO RECONSTRUCT BY HAND/s, 'text sections in the asked order');
    unlike($text . encode_json($r), qr/hunter2|chap_password/, 'no secret from the record or from a log line');
    diag("HEALTHY\n$text") if $ENV{REPORT_SAMPLE};
}

#--- (b) refused by vm-reassemble, every node off
{
    my $f = fixture();
    my $nodes = FakeNodes->new(up => {});
    my $before = snapshot($f->{base});
    my $r = reporter($f, $nodes)->report('t1');
    is_deeply($before, snapshot($f->{base}), 'every node off: the config tree is byte-identical');
    is(scalar @{ $nodes->{calls} }, 0, 'a node that does not answer is not called');
    my ($v) = @{ $r->{vms} };
    my ($d) = @{ $v->{storage} };
    is($d->{legs}[1]{zvol}, 'lab/enc/vm/t1-app-b', 'the recorded storage is complete with every node off');
    is($d->{legs}[1]{address}, '10.0.0.13', '... with the storage host address');
    is($d->{legs}[0]{live}{zvol_exists}, 'not reachable', 'live facts: not reachable');
    is($d->{legs}[0]{live}{session}, 'not reachable', '... every one');
    is($d->{live_mirror}{array_state}, 'not reachable', '... and the mirror');
    my $w = $v->{why_it_will_not_start};
    is($w->{status}, 'failed or refused operation on record', 'a failure is on record');
    is($w->{verb}, 'vm-reassemble', 'verb: the newest failure is the healer\'s vm-reassemble');
    is($w->{step}, 'exit 3', 'step');
    like($w->{line}, qr/\AREFUSED legs leg\(s\) not present or not logged in: iscsi:10\.0\.0\.12:\Q$IQN_A\E \(mirror t1-app-root\); t1-app is untouched/, 'the refusal line, verbatim');
    is($w->{at}, '2026-11-17T12:20:00Z', 'time');
    like($w->{source}, qr/issue 20261117-001/, 'source');
    is(scalar @{ $v->{open_issues} }, 1, 'the open issue naming the VM');
    is($v->{open_issues}[0]{id}, '20261117-001', '... its id');
    my @e = @{ $v->{last_errors} };
    ok(@e >= 3, 'last errors found');
    is_deeply([ map { $_->{time} } @e ], [ sort { $b cmp $a } map { $_->{time} } @e ], 'newest first');
    ok((grep { $_->{source} =~ /jobs\/failed\/aaaaaaaa/ } @e), 'a failed job that names the workload');
    ok(!(grep { $_->{source} =~ /bbbbbbbb/ } @e), 'a failed job of another workload is not shown');
    ok((grep { $_->{source} eq 'events.log' && $_->{line} =~ /\ADIVERGED t1-app-root/ } @e), 'an events.log failure, the line that says why');
    unlike(encode_json($r), qr/hunter2/, 'the secret in a log line is withheld');
    my $text = HPS::Workload::Report::render($r);
    like($text, qr/leg 0 \(iscsi\): storage host sch-002 \(10\.0\.0\.12\), pool lab, zvol lab\/enc\/vm\/t1-app-a, target \Q$IQN_A\E/, 'text: the leg line');
    like($text, qr/zvol exists not reachable/, 'text: not reachable, not an error');
    diag($text) if $ENV{REPORT_SAMPLE};
}

#--- --no-probe, missing data named, one VM
{
    my $f = fixture();
    my $nodes = $healthy->();
    my $r = reporter($f, $nodes, probe => 0)->report('t1', vm => 't1-app');
    is(scalar @{ $nodes->{calls} }, 0, '--no-probe calls no node');
    is($r->{vms}[0]{storage}[0]{legs}[0]{live}{session}, 'not probed', '... and says so');
    is($r->{probed}, JSON::PP::false, 'probed false');
    # a record without the remote entries and a definition without hosts: say what is missing
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t1');
    delete $rec->{vms}{'t1-app'}{disks}{root}{remote};
    $f->{reg}->cluster_unset('lab', 'workload_t1');
    $f->{reg}->cluster_set('lab', 'workload_t1', $rec);
    $f->{reg}->host_unset($MAC{sch3}, 'storage_exports');
    $f->{reg}->host_unset($MAC{sch3}, 'IP');
    $r = reporter($f, undef, probe => 0)->report('t1');
    my $l1 = $r->{vms}[0]{storage}[0]{legs}[1];
    is($l1->{zvol}, 'not recorded', 'a zvol that is not on record reads "not recorded"');
    is($l1->{pool}, 'not recorded', 'a pool that is not on record reads "not recorded"');
    like($l1->{address}, qr/10\.0\.0\.13 \(portal; host IP not recorded\)/, 'the host IP missing: the portal, labelled');
    is($r->{vms}[0]{storage}[0]{legs}[0]{zvol}, 'lab/enc/vm/t1-app-a', 'the other leg: the zvol from the storage host\'s storage_exports');
    my $err = eval { reporter($f, undef)->report('t1', vm => 'nosuch'); 1 } ? undef : $@;
    is(ref $err && $err->kind, 'notfound', 'an unknown VM: not found');
    $err = eval { reporter($f, undef)->report('nosuch'); 1 } ? undef : $@;
    is(ref $err && $err->kind, 'notfound', 'an unknown workload: not found');
}

#--- the JSON shape (pinned)
{
    my $f = fixture();
    my $r = reporter($f, FakeNodes->new(up => {}))->report('t1');
    is_deeply([ sort keys %$r ], [ sort @HPS::Workload::Report::TOP_KEYS ], 'top-level keys');
    is_deeply([ sort keys %$r ], [ sort qw(schema workload cluster generated_at state probed vms notes) ], '... are exactly these');
    is_deeply([ sort keys %{ $r->{vms}[0] } ], [ sort @HPS::Workload::Report::VM_KEYS ], 'per-VM keys');
    is_deeply([ sort keys %{ $r->{vms}[0]{why_it_will_not_start} } ], [ sort qw(status at source verb step line) ], 'why keys');
    is_deeply([ sort keys %{ $r->{vms}[0]{storage}[0] } ], [ sort qw(disk mirror mirror_name size mirrored device legs live_mirror) ], 'disk keys');
    is_deeply([ sort keys %{ $r->{vms}[0]{storage}[0]{legs}[0] } ],
        [ sort qw(index kind spec recorded_from host address pool zvol target portal host_known size size_note live) ], 'leg keys');
    is_deeply([ sort keys %{ $r->{vms}[0]{storage}[0]{legs}[0]{live} } ], [ sort qw(host_reachable zvol_exists target_exported session device_state) ], 'live keys');
    is(ref $r->{vms}[0]{reconstruct}, 'ARRAY', 'reconstruct is a list of strings');
    ok(!(grep { ref $_ } @{ $r->{vms}[0]{reconstruct} }), '... strings');
    diag("JSON\n" . JSON::PP->new->canonical->pretty->encode($r)) if $ENV{REPORT_SAMPLE};
    is(encode_json($r) =~ /null/ ? 1 : 0, 0, 'no null: a missing fact is a word, not an absent or empty value');
}

#--- recorded at create: the remote leg's portal, mirror, size; a failed step's own line in the event
{
    my $f = StorageFixture::setup_workload();
    my $wl = $f->{wl}->();
    $wl->run('create', 't0');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t0');
    my ($rm) = @{ $rec->{vms}{'t0-app'}{disks}{root}{remote} };
    is($rm->{iqn}, 'iqn.2026-01.lab.nas:hpslab-t0-root', 'create records the leg iqn');
    is($rm->{portal}, '192.0.2.50', '... its portal');
    is($rm->{mirror}, 't0-app-root', '... the mirror name');
    is($rm->{size}, '20G', '... the disk size');
    ok(!defined $rm->{dataset} && !defined $rm->{pool}, '... the zvol and pool stay unknown when no export names the iqn (reported as not recorded)');
    @{ $f->{log} } = ();
    $f->{ce}{rc}{'mirror-assemble'} = 3;
    $f->{ce}{err}{'mirror-assemble'} = "REFUSED legs leg(s) not present or not logged in: x\n";
    eval { $f->{wl}->()->run('start', 't0') };
    ok((grep { /HPS-ALERT.*kind=workload subject=t0 state=refused|state=refused/ || /state=failed/ } @{ $f->{log} }), 'a refused step is an event');
    ok((grep { /step \d+\/\d+ mirror-assemble exited 3: REFUSED legs leg\(s\) not present/ } @{ $f->{log} }), 'the event carries the step\'s own last stderr line');
}

#--- the CLI: usage, the read-only claim end to end, --json
{
    my $tmp = tempdir(CLEANUP => 1);
    my $f = fixture();
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}            = "$tmp/hps-run";
    local $ENV{HPS_LOG}                = "$f->{base}/log";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{SHIM_DIR}               = $tmp;
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_);
        my $out = qx(@cmd 2>$tmp/stderr);
        return ($? >> 8, $out, do { open(my $e, '<', "$tmp/stderr") or die; local $/; <$e> });
    };
    my ($rc, $out, $err) = $cli->('report');
    is($rc, 2, 'no name: usage');
    ($rc) = $cli->('report', 't1', 'extra');
    is($rc, 2, 'an extra argument: usage');
    ($rc, $out, $err) = $cli->('start', 't1', '--no-probe');
    is($rc, 2, '--no-probe on start: usage');
    ($rc) = $cli->('report', 'nosuch');
    is($rc, 4, 'an unknown workload: 4');
    my $before = snapshot($f->{base});
    ($rc, $out, $err) = $cli->('report', 't1');
    is($rc, 0, 'report: 0') or diag $err;
    like($out, qr/STORAGE.*sch-002.*WHY IT WILL NOT START/s, 'text on stdout');
    ($rc, $out) = $cli->('report', 't1', '--json');
    is($rc, 0, 'report --json: 0');
    my $j = eval { decode_json($out) };
    is($j && $j->{workload}, 't1', 'valid JSON');
    ($rc) = $cli->('report', 't1', '--vm', 't1-app', '--no-probe');
    is($rc, 0, '--vm and --no-probe');
    is_deeply($before, snapshot($f->{base}), 'the CLI wrote nothing to the config tree');
    ok(!-d "$f->{base}/clusters/lab/jobs/new", 'no job was queued');
}

done_testing;
