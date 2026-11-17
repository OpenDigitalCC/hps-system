#!/usr/bin/env perl
# One hps-monitor result is one syslog record, whole: a `vms` result of a host with 64
# guests (about 12 KB) is passed to logger with --size, and the IPS's rsyslog takes it
# (maxMessageSize). A line over HPS_MONITOR_LINE_MAX is cut at a token boundary, marked
# hps_truncated=<bytes dropped>, logged by the monitor, and hps-metrics reports it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Metrics;
use HPS::Registry;

my $base = tempdir(CLEANUP => 1);
sub slurp { open(my $f, '<', $_[0]) or return ''; local $/; my $t = <$f>; return $t }
sub spew  { my $p = shift; open(my $f, ">", $p) or die; print {$f} @_; close $f }

# the emit code of bin/hps-monitor, as it is in the file
my $src = slurp("$Bin/../bin/hps-monitor");
my ($code) = $src =~ /^(sub line_max .*?\nsub emit \{.*?\n\}\n)/ms or BAIL_OUT('emit not found in bin/hps-monitor');
our $QUIET = 1;
{ no strict; no warnings; eval "package Mon; our \$QUIET = 1; $code; 1" or BAIL_OUT($@) }

# a logger that records its arguments, one record per call, size and message
my $stub = "$base/logger.sh";
# the stub is called as <cmd> <priority> <line>
spew($stub, "#!/bin/sh\nprintf '%s\\n' \"\$2\" >> '$base/msgs'\nprintf '%s\\n' \"\$1\" >> '$base/prios'\n");
chmod 0755, $stub;

my @labels = qw(cpu_pct rss mem vcpus rd_Bps wr_Bps rx_Bps tx_Bps);
sub vms_line {
    my ($n) = @_;
    my $perf = join ' ', 'vms=' . $n, map { my $g = sprintf('guest-%03d', $_); map { "${g}_$_=1234567" } @labels } 1 .. $n;
    return "hps-monitor: host=tch-001.hps.test check=vms state=OK $n guests | $perf";
}
sub msgs { return split /\n/, slurp("$base/msgs") }
sub reset_logs { unlink "$base/msgs", "$base/prios" }

local $ENV{HPS_MONITOR_LOGGER} = $stub;

# 64 guests: whole
my $line = vms_line(64);
cmp_ok(length $line, '>', 8192, 'the 64-guest line is longer than rsyslog\'s default 8k');
reset_logs();
Mon::emit('info', $line);
my @m = msgs();
is(scalar @m, 1, '64 guests: one record');
is($m[0], $line, '64 guests: stored whole, nothing cut or marked');

# 128 guests also fit the default limit
$line = vms_line(128);
reset_logs();
Mon::emit('info', $line);
@m = msgs();
is($m[0], $line, '128 guests: stored whole');

# the default logger command gets --size and the cap with room
{
    local $ENV{HPS_MONITOR_LOGGER};
    delete $ENV{HPS_MONITOR_LOGGER};
    my $bin = "$base/bin"; make_path($bin);
    spew("$bin/logger", "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> '$base/real-args'\n");
    chmod 0755, "$bin/logger";
    local $ENV{PATH} = "$bin:$ENV{PATH}";
    Mon::emit('info', 'hps-monitor: host=x check=a state=OK fine');
    like(slurp("$base/real-args"), qr/^-t hps --size 32512 -p local0\.info -- hps-monitor: host=x /, 'logger -t hps --size <cap + 512> -p local0.<prio> -- <line>');
}

# over the limit: cut at a token, marked, announced
{
    local $ENV{HPS_MONITOR_LINE_MAX} = 2000;
    my $long = vms_line(64);
    reset_logs();
    Mon::emit('info', $long);
    my @r = msgs();
    is(scalar @r, 2, 'over the limit: the record and the monitor\'s own warning');
    cmp_ok(length $r[0], '<=', 2000, 'the record is within the limit');
    my ($dropped) = $r[0] =~ / hps_truncated=([0-9]+)\z/;
    ok(defined $dropped, 'the record ends in hps_truncated=<bytes dropped>');
    like($r[0], qr/=1234567 hps_truncated=/, 'cut at a token boundary');
    my $kept = $r[0] =~ s/ hps_truncated=[0-9]+\z//r;
    is(length($kept) + $dropped, length $long, 'kept plus dropped is the whole line (the join space counts as dropped)') or diag length($kept) . " + $dropped vs " . length $long;
    like($r[1], qr/^hps-monitor: record for tch-001\.hps\.test cut at 2000 bytes \(\d+ dropped, marked hps_truncated/, 'the monitor logs the cut');
    my @p = split /\n/, slurp("$base/prios");
    is($p[1], 'warning', 'as a warning');
}

# hps-metrics: the cut record is reported, the figures that are there are read
{
    my $now = timegm(0, 30, 8, 12, 10, 2026);
    my $ev = sub { my ($t, $msg) = @_; strftime('%Y-%m-%dT%H:%M:%S', gmtime $t) . ".123456+00:00 metric ips hps: $msg\n" };
    my $cut = do { local $ENV{HPS_MONITOR_LINE_MAX} = 1200; reset_logs(); Mon::emit('info', vms_line(64)); (msgs())[0] };
    my $logd = "$base/mlog";
    make_path($logd);
    spew("$logd/metrics.log",
        $ev->($now - 60, $cut),
        $ev->($now - 59, 'hps-monitor: host=tch-001.hps.test check=cpu state=OK CPU OK | busy=5%'),
        $ev->($now - 58, 'hps-monitor: host=tch-001.hps.test checks=2 worst=OK duration=1.0'));
    # the lines are in time order: run one = vms, cpu, summary
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
    $reg->host_set('aabbccddee02', 'HOSTNAME', 'tch-001');
    local $ENV{HPS_LOG} = $logd;
    local $ENV{HPS_CONFIG_BASE} = $base;
    local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
    my $mx = HPS::Metrics->new(log_dir => $logd, registry => $reg, now => $now, last_window => 900);
    my ($h) = @{ $mx->latest('all')->{hosts} };
    my ($v) = grep { $_->{check} eq 'vms' } @{ $h->{checks} };
    ok($v->{truncated} > 0, 'metrics last: the vms check carries truncated=<bytes>');
    ok(!exists $v->{perf}{hps_truncated}, 'metrics last: the mark is not a perfdata figure');
    ok(exists $v->{perf}{'guest-001_cpu_pct'}, 'metrics last: the guests that were stored are read');
    my ($c) = grep { $_->{check} eq 'cpu' } @{ $h->{checks} };
    ok(!exists $c->{truncated}, 'metrics last: a whole record has no mark');
    my $out = `$^X -I$Bin/../lib/perl $Bin/../bin/hps-metrics last tch-001 2>&1`;
    like($out, qr/# TRUNCATED: the record of vms was cut by hps-monitor, \d+ bytes of perfdata are not stored/, 'hps-metrics last says so')
        or diag $out;
}

# the IPS's rsyslog takes the whole record
like(slurp("$Bin/../lib/functions.d/create-config-rsyslog.sh"), qr/global\(\n\s+workDirectory=[^\n]+\n\s+maxMessageSize="64k"/, 'the generated rsyslog.conf sets maxMessageSize 64k in global()');

done_testing;
