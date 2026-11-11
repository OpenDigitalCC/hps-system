#!/usr/bin/env perl
# hps-monitor (docs/MONITORING.md): log lines from canned nagios-check replies, the
# interval key, the tick schedule, and that only check names (--all) are sent.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Monitor;
use HPS::ClusterConfig;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/replies");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
my %mac = (sch => 'aabbccddee01', tch => 'aabbccddee02', gone => 'aabbccddee03', held => 'aabbccddee04');
$reg->host_set($mac{sch},  'HOSTNAME', 'sch-001');
$reg->host_set($mac{tch},  'HOSTNAME', 'tch-001');
$reg->host_set($mac{gone}, 'HOSTNAME', 'tch-002');
$reg->host_set($mac{held}, 'HOSTNAME', 'held-001');    # in the registry, not paired
$ENV{HPS_CONFIG_BASE}     = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub spew { open(my $fh, '>', $_[0]) or die $!; print {$fh} $_[1]; close $fh }

# Canned replies, in ctrl-exec-cli --json form (stdout is the nagios-check document).
sub reply {
    my (@checks) = @_;
    my $doc = encode_json({ host => 'x', state => 'OK', code => 0, checks => \@checks });
    return encode_json({ ok => JSON::PP::true, results => [ { exit => 0, stdout => $doc, stderr => '' } ] });
}
sub chk { my ($n, $s, $sum, @p) = @_; return { name => $n, state => $s, code => 0, summary => $sum, perfdata => [@p], long_output => '', duration_ms => 5 } }
sub pd { my ($l, $v, $u) = @_; return { label => $l, value => $v, uom => $u, warn => 1, crit => 2, min => 0, max => 100 } }

spew("$base/replies/sch-001.hps.test", reply(
    chk('disk_root', 'OK', 'DISK OK - free space: / 3000 MiB (60%)', pd('/', 3000, 'MB')),
    chk('mem', 'OK', 'MEM OK - 62% available (9.8 GiB of 15.6 GiB)', pd('available', 10522, 'MB'), pd('available_pct', 62, '%')),
));
spew("$base/replies/tch-001.hps.test", reply(
    chk('load', 'WARNING', 'LOAD WARNING - total load average: 1.60, 1.10, 0.90', pd('load1', 1.6), pd('load5', 1.1)),
    chk('procs', 'OK', 'PROCS OK: 120 processes'),
));

# The runner stub: records its arguments, answers from replies/<fqdn>; tch-002 is not registered.
my $runner = "$base/hps-run.sh";
spew($runner, <<"SH");
#!/bin/sh
echo "\$*" >> '$base/run-args'
for last; do :; done
host=\$2
if [ -f '$base/replies/'"\$host" ]; then cat '$base/replies/'"\$host"; exit 0; fi
echo "hps-run: \$host -> agent \$host, script nagios-check" >&2
echo "hps-run: no registered agent for \$host; expected the FQDN" >&2
exit 4
SH
chmod 0755, $runner;
my $agents = "$base/agents.sh";
spew($agents, "#!/bin/sh\nprintf '%s\\n' ips.hps.test sch-001.hps.test tch-001.hps.test tch-002.hps.test stale-old.hps.test\n");
chmod 0755, $agents;
my $logger = "$base/logger.sh";
spew($logger, "#!/bin/sh\necho \"\$1 \$2\" >> '$base/log'\n");
chmod 0755, $logger;
$ENV{HPS_MONITOR_RUN}    = $runner;
$ENV{HPS_MONITOR_AGENTS} = $agents;
$ENV{HPS_MONITOR_LOGGER} = $logger;

sub monitor { my $out = `perl $Bin/../bin/hps-monitor @_ 2>$base/stderr`; return ($? >> 8, $out) }
sub reset_logs { unlink "$base/log", "$base/run-args" }

# --- run: every paired node, once, lines exact ------------------------------------------
my ($rc, $out) = monitor('run');
is($rc, 0, 'run exits 0');
my @lines = split /\n/, $out;
my @logged = map { s/^\S+ //r } split /\n/, slurp("$base/log");
is_deeply(\@logged, \@lines, 'stdout carries exactly the lines that went to the logger');

my $d = qr/\d+\.\d/;
like($lines[0], qr/^hps-monitor: host=sch-001\.hps\.test check=disk_root state=OK DISK OK - free space: \/ 3000 MiB \(60%\) \| \/=3000MB$/, 'OK check line with perfdata');
is($lines[1], 'hps-monitor: host=sch-001.hps.test check=mem state=OK MEM OK - 62% available (9.8 GiB of 15.6 GiB) | available=10522MB available_pct=62%', 'two perfdata items, compact');
like($lines[2], qr/^hps-monitor: host=sch-001\.hps\.test checks=2 worst=OK duration=$d$/, 'host summary, OK');
is($lines[3], 'hps-monitor: host=tch-001.hps.test check=load state=WARNING LOAD WARNING - total load average: 1.60, 1.10, 0.90 | load1=1.6 load5=1.1', 'WARNING check line');
is($lines[4], 'hps-monitor: host=tch-001.hps.test check=procs state=OK PROCS OK: 120 processes', 'no perfdata: no separator');
like($lines[5], qr/^hps-monitor: host=tch-001\.hps\.test checks=2 worst=WARNING duration=$d$/, 'host summary, worst is WARNING');
like($lines[6], qr/^hps-monitor: host=tch-002\.hps\.test state=UNREACHABLE hps-run exit 4: hps-run: no registered agent for tch-002\.hps\.test/, 'unreachable host: one line with the reason');
like($lines[7], qr/^hps-monitor: tick hosts=3 duration=$d$/, 'tick line');
is(scalar @lines, 8, 'nothing else');
is_deeply([ map { (split ' ')[0] } split /\n/, slurp("$base/log") ],
    [ qw(info info info warning info warning err info) ], 'priorities: OK info, WARNING warning, unreachable err');
my @args = split /\n/, slurp("$base/run-args");
is_deeply([ sort @args ], [ '--json sch-001.hps.test nagios-check --all', '--json tch-001.hps.test nagios-check --all', '--json tch-002.hps.test nagios-check --all' ],
    'the node is sent the script name and --all only; IPS, unpaired and stale hosts are not called');

# --- run --host --------------------------------------------------------------------------
reset_logs();
($rc, $out) = monitor('run', '--host', 'tch-001', '--parallel', 1);
is($rc, 0, 'run --host exits 0');
@lines = split /\n/, $out;
is(scalar @lines, 4, 'one host: two checks, summary, tick');
is(slurp("$base/run-args"), "--json tch-001.hps.test nagios-check --all\n", 'a HOSTNAME is resolved to its FQDN');
reset_logs();
($rc, $out) = monitor('run', '--host', 'sch-001.hps.test', '--host', 'tch-002');
like($out, qr/host=tch-002\.hps\.test state=UNREACHABLE/, 'several --host');

# --- the interval -----------------------------------------------------------------------
is_deeply([ HPS::Monitor::interval(undef) ], [ 60, undef ], 'unset: default 60');
is_deeply([ HPS::Monitor::interval('0') ], [ 0, undef ], '0 disables');
is_deeply([ HPS::Monitor::interval('30') ], [ 30, undef ], 'an interval of 30');
is_deeply([ HPS::Monitor::interval('10') ], [ 10, undef ], 'lower bound 10');
is_deeply([ HPS::Monitor::interval('86400') ], [ 86400, undef ], 'upper bound 86400');
for my $bad (qw(9 1 86401 abc -5 1.5)) {
    my ($v, $w) = HPS::Monitor::interval($bad);
    is($v, 60, "'$bad': default 60");
    like($w, qr/monitor_interval_seconds='\Q$bad\E'/, "'$bad': a warning names the value");
}
my $q = HPS::ClusterConfig::question('monitor_interval_seconds');
is($q->{default}, '60', 'catalogue default 60');
is($q->{rule}, 'int0:10..86400', 'catalogue rule');
is(HPS::ClusterConfig::validate_value($q, $_), undef, "valid: $_") for qw(0 10 30 86400);
isnt(HPS::ClusterConfig::validate_value($q, $_), undef, "refused: $_") for qw(1 9 86401 -1 x 007);

($rc, $out) = monitor('interval');
is($out, "60\n", 'interval: key unset gives 60');
$reg->cluster_set('lab', 'monitor_interval_seconds', '30');
($rc, $out) = monitor('interval');
is($out, "30\n", 'interval: the lab value');

is(HPS::Monitor::missed_ticks(5, 30), 0, 'a run inside its interval misses nothing');
is(HPS::Monitor::missed_ticks(30, 30), 1, 'a run of one interval skips the next tick');
is(HPS::Monitor::missed_ticks(95, 30), 3, 'a long run skips every tick it covered');

# --- loop ----------------------------------------------------------------------------------
reset_logs();
$reg->cluster_set('lab', 'monitor_interval_seconds', '0');
($rc, $out) = monitor('loop', '--max-ticks', 1);
is($rc, 0, 'loop with 0 exits cleanly after its tick limit');
ok(!-e "$base/run-args", 'interval 0: no node is called');
is(scalar(() = slurp("$base/log") =~ /disabled \(monitor_interval_seconds=0\)/g), 1, 'disabled is logged once');
is($out, '', 'loop prints nothing (supervisor logs stdout; the logger has the lines)');

reset_logs();
$reg->cluster_set('lab', 'monitor_interval_seconds', '10');
($rc, $out) = monitor('loop', '--max-ticks', 1);
is($rc, 0, 'loop, one tick');
like(slurp("$base/log"), qr/hps-monitor: tick hosts=3 duration=$d/, 'the tick line is logged');
unlike(slurp("$base/log"), qr/tick skipped/, 'no skipped tick when the run is quick');

reset_logs();
my $slow = "$base/slow.sh";
spew($slow, "#!/bin/sh\nsleep 11\ncat '$base/replies/sch-001.hps.test'\n");
chmod 0755, $slow;
{
    local $ENV{HPS_MONITOR_RUN} = $slow;
    local $ENV{HPS_MONITOR_AGENTS} = "$base/agents-one.sh";
    spew("$base/agents-one.sh", "#!/bin/sh\necho sch-001.hps.test\n");
    chmod 0755, "$base/agents-one.sh";
    ($rc, $out) = monitor('loop', '--max-ticks', 1);
}
like(slurp("$base/log"), qr/warning hps-monitor: tick skipped missed=1 run=11\.\d+s interval=10s/, 'a run longer than the interval logs one skipped-tick line');

($rc, $out) = monitor('frobnicate');
is($rc, 2, 'unknown command is a usage error');

done_testing;
