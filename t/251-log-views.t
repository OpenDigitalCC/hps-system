#!/usr/bin/env perl
# HPS::Log views (docs/LOGGING.md): gzip-transparent day files, rotated view
# files, events_log, audit_log, the event line parser, the metrics.log form,
# attention (every status), and the --since units. A temp log tree.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Compress::Gzip qw(gzip $GzipError);
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;
use HPS::Log;

my $base = tempdir(CLEANUP => 1);
my $logd = "$base/log";
make_path($logd);

sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }
sub gz { my ($f, @l) = @_; my $text = join '', map { "$_\n" } @l; gzip(\$text => $f) or die "gzip: $GzipError" }
# line($time, $host, $pri, $kind, $subject, $state, $text): an events.log line;
# $time is HH:MM:SS of 2026-11-12 or a full RFC 3339 time.
sub line {
    my ($tm, $host, $pri, $kind, $subj, $state, $text) = @_;
    $tm = "2026-11-12T${tm}Z" unless $tm =~ /T/;
    return "$tm $host " . HPS::Event::marker($pri) . " pri=$pri kind=$kind subject=$subj state=$state $text";
}

my $now = timegm(0, 0, 10, 12, 10, 2026);    # 2026-11-12 10:00:00 UTC

#--- parsers ----------------------------------------------------------------------------
my $r = HPS::Log::parse_event('2026-11-12T08:00:00.123+01:00 ips.lab HPS-ALERT pri=warning kind=issue subject=zfs-vdev state=open hps-issue: opened I-1');
is($r->{epoch}, timegm(0, 0, 7, 12, 10, 2026), 'parse_event: the offset is converted');
is($r->{host}, 'ips.lab', 'parse_event: host');
is($r->{tag}, 'hps-issue', 'parse_event: the tag is the first word of the text');
is($r->{ev}{kind}, 'issue', 'parse_event: ev');
like($r->{message}, qr/\AHPS-ALERT pri=warning/, 'parse_event: the message starts at the marker');
is(HPS::Log::parse_event('2026-11-12T08:00:00Z ips.lab HPS-ALERT pri=nope kind=issue subject=x state=open t'), undef, 'parse_event: a bad word is not an event');
is(HPS::Log::parse_event('2026-11-12T08:00:00Z ips.lab no marker here'), undef, 'parse_event: no marker');
is(HPS::Log::parse_event('garbage'), undef, 'parse_event: not a line');
$r = HPS::Log::parse_event('2026-11-12T08:00:00Z metric ips hps: hps-monitor: host=x check=mem state=OK');
is($r->{event}, 'metric', 'parse_event: the metrics.log form keeps its event word');
ok(!$r->{ev}, 'parse_event: ... and has no ev');
$r = HPS::Log::parse_event('2026-11-12T08:00:00Z dhcp ips dnsmasq-dhcp: DHCPACK');
is($r->{event}, 'dhcp', 'parse_event: a lab collector event word');
$r = HPS::Log::parse_audit('2026-11-12T08:00:00Z 10.1.2.3 [s3.ips] ctrl-exec-api[44]:  ACTION=run EXIT=0');
is_deeply([ @$r{qw(from host tag message)} ], [ '10.1.2.3', 's3.ips', 'ctrl-exec-api', 'ACTION=run EXIT=0' ], 'parse_audit');
is(HPS::Log::parse_audit('Nov 12 08:00:00 x'), undef, 'parse_audit: a syslog line is not one');

#--- level of an event line -----------------------------------------------------------------
is(HPS::Log::level('HPS-ALERT pri=urgent kind=issue subject=x state=open all fine, no errors'), 'error', 'level: urgent is error whatever the text');
is(HPS::Log::level('HPS-ALERT pri=warning kind=issue subject=x state=open t'), 'warning', 'level: warning');
is(HPS::Log::level('HPS-EVENT pri=notice kind=job subject=x state=failed t'), 'info', 'level: notice is info');

#--- gz day files ----------------------------------------------------------------------------
make_path("$logd/ips/hps");
gz("$logd/ips/hps/2026-11-11.log.gz", 'Nov 11 23:00:00 127.0.0.1 [ips] hps: from the gz file');
spew("$logd/ips/hps/2026-11-12.log", 'Nov 12 08:00:00 127.0.0.1 [ips] hps: from the plain file');
spew("$logd/ips/hps/2026-11-10.log", 'Nov 10 08:00:00 127.0.0.1 [ips] hps: plain and gz');
gz("$logd/ips/hps/2026-11-10.log.gz", 'Nov 10 08:00:00 127.0.0.1 [ips] hps: the gz of the same day, not read');
my @f = HPS::Log::_day_files("$logd/ips/hps");
is_deeply([ map { $_->[0] =~ s{.*/}{}r } @f ], [ '2026-11-12.log', '2026-11-11.log.gz', '2026-11-10.log' ], '_day_files: gz included, plain preferred, newest first');
my $log = HPS::Log->new(log_dir => $logd, now => $now);
$r = $log->ips_log;
is_deeply([ map { $_->{message} } @{ $r->{lines} } ], [ 'plain and gz', 'from the gz file', 'from the plain file' ], 'ips_log reads through a gz day file');

#--- a damaged gz file is reported, never "no lines" --------------------------------------------
open(my $bad, '>', "$logd/ips/hps/2026-11-09.log.gz") or die; print {$bad} "this is not gzip data\n"; close $bad;
$log = HPS::Log->new(log_dir => $logd, now => $now);
$r = $log->ips_log;
ok(scalar @{ $log->{unreadable} // [] }, 'a damaged gz file is noted as unreadable');
unlink "$logd/ips/hps/2026-11-09.log.gz";

#--- a big gz file: the newest bytes are read, and it is said ---------------------------------
gz("$logd/ips/hps/2026-11-08.log.gz", map { sprintf("Nov  8 08:%02d:00 127.0.0.1 [ips] hps: line %02d", $_, $_) } 0 .. 59);
$log = HPS::Log->new(log_dir => $logd, now => $now, gz_window => 400);
$r = $log->ips_log(since => "10d", lines => 500, grep => "line");
is($r->{truncated} ? 1 : 0, 1, "a gz file larger than the window: truncated is said");
ok(scalar(@{ $r->{lines} }) < 60 && $r->{lines}[-1]{message} =~ /line 59/, "... and the newest lines of it were read");
unlink "$logd/ips/hps/2026-11-08.log.gz";

#--- view_files ---------------------------------------------------------------------------------
spew("$logd/events.log", 'x');
spew("$logd/events-2026-11-11.log", 'x');
gz("$logd/events-2026-11-11.log.gz", 'x');
gz("$logd/events-2026-11-10.log.gz", 'x');
gz("$logd/events-2026-11-10.1.log.gz", 'x');
spew("$logd/events-bogus.log", 'x');
spew("$logd/audit.log", 'x');
is_deeply([ map { $_->[0] =~ s{.*/}{}r } HPS::Log::view_files($logd, 'events') ],
    [ 'events.log', 'events-2026-11-11.log', 'events-2026-11-10.1.log.gz', 'events-2026-11-10.log.gz' ],
    'view_files: the live file, then rotated newest first (sequence after the plain day), plain before gz');
is_deeply([ HPS::Log::view_files($logd, 'metrics') ], [], 'view_files: none');
unlink map { "$logd/$_" } qw(events.log events-2026-11-11.log events-2026-11-11.log.gz events-2026-11-10.log.gz events-2026-11-10.1.log.gz events-bogus.log audit.log);

#--- events and audit over rotated files ----------------------------------------------------------
spew("$logd/events.log",
    line('09:30:00', 'ips.lab', 'info', 'job', 'j9', 'ended', 'hps-jobs: job j9 end'),
    'junk line that is skipped',
    '2026-11-12T09:31:00Z dhcp ips dnsmasq-dhcp: a lab collector line stays readable',
);
gz("$logd/events-2026-11-11.log.gz",
    line('2026-11-11T00:00:00Z', 'ips.lab', 'info', 'job', 'j1', 'ended', 'hps-jobs: yesterday'),
);
$log = HPS::Log->new(log_dir => $logd, now => $now);
$r = $log->events_log;
is($r->{target}, 'events', 'events_log: target');
is_deeply($r->{sources}, ['events'], 'events_log: source');
is(scalar @{ $r->{lines} }, 3, 'events_log: the parsable lines of the live and the rotated file');
is($r->{lines}[0]{message}, 'HPS-EVENT pri=info kind=job subject=j1 state=ended hps-jobs: yesterday', 'events_log: the rotated gz file is read first (oldest)');
is($r->{lines}[1]{kind}, 'job', 'events_log: kind in the entry');
is($r->{lines}[1]{subject}, 'j9', 'events_log: subject in the entry');
is($r->{lines}[1]{text}, 'hps-jobs: job j9 end', 'events_log: text in the entry');
$r = $log->events_log(since => '30m');
is(scalar @{ $r->{lines} }, 2, 'events_log: --since 30m leaves out the day before');
is($r->{since_minutes}, 30, 'events_log: since_minutes');
$r = $log->events_log(grep => 'j9');
is(scalar @{ $r->{lines} }, 1, 'events_log: --grep');
$r = HPS::Log->new(log_dir => "$base/none", now => $now)->events_log;
is(scalar @{ $r->{lines} }, 0, 'events_log: no file, no lines (attention is the verb that says why)');

spew("$logd/audit.log", '2026-11-12T09:00:00Z 10.1.2.3 [s3.ips] ctrl-exec-api[44]:  ACTION=run EXIT=0 SCRIPT=hps-workload');
$r = $log->audit_log;
is($r->{lines}[0]{tag}, 'ctrl-exec-api', 'audit_log: tag');
is($r->{lines}[0]{message}, 'ACTION=run EXIT=0 SCRIPT=hps-workload', 'audit_log: message');
is($r->{target}, 'audit', 'audit_log: target');
unlink "$logd/events.log", "$logd/events-2026-11-11.log.gz", "$logd/audit.log";

#--- --since units -----------------------------------------------------------------------------------
is(HPS::Log::options(since => '1h')->{since}, 60, '--since 1h');
is(HPS::Log::options(since => '2d')->{since}, 2880, '--since 2d');
is(HPS::Log::options(since => '45m')->{since}, 45, '--since 45m');
is(HPS::Log::options(since => '45')->{since}, 45, '--since 45 (minutes)');
for my $bad ('0', '1x', 'h', '31d', '-1h', '1.5h', '') {
    my $ok = eval { HPS::Log::options(since => $bad); 1 };
    ok(!$ok && ref $@ && $@->kind eq 'usage', "--since '$bad' is a usage error");
}

#--- attention -----------------------------------------------------------------------------------------
sub fresh { my $d = shift; make_path($d); return HPS::Log->new(log_dir => $d, now => $now) }

# absent
my $a = fresh("$base/a")->attention;
is($a->{status}, 'absent', 'attention: no events.log is absent, not clear');
like($a->{reason}, qr/no events\.log/, 'attention: absent has a reason');

# empty
spew("$base/b/events.log") if make_path("$base/b");
$a = fresh("$base/b")->attention;
is($a->{status}, 'empty', 'attention: an empty events.log is empty, not clear');

# unreadable
make_path("$base/c");
open(my $badz, '>', "$base/c/events-2026-11-11.log.gz") or die; print {$badz} "not gzip\n"; close $badz;
spew("$base/c/events.log", line('09:50:00', 'ips.lab', 'info', 'service', 'hps-monitor', 'ok', 'alive'));
$a = fresh("$base/c")->attention(since => '2d');
is($a->{status}, 'unreadable', 'attention: a damaged file is unreadable, not clear');
like($a->{reason}, qr/events-2026-11-11\.log\.gz/, 'attention: it names the file');

# silent: lines, but none in the window
make_path("$base/d");
spew("$base/d/events.log", line('06:00:00', 'ips.lab', 'info', 'service', 'hps-monitor', 'ok', 'alive'));
$a = fresh("$base/d")->attention;
is($a->{status}, 'silent', 'attention: no line within the hour is silent, not clear');
$a = fresh("$base/d")->attention(since => '6h');
is($a->{status}, 'clear', 'attention: the same file read over 6h is clear');

# clear and attention, newest line per (kind, subject) decides
make_path("$base/e");
spew("$base/e/events.log",
    line('09:00:00', 'ips.lab', 'warning', 'issue', 'zfs-vdev:sch-001', 'open', 'hps-issue: opened I-1'),
    line('09:10:00', 'ips.lab', 'notice',  'issue', 'zfs-vdev:sch-001', 'resolved', 'hps-issue: resolved I-1'),
    line('09:15:00', 'ips.lab', 'warning', 'monitor', 'sch-001.hps/mem', 'warning', 'mem low'),
    line('09:20:00', 'ips.lab', 'info',    'monitor', 'sch-001.hps/mem', 'ok', 'mem fine'),
    line('09:25:00', 'ips.lab', 'warning', 'workload', 'media-1', 'failed', 'hps-workload: start media-1 failed'),
    line('09:26:00', 'ips.lab', 'info', 'service', 'hps-monitor', 'ok', 'alive'),
);
$a = fresh("$base/e")->attention;
is($a->{status}, 'attention', 'attention: a failed workload start is open');
is_deeply($a->{counts}, { urgent => 0, warning => 1 }, 'attention: a resolved issue and a recovered check are not counted');
is(scalar @{ $a->{problems} }, 1, 'attention: one line per open problem');
is_deeply([ @{ $a->{problems}[0] }{qw(pri kind subject state)} ], [ 'warning', 'workload', 'media-1', 'failed' ], 'attention: the problem');
is($a->{events}, 6, 'attention: the lines read in the window');
is($a->{newest}, '2026-11-12T09:26:00Z', 'attention: newest line time');

spew("$base/e/events.log",
    line('09:00:00', 'ips.lab', 'warning', 'workload', 'media-1', 'failed', 'start failed'),
    line('09:30:00', 'ips.lab', 'notice', 'workload', 'media-1', 'done', 'hps-workload: start media-1 ok'),
    line('09:31:00', 'ips.lab', 'info', 'service', 'hps-monitor', 'ok', 'alive'),
);
$a = fresh("$base/e")->attention;
is($a->{status}, 'clear', 'attention: a later success of the same workload closes the failure');
is($a->{counts}{warning} + $a->{counts}{urgent}, 0, 'attention: clear has no counts');

# standing run, urgent first, first/lines, window, secrets, cap
spew("$base/e/events.log",
    line('08:50:00', 'ips.lab', 'warning', 'monitor', 'n1', 'warning', 'older than the window'),
    line('09:10:00', 'ips.lab', 'warning', 'monitor', 'n1', 'warning', 'disk 85%'),
    line('09:15:00', 'ips.lab', 'urgent',  'monitor', 'n1', 'critical', 'disk 95%'),
    line('09:20:00', 'ips.lab', 'urgent',  'monitor', 'n1', 'critical', 'disk 96%'),
    line('09:21:00', 'ips.lab', 'warning', 'issue',   'om3-hb:a:b', 'open', 'beat missing'),
    line('09:22:00', 'ips.lab', 'urgent',  'issue',   'key-x', 'escalated', 'api_key=abc leaked'),
);
$a = fresh("$base/e")->attention;
is_deeply($a->{counts}, { urgent => 2, warning => 1 }, 'attention: counts by priority of the problems, not the lines');
is($a->{problems}[0]{pri}, 'urgent', 'attention: urgent first');
my ($n1) = grep { $_->{subject} eq 'n1' } @{ $a->{problems} };
is($n1->{state}, 'critical', 'attention: the newest line of the subject is the state');
is($n1->{lines}, 3, 'attention: the run counts its lines in the window');
is($n1->{first}, '2026-11-12T09:10:00Z', 'attention: first is the start of the run in the window');
is($n1->{text}, 'disk 96%', 'attention: the newest text');
my ($kx) = grep { $_->{subject} eq 'key-x' } @{ $a->{problems} };
is($kx->{text}, '[redacted]', 'attention: a secret text is redacted');
$a = fresh("$base/e")->attention(since => '45m');
is($a->{events}, 4, 'attention: --since narrows the window');

my @many = map { line('09:' . sprintf('%02d', $_) . ':00', 'ips.lab', 'warning', 'monitor', "n$_", 'warning', 'x' x 200) } 10 .. 39;
spew("$base/e/events.log", @many);
$a = fresh("$base/e")->attention;
is(scalar @{ $a->{problems} }, HPS::Log::ATTENTION_ROWS, 'attention: at most a screenful of problems');
is($a->{more}, 30 - HPS::Log::ATTENTION_ROWS, 'attention: the rest is counted');
is($a->{counts}{warning}, 30, 'attention: counts are of all problems');
cmp_ok(length $a->{problems}[0]{text}, '<=', 120, 'attention: a long text is cut');

# the rotated file in the window is read
make_path("$base/f");
gz("$base/f/events-2026-11-12.log.gz", line('09:40:00', 'ips.lab', 'warning', 'storage', 'sch-001', 'failed', 'hps-storage: create exit 1'));
spew("$base/f/events.log", line('09:50:00', 'ips.lab', 'info', 'service', 'hps-monitor', 'ok', 'alive'));
$a = fresh("$base/f")->attention;
is($a->{status}, 'attention', 'attention: a problem in yesterday-rotated file inside the window is found');

# point state, attention priority, no later line: still open until it ages out of the window
is(fresh("$base/f")->attention(since => '5m')->{status}, 'silent', 'attention: a window with no lines is silent');

done_testing;
