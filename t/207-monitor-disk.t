#!/usr/bin/env perl
# hps-monitor disk grading (docs/MONITORING.md): the thresholds from the cluster
# keys, the nodes' disk_* and zpool_cap graded again on the IPS, df parsing and
# the IPS's own resources and log checks, end to end through bin/hps-monitor.
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

#--- thresholds --------------------------------------------------------------------------
is_deeply([ HPS::Monitor::disk_thresholds(undef, undef) ], [ 80, 90, undef ], 'unset: 80 and 90, no warning');
is_deeply([ HPS::Monitor::disk_thresholds('70', '85') ], [ 70, 85, undef ], 'the keys');
is_deeply([ HPS::Monitor::disk_thresholds('70', undef) ], [ 70, 90, undef ], 'only warn set');
for my $bad ([ '90', '80' ], [ '90', '90' ], [ '0', '90' ], [ 'x', '90' ], [ '80', '101' ], [ '95', undef ]) {
    my ($w, $c, $why) = HPS::Monitor::disk_thresholds(@$bad);
    is_deeply([ $w, $c ], [ 80, 90 ], "warn=$bad->[0] crit=" . ($bad->[1] // 'unset') . ': both defaults');
    like($why, qr/monitor_disk_(?:warn|crit)_pct.*using 80 and 90/, '... with a warning naming the key');
}
for my $k (qw(monitor_disk_warn_pct monitor_disk_crit_pct)) {
    my $q = HPS::ClusterConfig::question($k);
    ok($q, "$k is in the catalogue");
    is($q->{rule}, 'int:1..100', "$k: rule");
    unlike($k, HPS::ClusterConfig::secret_name_re(), "$k is not a secret name");
}
is(HPS::ClusterConfig::question('monitor_disk_warn_pct')->{default}, '80', 'warn default 80');
is(HPS::ClusterConfig::question('monitor_disk_crit_pct')->{default}, '90', 'crit default 90');

#--- which checks are disk checks ----------------------------------------------------------
ok(HPS::Monitor::is_disk_check($_), "$_ is graded") for qw(disk_var_lib_containers disk_other zpool_cap);
ok(!HPS::Monitor::is_disk_check($_), "$_ is not") for qw(disk_root mem zpool zpool_io diskio);

#--- regrade -------------------------------------------------------------------------------
sub pd { my ($l, $v, $u) = @_; return { label => $l, value => $v, uom => $u // '%' } }
sub reply {
    my (@checks) = @_;
    my $doc = encode_json({ state => 'OK', checks => \@checks });
    return encode_json({ ok => JSON::PP::true, results => [ { exit => 0, stdout => $doc } ] });
}
sub chk { my ($n, $s, $sum, @p) = @_; return { name => $n, state => $s, summary => $sum, perfdata => [@p] } }

my $text = reply(
    chk('disk_var_lib_containers', 'OK', 'DISK OK - /var/lib/containers 75% used (7.5 GiB of 10.0 GiB), inodes 3%', pd('used_pct', 75), pd('inode_pct', 3), pd('used', 7, 'B')),
    chk('disk_other', 'WARNING', 'DISK WARNING - 1 filesystems: /srv 85%', pd('srv_used_pct', 85), pd('srv_inode_pct', 10)),
    chk('zpool_cap', 'OK', 'ZPOOL_CAP OK - 1 pools: lab 72%', pd('lab_cap', 72)),
    chk('disk_var_lib_hps_ips', 'OK', 'DISK OK - /var/lib/hps-ips not mounted (on the RAM root; disk_root watches it)'),
    chk('disk_root', 'OK', 'DISK OK - free space: / 100 MiB (5%)', pd('/', 100, 'MB')),
    chk('mem', 'OK', 'MEM OK', pd('available_pct', 3)),
);
my $p = HPS::Monitor::parse_reply(0, $text);
is_deeply($p->{checks}[0]{pcts}, [ 75, 3 ], 'the fill figures are kept: used_pct and inode_pct, % only');
is_deeply($p->{checks}[1]{pcts}, [ 85, 10 ], '... a prefixed label (disk_other)');
is_deeply($p->{checks}[2]{pcts}, [ 72 ], '... <pool>_cap');

HPS::Monitor::regrade($p, 80, 90);
is($p->{checks}[0]{state}, 'OK', 'default grades: 75% stays OK');
is($p->{checks}[1]{state}, 'WARNING', 'default grades: 85% stays WARNING, summary unchanged');
is($p->{checks}[1]{summary}, 'DISK WARNING - 1 filesystems: /srv 85%', '... summary untouched when the state holds');

$p = HPS::Monitor::parse_reply(0, $text);
HPS::Monitor::regrade($p, 70, 84);
is($p->{checks}[0]{state}, 'WARNING', 'warn 70: 75% is WARNING on the IPS');
is($p->{checks}[0]{summary}, 'DISK WARNING - /var/lib/containers 75% used (7.5 GiB of 10.0 GiB), inodes 3% (graded at warn 70% crit 84%)', '... the state word and a note');
is($p->{checks}[1]{state}, 'CRITICAL', 'crit 84: 85% is CRITICAL');
is($p->{checks}[2]{state}, 'WARNING', 'zpool_cap 72% at warn 70: WARNING');
is($p->{checks}[3]{state}, 'OK', 'not mounted (no figures): unchanged');
is($p->{checks}[4]{state}, 'OK', 'disk_root (RAM, free-space style) is not regraded');
is($p->{checks}[5]{state}, 'OK', 'mem is not regraded');

$p = HPS::Monitor::parse_reply(0, $text);
HPS::Monitor::regrade($p, 95, 99);
is($p->{checks}[1]{state}, 'OK', 'warn 95: the node\'s WARNING at 85% becomes OK');

$p = HPS::Monitor::parse_reply(0, reply(chk('disk_other', 'UNKNOWN', 'DISK UNKNOWN - statfs /srv failed', pd('srv_used_pct', 99))));
HPS::Monitor::regrade($p, 80, 90);
is($p->{checks}[0]{state}, 'UNKNOWN', 'an UNKNOWN check is never regraded');

#--- df ----------------------------------------------------------------------------------
my $df  = "Filesystem 1-blocks Used Available Capacity Mounted on\n/dev/vdc1 105087164416 99503210496 198561792 100% /srv/projects\n";
my $dfi = "Filesystem Inodes IUsed IFree IUse% Mounted on\n/dev/vdc1 6553600 2225151 4328449 34% /srv/projects\n";
my $fs = HPS::Monitor::parse_df($df, $dfi);
is($fs->{pct}, 100, 'df: used / (used + available), rounded up, as df shows it');
is($fs->{ipct}, 34, 'df -i: inodes used');
is($fs->{mount}, '/srv/projects', 'df: the mount point');
is(HPS::Monitor::parse_df("Filesystem 1-blocks Used Available Capacity Mounted on\n/x 0 0 0 - /x\n", "Filesystem Inodes IUsed IFree IUse% Mounted on\nx 0 0 0 - /x\n")->{ipct}, undef, 'no fixed inode count: no inode figure');
is(HPS::Monitor::parse_df("df: /nope: No such file or directory\n"), undef, 'df failing: undef');

my $c = HPS::Monitor::fs_check('disk_log', '/srv/hps-log', $fs, 80, 90);
is($c->{state}, 'CRITICAL', 'fs_check: 100% is CRITICAL');
is($c->{summary}, 'DISK CRITICAL - /srv/hps-log 100% used (92.7 GiB of 97.9 GiB), inodes 34% on /srv/projects', 'fs_check: summary like the node plugin, naming the mount');
is($c->{perf}, 'used_pct=100% inode_pct=34% used=99503210496B size=105087164416B', 'fs_check: perfdata like the node plugin');
$fs->{pct} = 20;
$fs->{ipct} = 85;
is(HPS::Monitor::fs_check('disk_log', '/srv/hps-log', $fs, 80, 90)->{state}, 'WARNING', 'fs_check: inodes alone make a WARNING');
$c = HPS::Monitor::fs_check('disk_log', '/nope', undef, 80, 90, 'does not exist');
is($c->{state}, 'UNKNOWN', 'fs_check: no figures is UNKNOWN');
is($c->{summary}, 'DISK UNKNOWN - /nope: does not exist', '... with the reason');

#--- end to end: bin/hps-monitor run -------------------------------------------------------
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/res", "$base/log");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
$reg->host_set('aabbccddee01', 'HOSTNAME', 'cnh-001');
sub spew { open(my $fh, '>', $_[0]) or die $!; print {$fh} $_[1]; close $fh }
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
spew("$base/reply", reply(chk('disk_var_lib_containers', 'OK', 'DISK OK - /var/lib/containers 75% used', pd('used_pct', 75))));
spew("$base/run.sh", "#!/bin/sh\ncat '$base/reply'\n");
spew("$base/agents.sh", "#!/bin/sh\necho cnh-001.hps.test\n");
spew("$base/logger.sh", "#!/bin/sh\necho \"\$1 \$2\" >> '$base/logged'\n");
# df: the resources filesystem 85% full, the log filesystem 50%, inodes 10%
spew("$base/df.sh", <<"SH");
#!/bin/sh
for a; do p=\$a; done
case "\$*" in
  *-i*) printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\\n/dev/x 100 10 90 10%% /srv\\n' ;;
  *) case "\$p" in
       */res) printf 'Filesystem 1-blocks Used Available Capacity Mounted on\\n/dev/x 100 85 15 85%% /srv\\n' ;;
       *) printf 'Filesystem 1-blocks Used Available Capacity Mounted on\\n/dev/x 100 50 50 50%% /srv\\n' ;;
     esac ;;
esac
SH
chmod 0755, map { "$base/$_" } qw(run.sh agents.sh logger.sh df.sh);
local $ENV{HPS_CONFIG_BASE}     = $base;
local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
local $ENV{HPS_MONITOR_RUN}     = "$base/run.sh";
local $ENV{HPS_MONITOR_AGENTS}  = "$base/agents.sh";
local $ENV{HPS_MONITOR_LOGGER}  = "$base/logger.sh";
local $ENV{HPS_MONITOR_DF}      = "$base/df.sh";
local $ENV{HPS_RESOURCES}       = "$base/res";
local $ENV{HPS_LOG}             = "$base/log";

my $out = `$^X $Bin/../bin/hps-monitor run 2>/dev/null`;
like($out, qr/^hps-monitor: host=cnh-001\.hps\.test check=disk_var_lib_containers state=OK /m, 'node disk check at the defaults: OK');
like($out, qr/^hps-monitor: host=ips\.hps\.test check=disk_resources state=WARNING DISK WARNING - \Q$base\E\/res 85% used/m, 'the IPS resources filesystem at 85%: WARNING');
like($out, qr/^hps-monitor: host=ips\.hps\.test check=disk_log state=OK /m, 'the IPS log filesystem at 50%: OK');
like($out, qr/^hps-monitor: host=ips\.hps\.test checks=2 worst=WARNING /m, 'the IPS summary line');
like(slurp("$base/logged"), qr/^warning hps-monitor: host=ips\.hps\.test check=disk_resources /m, 'a WARNING goes to syslog at warning');

$reg->cluster_set('lab', 'monitor_disk_warn_pct', '70');
$reg->cluster_set('lab', 'monitor_disk_crit_pct', '80');
$out = `$^X $Bin/../bin/hps-monitor run 2>/dev/null`;
like($out, qr/check=disk_var_lib_containers state=WARNING DISK WARNING - \/var\/lib\/containers 75% used \(graded at warn 70% crit 80%\)/, 'keys 70/80: the node\'s 75% is a WARNING');
like($out, qr/check=disk_resources state=CRITICAL /, 'keys 70/80: the IPS\'s 85% is CRITICAL');

$reg->cluster_set('lab', 'monitor_disk_warn_pct', '90');
$out = `$^X $Bin/../bin/hps-monitor run 2>/dev/null`;
like($out, qr/^hps-monitor: monitor_disk_warn_pct=90 is not below monitor_disk_crit_pct=80; using 80 and 90$/m, 'a bad pair is a warning line, and the defaults grade');
like($out, qr/check=disk_resources state=WARNING /, '... 85% is WARNING again');

$out = `$^X $Bin/../bin/hps-monitor run --host cnh-001 2>/dev/null`;
unlike($out, qr/host=ips\./, 'run --host: the IPS is not checked');

done_testing;
