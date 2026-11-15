#!/usr/bin/env perl
# A node that is a VM of a stopped (or suspended) workload is stopped, not down
# (docs/MONITORING.md): HPS::Monitor::stopped_hosts and stopped_lines, hps-monitor
# not calling such a node, and hps-metrics reading the STOPPED line back.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::Local qw(timegm);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Monitor;
use HPS::Metrics;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/replies");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
my %mac = (sch => 'aabbccddee01', bld => '5254000d224e', tch => 'aabbccddee02', multi => 'aabbccddee05');
$reg->host_set($mac{sch},   'HOSTNAME', 'sch-001');
$reg->host_set($mac{bld},   'HOSTNAME', 'bld-001');
$reg->host_set($mac{tch},   'HOSTNAME', 'tch-001');
$reg->host_set($mac{multi}, 'HOSTNAME', 'tch-002');
# tch-002 has a second NIC: a workload record may name either MAC
$reg->host_set($mac{multi}, 'macs', [ { mac => 'aa:bb:cc:dd:ee:05', ifname => 'eth0' }, { mac => '52:54:00:aa:00:09', ifname => 'eth1' } ]);
$ENV{HPS_CONFIG_BASE}     = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

sub vm { my ($state, @macs) = @_; return { host => 'sch-001', (defined $state ? (state => $state) : ()), macs => [@macs] } }
sub wl { my ($state, %vms) = @_; return { state => $state, vms => {%vms}, created_at => '2026-11-10 10:00:00 UTC' } }
my $BLD = '52:54:00:0d:22:4e';
my $F   = 'bld-001.hps.test';

#--- stopped_hosts: which hosts, by which workload -----------------------------------
my $st = HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => vm('stopped', $BLD)) });
is_deeply($st, { $F => { workload => 'builder', vm => 'bld-001', state => 'stopped' } }, 'a node that is the VM of a stopped workload is stopped, by that workload');
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('suspended', 'bld-001' => vm('suspended', $BLD)) }),
    { $F => { workload => 'builder', vm => 'bld-001', state => 'suspended' } }, 'a suspended VM counts the same way');
is_deeply(HPS::Monitor::stopped_hosts($reg, { nodes => wl('stopped', 't2' => vm('stopped', '52:54:00:aa:00:09')) }),
    { 'tch-002.hps.test' => { workload => 'nodes', vm => 't2', state => 'stopped' } }, 'any recorded MAC of the host names it');
is_deeply(HPS::Monitor::stopped_hosts($reg, { mix => wl('partial', 'bld-001' => vm('stopped', $BLD), 't1' => vm('running', 'aa:bb:cc:dd:ee:02')) }),
    { $F => { workload => 'mix', vm => 'bld-001', state => 'stopped' } }, 'the VM\'s own state decides: its running sibling is a target as before');

# everything else is "not stopped": today's behaviour
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('running', 'bld-001' => vm('running', $BLD)) }), {}, 'a running workload: not stopped');
for my $s (qw(creating defined partial failed), '') {
    is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl($s, 'bld-001' => vm($s, $BLD)) }), {}, "recorded state '$s': not stopped");
}
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => vm(undef, $BLD)) }), {}, 'a VM with no state of its own: not stopped');
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => vm('stopped')) }), {}, 'no macs recorded: not stopped');
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => { state => 'stopped' }) }), {}, 'no macs key: not stopped');
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => { state => 'stopped', macs => 'x' }) }), {}, 'macs that is not a list: not stopped');
is_deeply(HPS::Monitor::stopped_hosts($reg, { builder => wl('stopped', 'bld-001' => vm('stopped', 'nonsense', undef, [1])) }), {}, 'values that are not MACs: not stopped');
is_deeply(HPS::Monitor::stopped_hosts($reg, { guest => wl('stopped', 'g1' => vm('stopped', '52:54:00:99:99:99')) }), {}, 'a stopped VM that is no registry host: nothing');
is_deeply(HPS::Monitor::stopped_hosts($reg, {}), {}, 'no workload records: nothing');
is_deeply(HPS::Monitor::stopped_hosts($reg, undef), {}, 'records not read: nothing');
is_deeply(HPS::Monitor::stopped_hosts($reg, { a => undef, b => 'text', c => [], d => { vms => [] }, e => { vms => { x => 'y' } } }), {}, 'records of any other shape: nothing');
is_deeply(HPS::Monitor::stopped_hosts($reg, { old => wl('stopped', 'bld-001' => vm('stopped', $BLD)), new => wl('running', 'bld-001' => vm('running', $BLD)) }), {},
    'a host one record calls stopped and another running: not stopped');

#--- workload_records: read from the registry ------------------------------------------
is_deeply(HPS::Monitor::workload_records($reg), {}, 'no workload keys: no records');
$reg->cluster_set('lab', 'workload_builder', wl('stopped', 'bld-001' => vm('stopped', $BLD)));
$reg->cluster_set('lab', 'workload_gone_destroyed', { at => '2026-11-10 10:00:00 UTC', by => 'op' });
$reg->cluster_set('lab', 'workload_text', 'not json {');
$reg->cluster_set('lab', 'workload_list', [ 1, 2 ]);
my $recs = HPS::Monitor::workload_records($reg);
is_deeply([ sort keys %$recs ], ['builder'], 'the records that are objects; a destroyed note, unreadable text and a list are left out');
is_deeply(HPS::Monitor::stopped_hosts($reg, $recs), { $F => { workload => 'builder', vm => 'bld-001', state => 'stopped' } }, 'read back: the builder is stopped');

#--- stopped_lines: once, then at the throttle interval ----------------------------------
{
    my $line = "hps-monitor: host=$F state=STOPPED workload=builder vm=bld-001 recorded state stopped; not checked";
    my @hosts = ('sch-001.hps.test', $F);
    is_deeply([ HPS::Monitor::stopped_lines($st, \@hosts, 1000) ], [ [ 'info', $line ] ], 'one info line, in the form of the other host lines');
    is_deeply([ HPS::Monitor::stopped_lines($st, ['sch-001.hps.test'], 1000) ], [], 'a stopped host that is not a target (not paired): no line');
    is_deeply([ HPS::Monitor::stopped_lines({}, \@hosts, 1000) ], [], 'nothing stopped: no line');
    my %memo = ($F => { since => 400, logged => 900, tried => 900 }, 'sch-001.hps.test' => { since => 1, logged => 1, tried => 1 }, _twarn => '');
    my $n = sub { scalar(() = HPS::Monitor::stopped_lines(@_)) };
    is($n->($st, \@hosts, 1000, \%memo), 1, 'loop: logged when first seen stopped');
    ok(!exists $memo{$F}, 'loop: what was kept of it as unreachable is dropped');
    ok(exists $memo{'sch-001.hps.test'} && exists $memo{_twarn}, 'loop: other hosts\' memory is untouched');
    is($n->($st, \@hosts, 1300, \%memo), 0, 'loop: 300 s later: not logged');
    is($n->($st, \@hosts, 1599, \%memo), 0, 'loop: still within 600 s: not logged');
    is($n->($st, \@hosts, 1600, \%memo), 1, 'loop: at 600 s: logged again');
    is($n->({}, \@hosts, 1660, \%memo), 0, 'loop: started again: no line');
    ok(!grep({ /\Astopped:/ } keys %memo), 'loop: and it is forgotten');
    is($n->($st, \@hosts, 1700, \%memo), 1, 'loop: stopped again 40 s later: logged at once');
    is(HPS::Monitor::skip_call(\%memo, $F, 1700), 0, 'loop: nothing holds back the first call after a start');
}

#--- hps-monitor: the stopped node is not called -----------------------------------------
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub spew { open(my $fh, '>', $_[0]) or die $!; print {$fh} $_[1]; close $fh }
my $doc = encode_json({ host => 'x', state => 'OK', code => 0, checks => [ { name => 'procs', state => 'OK', code => 0, summary => 'PROCS OK: 120 processes', perfdata => [] } ] });
spew("$base/replies/sch-001.hps.test", encode_json({ ok => JSON::PP::true, results => [ { exit => 0, stdout => $doc, stderr => '' } ] }));
my $runner = "$base/hps-run.sh";
spew($runner, <<"SH");
#!/bin/sh
echo "\$*" >> '$base/run-args'
host=\$2
if [ -f '$base/replies/'"\$host" ]; then cat '$base/replies/'"\$host"; exit 0; fi
echo "hps-run: host '\$host' is unreachable" >&2
exit 4
SH
spew("$base/agents.sh", "#!/bin/sh\nprintf '%s\\n' ips.hps.test sch-001.hps.test bld-001.hps.test\n");
spew("$base/logger.sh", "#!/bin/sh\necho \"\$1 \$2\" >> '$base/log'\n");
spew("$base/df.sh", "#!/bin/sh\ncase \"\$2\" in -i) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted\\n/dev/x 1000 100 900 10%% /srv\\n' ;; *) printf 'Filesystem 1-blocks Used Available Capacity Mounted\\n/dev/x 1000 400 600 40%% /srv\\n' ;; esac\n");
chmod 0755, $runner, "$base/agents.sh", "$base/logger.sh", "$base/df.sh";
make_path("$base/res", "$base/hpslog");
@ENV{qw(HPS_MONITOR_RUN HPS_MONITOR_AGENTS HPS_MONITOR_LOGGER HPS_MONITOR_DF HPS_RESOURCES HPS_LOG)}
    = ($runner, "$base/agents.sh", "$base/logger.sh", "$base/df.sh", "$base/res", "$base/hpslog");
sub monitor { my $out = `perl $Bin/../bin/hps-monitor @_ 2>$base/stderr`; return ($? >> 8, $out) }
sub reset_logs { unlink "$base/log", "$base/run-args" }

my ($rc, $out) = monitor('run');
is($rc, 0, 'run exits 0');
is(slurp("$base/run-args"), "--json sch-001.hps.test nagios-check --all\n", 'run: the stopped node is not called; the others are');
like($out, qr/^HPS-EVENT pri=info kind=monitor subject=\Q$F\E state=stopped hps-monitor: host=\Q$F\E state=STOPPED workload=builder vm=bld-001 recorded state stopped; not checked$/m, 'run: one STOPPED line for it');
unlike($out, qr/UNREACHABLE/, 'run: and no UNREACHABLE line');
like($out, qr/^hps-monitor: tick hosts=1 duration=/m, 'run: the tick counts the hosts called');
like(slurp("$base/log"), qr/^info HPS-EVENT pri=info kind=monitor subject=\Q$F\E state=stopped hps-monitor: host=\Q$F\E state=STOPPED /m, 'run: logged at info');
is(slurp("$base/stderr"), '', 'run: nothing on stderr');

reset_logs();
($rc, $out) = monitor('loop', '--max-ticks', 1);
is($rc, 0, 'loop, one tick');
is(slurp("$base/run-args"), "--json sch-001.hps.test nagios-check --all\n", 'loop: the stopped node is not called');
is(scalar(() = slurp("$base/log") =~ /state=STOPPED workload=builder/g), 1, 'loop: one STOPPED line');

reset_logs();
($rc, $out) = monitor('run', '--host', 'bld-001');
like(slurp("$base/run-args"), qr/^--json \Q$F\E nagios-check --all$/m, 'run --host: a node the operator names is called, stopped or not');
like($out, qr/host=\Q$F\E state=UNREACHABLE/, 'run --host: and its answer is reported as it is');

# started again: a normal target, no operator action
reset_logs();
$reg->cluster_set('lab', 'workload_builder', wl('running', 'bld-001' => vm('running', $BLD)));
($rc, $out) = monitor('run');
is_deeply([ sort split /\n/, slurp("$base/run-args") ], [ "--json $F nagios-check --all", '--json sch-001.hps.test nagios-check --all' ], 'workload running again: the node is called');
unlike($out, qr/STOPPED/, 'workload running again: no STOPPED line');
like($out, qr/host=\Q$F\E state=UNREACHABLE/, 'a node of a running workload that does not answer is UNREACHABLE, as before');

# the record gone or unreadable: today's behaviour
for my $case ([ 'unreadable record', sub { $reg->cluster_set('lab', 'workload_builder', '{ not json') } ],
              [ 'no record', sub { $reg->cluster_unset('lab', 'workload_builder') } ]) {
    reset_logs();
    $case->[1]->();
    ($rc, $out) = monitor('run');
    is($rc, 0, "$case->[0]: run exits 0");
    like(slurp("$base/run-args"), qr/^--json \Q$F\E nagios-check --all$/m, "$case->[0]: the node is called");
    unlike($out, qr/STOPPED/, "$case->[0]: no STOPPED line");
}

#--- hps-metrics: the STOPPED line read back -----------------------------------------------
my $m = HPS::Metrics::parse_message("hps-monitor: host=$F state=STOPPED workload=builder vm=bld-001 recorded state stopped; not checked");
is($m->{kind}, 'stopped', 'metrics: a STOPPED line');
is($m->{text}, 'workload=builder vm=bld-001 recorded state stopped; not checked', 'metrics: its text');
{
    my $now = timegm(0, 30, 8, 12, 10, 2026);
    my $ev = sub { my ($t, $msg) = @_; strftime('%Y-%m-%dT%H:%M:%S', gmtime $t) . ".123456+00:00 metric ips hps: hps-monitor: $msg\n" };
    my $logd = "$base/mlog";
    make_path($logd);
    spew("$logd/metrics.log", join '',
        $ev->($now - 800, "host=$F check=cpu state=OK CPU OK | busy=5%"),
        $ev->($now - 800, "host=$F checks=1 worst=OK duration=1.0"),
        $ev->($now - 700, "host=$F state=UNREACHABLE hps-run exit 4: host is unreachable"),
        $ev->($now - 100, "host=$F state=STOPPED workload=builder vm=bld-001 recorded state stopped; not checked"),
        $ev->($now - 90,  'host=tch-001.hps.test state=STOPPED workload=nodes vm=t1 recorded state stopped; not checked'),
        $ev->($now - 60,  'host=tch-001.hps.test state=UNREACHABLE timed out'),
        $ev->($now - 50,  'tick hosts=1 duration=1.0'));
    my $mx = HPS::Metrics->new(log_dir => $logd, registry => $reg, now => $now, last_window => 900);
    my %by = map { $_->{host} => $_ } @{ $mx->latest('all')->{hosts} };
    my $b = $by{$F};
    is($b->{worst}, 'STOPPED', 'metrics last: a STOPPED line newer than the UNREACHABLE one wins');
    like($b->{stopped}, qr/\Aworkload=builder /, 'metrics last: with its text');
    is($b->{stopped_at}, strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($now - 100)), 'metrics last: and its time');
    ok(!exists $b->{unreachable}, 'metrics last: the older UNREACHABLE line is not reported');
    is($b->{time}, $b->{stopped_at}, 'metrics last: the host\'s time is the STOPPED line\'s');
    my $t = $by{'tch-001.hps.test'};
    is($t->{worst}, 'UNREACHABLE', 'metrics last: an UNREACHABLE line newer than a STOPPED one wins');
    ok(!exists $t->{stopped}, 'metrics last: the older STOPPED line is not reported');
    my $s = $mx->series('bld-001', hours => 1, step => 300);
    is((grep { defined } @{ $s->{state}{_host} })[-1], 'STOPPED', 'metrics series: STOPPED in the host state');
}

done_testing;
