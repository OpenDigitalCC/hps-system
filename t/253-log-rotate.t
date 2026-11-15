#!/usr/bin/env perl
# HPS::LogRotate and bin/hps-log-rotate (docs/LOGGING.md "Rotation"): the daily
# rename and HUP, compression of files untouched for ten minutes, retention per
# file kind, the cluster keys, and the CLI. A temp log tree and a fake clock.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use POSIX qw(tzset);
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::LogRotate;
use HPS::Log;

$ENV{TZ} = 'UTC';
tzset();

my $base = tempdir(CLEANUP => 1);
sub spew { my ($f, $t) = @_; make_path($f =~ s{/[^/]+\z}{}r); open(my $fh, '>', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<', $_[0]) or return undef; local $/; my $t = <$fh>; close $fh; return $t }
sub age { my ($f, $now, $secs) = @_; utime($now - $secs, $now - $secs, $f) or die "utime $f: $!" }
sub ls { my $d = shift; my @f; my $w; $w = sub { my $p = shift; opendir(my $dh, $p) or return; for my $n (sort grep { !/\A\.\.?\z/ } readdir $dh) { my $q = "$p/$n"; -d $q ? $w->($q) : push @f, $q =~ s{\A\Q$d\E/}{}r } }; $w->($d); return @f }
sub fresh { my $n = shift; my $d = "$base/$n"; make_path($d); return $d }

my $now = timegm(0, 0, 3, 13, 10, 2026);    # 2026-11-13 03:00:00 UTC

#--- date_of ------------------------------------------------------------------------------
is(HPS::LogRotate::date_of($now), '2026-11-13', 'date_of: today');
is(HPS::LogRotate::date_of($now, 1), '2026-11-12', 'date_of: yesterday');
is(HPS::LogRotate::date_of($now, 13), '2026-10-31', 'date_of: across a month');
is(HPS::LogRotate::date_of(timegm(0, 59, 23, 31, 11, 2026), 1), '2026-12-30', 'date_of: late evening is still that day');

#--- keep_days (the cluster keys) --------------------------------------------------------------
my ($k, @bad) = HPS::LogRotate::keep_days(sub { undef });
is_deeply($k, { events => 365, metrics => 30, audit => 14, other => 7 }, 'keep_days: the defaults');
is(scalar @bad, 0, 'keep_days: unset is silent');
my %set = (log_events_retention_days => '400', log_metrics_retention_days => ' 10 ', log_audit_retention_days => '0', log_retention_days => 'many');
($k, @bad) = HPS::LogRotate::keep_days(sub { $set{ $_[0] } });
is_deeply($k, { events => 400, metrics => 10, audit => 14, other => 7 }, 'keep_days: valid values used, others default');
is(scalar @bad, 2, 'keep_days: the two bad values are named');
like($bad[0] . $bad[1], qr/log_audit_retention_days='0'.*log_retention_days='many'|log_retention_days='many'.*log_audit_retention_days='0'/s, 'keep_days: which keys');
($k) = HPS::LogRotate::keep_days(sub { die "no registry\n" });
is($k->{events}, 365, 'keep_days: an unreadable registry gives the defaults');
($k) = HPS::LogRotate::keep_days(sub { '3651' });
is($k->{events}, 365, 'keep_days: over 3650 is not accepted');

#--- rotation_due and the state ---------------------------------------------------------------------
my $d = fresh('due');
my $hups = 0;
my $rot = HPS::LogRotate->new(log_dir => $d, now => $now, hup => sub { $hups++; 1 });
ok($rot->rotation_due, 'rotation_due: never rotated is due');
is($rot->last_rotated, undef, 'last_rotated: none');
spew("$d/.log-rotate-state", "2026-11-13\n");
ok(!$rot->rotation_due, 'rotation_due: rotated today is not due');
spew("$d/.log-rotate-state", "2026-11-12\n");
ok($rot->rotation_due, 'rotation_due: rotated yesterday is due');
spew("$d/.log-rotate-state", "garbage\n");
ok($rot->rotation_due, 'rotation_due: a garbled state is due');

#--- rotate_views ---------------------------------------------------------------------------------
$d = fresh('rot');
spew("$d/events.log", "e1\ne2\n");
spew("$d/metrics.log", "m1\n");
spew("$d/audit.log", '');
spew("$d/all.log", "lab file: never touched\n");
$hups = 0;
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, hup => sub { $hups++; 1 });
my ($done, $err) = $rot->rotate_views;
is_deeply($done, [ 'events.log -> events-2026-11-12.log', 'metrics.log -> metrics-2026-11-12.log' ], 'rotate_views: the views with lines, named for yesterday');
is_deeply($err, [], 'rotate_views: no error');
is($hups, 1, 'rotate_views: one HUP after the renames');
ok(!-e "$d/events.log" && !-e "$d/metrics.log", 'rotate_views: the live files are gone (rsyslog makes them again)');
is(slurp("$d/events-2026-11-12.log"), "e1\ne2\n", 'rotate_views: content kept');
ok(-e "$d/audit.log", 'rotate_views: an empty view is left alone');
ok(-e "$d/all.log", 'rotate_views: other files are not touched');
is($rot->last_rotated, '2026-11-13', 'rotate_views: the state is today');

# a second rotation the same day never overwrites
spew("$d/events.log", "e3\n");
($done) = $rot->rotate_views;
is_deeply($done, [ 'events.log -> events-2026-11-12.1.log' ], 'rotate_views: the next name has a sequence number');
spew("$d/events.log", "e4\n");
spew("$d/events-2026-11-12.2.log.gz", 'x');
($done) = $rot->rotate_views;
is_deeply($done, [ 'events.log -> events-2026-11-12.3.log' ], 'rotate_views: a name taken by a .gz is skipped too');
is(slurp("$d/events-2026-11-12.log"), "e1\ne2\n", 'rotate_views: the first rotated file is intact');

# a failing HUP: said, state not written
$d = fresh('hupfail');
spew("$d/events.log", "x\n");
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, hup => sub { 0 });
($done, $err) = $rot->rotate_views;
is(scalar @$err, 1, 'rotate_views: a failed HUP is an error');
like($err->[0], qr/rsyslogd did not take the HUP/, 'rotate_views: the error says it');
is($rot->last_rotated, undef, 'rotate_views: the state is not written, so the next pass is due again');

# nothing to rotate: no HUP
$d = fresh('norot');
$hups = 0;
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, hup => sub { $hups++; 1 });
($done, $err) = $rot->rotate_views;
is_deeply([ $done, $err, $hups ], [ [], [], 0 ], 'rotate_views: no view holds lines: no rename, no HUP');
is($rot->last_rotated, '2026-11-13', 'rotate_views: but the day is noted');

# dry run
$d = fresh('dry');
spew("$d/events.log", "x\n");
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, hup => sub { die 'no HUP in a dry run' }, dry_run => 1);
($done) = $rot->rotate_views;
is_deeply($done, [ 'events.log -> events-2026-11-12.log' ], 'dry run: says what it would do');
ok(-e "$d/events.log" && !-e "$d/events-2026-11-12.log", 'dry run: changes nothing');

#--- compress ---------------------------------------------------------------------------------------
$d = fresh('gz');
spew("$d/events-2026-11-12.log", "line 1\nline 2\n");
age("$d/events-2026-11-12.log", $now, 700);
spew("$d/metrics-2026-11-12.log", "fresh\n");
age("$d/metrics-2026-11-12.log", $now, 300);
spew("$d/10.0.0.5/2026-11-12.log", "yesterday's day file\n");
age("$d/10.0.0.5/2026-11-12.log", $now, 4000);
spew("$d/10.0.0.5/2026-11-13.log", "today's day file, quiet for a long time\n");
age("$d/10.0.0.5/2026-11-13.log", $now, 4000);
spew("$d/ips/hps/2026-11-11.log", "service day file\n");
age("$d/ips/hps/2026-11-11.log", $now, 90000);
spew("$d/events.log", "live\n");
age("$d/events.log", $now, 90000);
spew("$d/supervisord.log", "not dated\n");
age("$d/supervisord.log", $now, 90000);
$rot = HPS::LogRotate->new(log_dir => $d, now => $now);
my ($c, $ce) = $rot->compress;
is_deeply([ sort map { s{\A\Q$d\E/}{}r } @$c ], [ '10.0.0.5/2026-11-12.log', 'events-2026-11-12.log', 'ips/hps/2026-11-11.log' ],
    'compress: rotated and past day files untouched for ten minutes');
is_deeply($ce, [], 'compress: no error');
is_deeply([ ls($d) ], [ '10.0.0.5/2026-11-12.log.gz', '10.0.0.5/2026-11-13.log', 'events-2026-11-12.log.gz', 'events.log',
    'ips/hps/2026-11-11.log.gz', 'metrics-2026-11-12.log', 'supervisord.log' ],
    'compress: gz beside, plain removed; a file touched in the last 10 minutes, today\'s day file, the live view and undated files stay');
my $text;
gunzip("$d/events-2026-11-12.log.gz" => \$text) or die $GunzipError;
is($text, "line 1\nline 2\n", 'compress: the gz holds the content');
is((stat "$d/events-2026-11-12.log.gz")[9], $now - 700, 'compress: the mtime is kept');
($c) = $rot->compress;
is_deeply($c, [], 'compress: a second pass has nothing to do');

# a plain file whose gz is already complete: the plain one goes
spew("$d/audit-2026-11-10.log", "again\n");
age("$d/audit-2026-11-10.log", $now, 99999);
spew("$d/audit-2026-11-10.log.gz", 'gz-bytes');
($c) = $rot->compress;
ok(!-e "$d/audit-2026-11-10.log" && -e "$d/audit-2026-11-10.log.gz", 'compress: an existing gz stands, the plain file is removed');

# dry run
$d = fresh('gzdry');
spew("$d/events-2026-11-12.log", "x\n");
age("$d/events-2026-11-12.log", $now, 700);
($c) = HPS::LogRotate->new(log_dir => $d, now => $now, dry_run => 1)->compress;
is(scalar @$c, 1, 'compress dry run: reports');
ok(-e "$d/events-2026-11-12.log" && !-e "$d/events-2026-11-12.log.gz", 'compress dry run: changes nothing');

# the reader follows the rotated, compressed files
$d = fresh('read');
spew("$d/events-2026-11-12.log", "2026-11-12T10:00:00Z ips HPS-EVENT pri=info kind=job subject=j1 state=ended old line\n");
age("$d/events-2026-11-12.log", $now, 700);
HPS::LogRotate->new(log_dir => $d, now => $now)->compress;
spew("$d/events.log", "2026-11-13T02:59:00Z ips HPS-EVENT pri=info kind=job subject=j2 state=ended new line\n");
my $r = HPS::Log->new(log_dir => $d, now => $now)->events_log(since => '1d');
is_deeply([ map { $_->{subject} } @{ $r->{lines} } ], [ 'j1', 'j2' ], 'HPS::Log reads what hps-log-rotate rotated and compressed');

#--- prune ---------------------------------------------------------------------------------------------
$d = fresh('prune');
my @keep = (
    'events-2026-11-12.log.gz', 'events-2025-11-14.log.gz', 'events-2025-11-13.log.gz',     # 365 days: 2025-11-13 is the last kept
    'metrics-2026-10-14.log.gz', 'metrics-2026-10-13.log.gz',                                # 30 days: 2026-10-14 kept
    'audit-2026-10-30.log.gz', 'audit-2026-10-29.log.gz',                                    # 14 days: 2026-10-30 kept
    '10.0.0.5/2026-11-06.log.gz', '10.0.0.5/2026-11-05.log', 'ips/2026-11-06.log', 'ips/2026-11-05.log.gz',   # 7 days: 11-06 kept
    'ips/hps/2026-11-01.log.gz',
);
spew("$d/$_", "x\n") for @keep;
spew("$d/10.0.0.9/2026-11-01.log.gz", "only an old file\n");
spew("$d/supervisord.log", "undated\n");
spew("$d/all-2026-01-01.log.gz", "lab collector: never pruned\n");
spew("$d/events-bogus.log", "x\n");
$rot = HPS::LogRotate->new(log_dir => $d, now => $now);
my ($p, $pe) = $rot->prune;
my %gone = map { (s{\A\Q$d\E/}{}r) => 1 } @$p;
my @expect = ('10.0.0.5/2026-11-05.log', '10.0.0.9/2026-11-01.log.gz', 'audit-2026-10-29.log.gz', 'ips/2026-11-05.log.gz', 'ips/hps/2026-11-01.log.gz', 'metrics-2026-10-13.log.gz');
is_deeply([ sort keys %gone ], \@expect,
    'prune: events 365 days, metrics 30, audit 14, the day files 7, by the date in the name');
ok(-e "$d/events-2025-11-13.log.gz" && !-e "$d/events-2024-11-13.log.gz", 'prune: events from 365 days ago is kept');
ok(!-d "$d/10.0.0.9", 'prune: a directory left empty goes');
ok(-d "$d/10.0.0.5" && -d "$d/ips", 'prune: other directories stay');
ok(-e "$d/supervisord.log" && -e "$d/all-2026-01-01.log.gz" && -e "$d/events-bogus.log", 'prune: undated files and the lab collector\'s files are never deleted');
is_deeply($pe, [], 'prune: no error');

# keep values
$d = fresh('prunekeys');
spew("$d/events-2026-11-10.log.gz", "x\n");
spew("$d/10.0.0.5/2026-11-10.log.gz", "x\n");
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, keep => { events => 2, other => 2 });
($p) = $rot->prune;
is(scalar @$p, 2, 'prune: the keep values given are used (3 days old, kept 2)');
$rot = HPS::LogRotate->new(log_dir => $d, now => $now, keep => { other => 2 });
spew("$d/events-2026-11-10.log.gz", "x\n");
($p) = $rot->prune;
is(scalar @$p, 0, 'prune: nothing else to delete (events keeps 365 by default)');
$d = fresh('prunedry');
spew("$d/events-2020-01-01.log.gz", "x\n");
($p) = HPS::LogRotate->new(log_dir => $d, now => $now, dry_run => 1)->prune;
is(scalar @$p, 1, 'prune dry run: reports');
ok(-e "$d/events-2020-01-01.log.gz", 'prune dry run: deletes nothing');

#--- run_once, a fake clock across days ------------------------------------------------------------------
$d = fresh('run');
my $clock = timegm(0, 0, 23, 12, 10, 2026);    # 2026-11-12 23:00
$hups = 0;
$rot = HPS::LogRotate->new(log_dir => $d, now => sub { $clock }, hup => sub { $hups++; 1 });
spew("$d/events.log", "day one\n");
age("$d/events.log", $clock, 10);
my $res = $rot->run_once;
ok($res->{rotation_ran}, 'run_once: the first run rotates');
is_deeply($res->{rotated}, [ 'events.log -> events-2026-11-11.log' ], 'run_once: named for the day before');
is_deeply($res->{compressed}, [], 'run_once: a file written ten seconds ago is not compressed');
$clock += 3600;    # 2026-11-13 00:00
spew("$d/events.log", "later the same day\n");
age("$d/events.log", $clock, 10);
$res = $rot->run_once;
ok($res->{rotation_ran}, 'run_once: after midnight it rotates again');
is_deeply($res->{rotated}, [ 'events.log -> events-2026-11-12.log' ], 'run_once: named for the day that ended');
is_deeply([ map { s{.*/}{}r } @{ $res->{compressed} } ], [ 'events-2026-11-11.log' ], 'run_once: the file an hour old is compressed');
$clock += 1800;
spew("$d/events.log", "day two\n");
age("$d/events.log", $clock, 10);
$res = $rot->run_once;
ok(!$res->{rotation_ran}, 'run_once: the same day it does not rotate');
ok(-e "$d/events.log", 'run_once: the live file is left');
is($hups, 2, 'run_once: HUP once per rotation');
is_deeply([ map { s{.*/}{}r } @{ $res->{compressed} } ], [ 'events-2026-11-12.log' ], 'run_once: the next rotated file is compressed when it is old enough');
$res = $rot->run_once(force => 1);
ok($res->{rotation_ran}, 'run_once: --force rotates the same day');
$clock += 400 * 86400;
$res = $rot->run_once;
cmp_ok(scalar @{ $res->{pruned} }, '>=', 2, 'run_once: a year later the old events files are pruned');
is_deeply($res->{errors}, [], 'run_once: no error');

#--- the CLI ---------------------------------------------------------------------------------------------------
my $bin = "$Bin/../bin/hps-log-rotate";
$d = fresh('cli');
spew("$d/events.log", "2026-11-12T10:00:00Z ips HPS-EVENT pri=info kind=job subject=j1 state=ended x\n");
spew("$d/10.0.0.5/2020-01-01.log.gz", "old\n");
my $lg = "$base/cli-logger.txt";
spew($lg, '');
my $stub = "$base/logger-stub.sh";
spew($stub, "#!/bin/sh\necho \"\$1 \$2\" >> '$lg'\n");
chmod 0755, $stub;
my $hupstub = "$base/hup-stub.sh";
spew($hupstub, "#!/bin/sh\necho hup >> '$base/hup.txt'\n");
chmod 0755, $hupstub;
$ENV{HPS_LOG} = $d;
$ENV{HPS_LOG_ROTATE_LOGGER} = $stub;
$ENV{HPS_LOG_ROTATE_HUP} = $hupstub;
$ENV{HPS_CONFIG_BASE} = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
my $out = `$^X $bin run --dry-run`;
is($? >> 8, 0, 'cli: run --dry-run exits 0');
like($out, qr/would rotate events\.log -> events-\d{4}-\d\d-\d\d\.log/, 'cli: dry run lists the rotation');
like($out, qr/would delete .*2020-01-01\.log\.gz/, 'cli: dry run lists the deletion');
ok(-e "$d/events.log" && -e "$d/10.0.0.5/2020-01-01.log.gz", 'cli: dry run changes nothing');
$out = `$^X $bin run`;
is($? >> 8, 0, 'cli: run exits 0');
ok(!-e "$d/10.0.0.5/2020-01-01.log.gz", 'cli: run deleted the old day file');
ok(!-e "$d/events.log", 'cli: run rotated events.log');
like(slurp($lg), qr/\Anotice HPS-EVENT pri=notice kind=log subject=hps-log-rotate state=rotated hps-log-rotate: rotated 1 view\(s\), compressed 0 file\(s\), deleted 1 file\(s\)\n\z/, 'cli: it logs one event line');
like(slurp("$base/hup.txt"), qr/hup/, 'cli: it sent the HUP');
$out = `$^X $bin run`;
is(slurp($lg) =~ tr/\n//, 1, 'cli: a pass that did nothing logs nothing');
spew("$d/events.log", "x\n");
$ENV{HPS_LOG_ROTATE_HUP} = '/bin/false';
system("$^X $bin run --force > /dev/null 2>&1");
is($? >> 8, 1, 'cli: a failed HUP exits 1');
like(slurp($lg), qr/\nwarning HPS-ALERT pri=warning kind=log subject=hps-log-rotate state=error hps-log-rotate: rsyslogd did not take the HUP/, 'cli: ... and is an alert event');
system("$^X $bin loop --interval 1 > /dev/null 2>&1");
is($? >> 8, 2, 'cli: loop --interval 1 is usage');
system("$^X $bin run --dry-run --max-ticks 1 > /dev/null 2>&1");
is($? >> 8, 0, 'cli: run accepts the loop options without effect');
system("$^X $bin loop --dry-run > /dev/null 2>&1");
is($? >> 8, 2, 'cli: loop --dry-run is usage');
system("$^X $bin > /dev/null 2>&1");
is($? >> 8, 2, 'cli: no verb is usage');
system("$^X $bin purge > /dev/null 2>&1");
is($? >> 8, 2, 'cli: an unknown verb is usage');
$ENV{HPS_LOG_ROTATE_HUP} = $hupstub;
system("$^X $bin loop --interval 5 --max-ticks 1 > /dev/null 2>&1");
is($? >> 8, 0, 'cli: loop --max-ticks 1 runs one pass and exits 0');

done_testing;
