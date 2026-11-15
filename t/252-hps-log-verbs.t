#!/usr/bin/env perl
# bin/hps-log verbs events, audit and attention (docs/LOGGING.md): output,
# --json, and every exit code: 0 nothing needs attention, 10 attention, 11 the
# events could not be read (absent, empty, unreadable, silent), 2 usage.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Compress::Gzip qw(gzip $GzipError);
use JSON::PP;
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;

my $base = tempdir(CLEANUP => 1);
my $bin  = "$Bin/../bin/hps-log";
$ENV{HPS_CONFIG_BASE} = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }
# an event line of $ago minutes ago (the CLI reads the real clock)
sub line {
    my ($ago, $pri, $kind, $subj, $state, $text) = @_;
    my $t = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time - $ago * 60));
    return "$t ips.lab " . HPS::Event::marker($pri) . " pri=$pri kind=$kind subject=$subj state=$state $text";
}
# run($dir, @args): (exit code, stdout, stderr)
sub run {
    my ($dir, @args) = @_;
    local $ENV{HPS_LOG} = $dir;
    my $out = "$base/out.$$";
    my $err = "$base/err.$$";
    system("$^X $bin " . join(' ', map { "'$_'" } @args) . " > $out 2> $err");
    my $rc = $? >> 8;
    my ($o, $e) = map { open(my $fh, '<', $_) or return ''; local $/; my $t = <$fh>; $t } ($out, $err);
    return ($rc, $o, $e);
}

#--- attention: clear (0) --------------------------------------------------------------------
my $clear = "$base/clear";
make_path($clear);
spew("$clear/events.log",
    line(30, 'warning', 'issue', 'zfs-vdev:sch-001', 'open', 'hps-issue: opened I-1'),
    line(20, 'notice',  'issue', 'zfs-vdev:sch-001', 'resolved', 'hps-issue: resolved I-1'),
    line(5,  'info',    'service', 'hps-monitor', 'ok', 'hps-monitor: alive'),
);
my ($rc, $out, $err) = run($clear, 'attention');
is($rc, 0, 'attention: nothing open exits 0');
like($out, qr/\Aattention: last 60 min: nothing needs attention \(3 event lines, newest \S+Z\)\n\z/, 'attention: one line when clear');
($rc, $out) = run($clear, 'attention', '--json');
is($rc, 0, 'attention --json: exit 0');
is(decode_json($out)->{status}, 'clear', 'attention --json: status clear');

#--- attention: attention (10) ----------------------------------------------------------------
my $bad = "$base/bad";
make_path($bad);
spew("$bad/events.log",
    line(40, 'warning', 'monitor', 'sch-001.hps/disk_log', 'warning', 'disk 85%'),
    line(30, 'urgent',  'monitor', 'sch-001.hps/disk_log', 'critical', 'disk 95%'),
    line(10, 'urgent',  'monitor', 'sch-001.hps/disk_log', 'critical', 'disk 96%'),
    line(9,  'warning', 'issue', 'om3-hb:a:b', 'open', 'hps-issue: opened I-2'),
    line(2,  'info',    'service', 'hps-monitor', 'ok', 'hps-monitor: alive'),
);
($rc, $out) = run($bad, 'attention');
is($rc, 10, 'attention: an open problem exits 10');
my @l = split /\n/, $out;
is(scalar @l, 3, 'attention: a header and one line per problem');
like($l[0], qr/\Aattention: last 60 min: 1 urgent, 1 warning \(5 event lines, newest /, 'attention: counts by priority');
like($l[1], qr/\Aurgent  monitor sch-001\.hps\/disk_log critical since \d\d:\d\dZ x3 disk 96%\z/, 'attention: urgent first, with its run');
like($l[2], qr/\Awarning issue om3-hb:a:b open since /, 'attention: then the warning');
($rc, $out) = run($bad, 'attention', '--json');
is($rc, 10, 'attention --json: exit 10');
my $d = decode_json($out);
is($d->{status}, 'attention', 'attention --json: status');
is_deeply($d->{counts}, { urgent => 1, warning => 1 }, 'attention --json: counts');
is(scalar @{ $d->{problems} }, 2, 'attention --json: problems');
($rc, $out) = run($bad, 'attention', '--since', '5m');
is($rc, 0, 'attention --since 5m: only the heartbeat in the window, nothing open');
($rc, $out) = run($bad, 'attention', '--since', '2h');
is($rc, 10, 'attention --since 2h');

#--- attention: could not read (11) ---------------------------------------------------------------
($rc, $out, $err) = run("$base/nowhere", 'attention');
is($rc, 11, 'attention: no events.log exits 11');
like($out, qr/cannot tell \(absent\): no events\.log/, 'attention: absent is said, not "no problems"');
unlike($out, qr/nothing needs attention/, 'attention: absent never says nothing needs attention');
my $empty = "$base/empty";
make_path($empty);
spew("$empty/events.log");
($rc, $out) = run($empty, 'attention');
is($rc, 11, 'attention: an empty events.log exits 11');
like($out, qr/cannot tell \(empty\)/, 'attention: empty is said');
my $silent = "$base/silent";
make_path($silent);
spew("$silent/events.log", line(600, 'info', 'service', 'hps-monitor', 'ok', 'old'));
($rc, $out) = run($silent, 'attention');
is($rc, 11, 'attention: no line in the window exits 11');
like($out, qr/cannot tell \(silent\)/, 'attention: silent is said');
my $dam = "$base/dam";
make_path($dam);
spew("$dam/events.log", line(1, 'info', 'service', 'hps-monitor', 'ok', 'alive'));
open(my $z, '>', "$dam/events-2026-01-01.log.gz") or die; print {$z} "garbage\n"; close $z;
($rc, $out) = run($dam, 'attention', '--since', '60d');
is($rc, 2, '--since 60d is over the limit: usage 2');
($rc, $out) = run($dam, 'attention', '--since', '30d');
is($rc, 11, 'attention: a damaged rotated file in the window exits 11');
like($out, qr/cannot tell \(unreadable\).*events-2026-01-01\.log\.gz/, 'attention: unreadable names the file');
($rc, $out) = run($dam, 'attention', '--json', '--since', '30d');
is($rc, 11, 'attention --json: exit 11 too');
is(decode_json($out)->{status}, 'unreadable', 'attention --json: the status says why');
my $gzdir = "$base/gz";
make_path($gzdir);
my $gztext = line(100, 'warning', 'storage', 'sch-001', 'failed', 'hps-storage: create exit 1') . "\n";
gzip(\$gztext => "$gzdir/events-2026-01-01.log.gz") or die $GzipError;
spew("$gzdir/events.log", line(1, 'info', 'service', 'hps-monitor', 'ok', 'alive'));
($rc, $out) = run($gzdir, 'attention', '--since', '3h');
is($rc, 10, 'attention: a problem only in a gzipped rotated file is found');

#--- events -------------------------------------------------------------------------------------
($rc, $out) = run($bad, 'events', '--lines', '2');
is($rc, 0, 'events: exit 0');
my @e = split /\n/, $out;
is(scalar @e, 2, 'events: --lines 2');
like($e[1], qr/\A\S+Z info    service hps-monitor ok ips\.lab: hps-monitor: alive\z/, 'events: compact form, newest last');
($rc, $out) = run($bad, 'events', '--min-level', 'error', '--json');
$d = decode_json($out);
is($d->{target}, 'events', 'events --json: target');
is($d->{count}, 2, 'events --min-level error: the two urgent lines');
is($d->{lines}[0]{kind}, 'monitor', 'events --json: kind');
is($d->{lines}[0]{pri}, 'urgent', 'events --json: pri');
is($d->{lines}[0]{level}, 'error', 'events --json: level');
($rc, $out) = run($bad, 'events', '--grep', 'om3-hb');
like($out, qr/om3-hb:a:b/, 'events --grep');
($rc, $out) = run("$base/nowhere", 'events');
is($rc, 0, 'events: no file is no lines, exit 0');
like($out, qr/# no log lines/, 'events: says so');
($rc, $out, $err) = run($bad, 'events', 'extra');
is($rc, 2, 'events: an argument is usage');
($rc, $out, $err) = run($bad, 'events', '--since', '0');
is($rc, 2, 'events --since 0: usage');

#--- audit ----------------------------------------------------------------------------------------
my $aud = "$base/aud";
make_path($aud);
spew("$aud/audit.log",
    '2026-11-12T09:00:00Z 10.1.2.3 [s3.ips] ctrl-exec-api[44]:  ACTION=run EXIT=0 SCRIPT=hps-workload',
    '2026-11-12T09:00:01Z 127.0.0.1 [ips] hps-auth-hook:  OPERATOR run operator=lab script=hps-osvc',
);
($rc, $out) = run($aud, 'audit', '--lines', '1', '--json');
is($rc, 0, 'audit: exit 0');
$d = decode_json($out);
is($d->{target}, 'audit', 'audit --json: target');
is($d->{lines}[0]{tag}, 'hps-auth-hook', 'audit: newest line');
($rc, $out) = run($aud, 'audit', '--grep', 'ctrl-exec-api');
like($out, qr/ctrl-exec-api: ACTION=run/, 'audit --grep, text form');
($rc, $out) = run($aud, 'audit', 'x');
is($rc, 2, 'audit: an argument is usage');

#--- usage ------------------------------------------------------------------------------------------
($rc, $out, $err) = run($bad, 'attention', '--lines', '5');
is($rc, 2, 'attention --lines: usage (only --since and --json)');
($rc, $out, $err) = run($bad, 'attention', 'x');
is($rc, 2, 'attention with an argument: usage');
($rc, $out, $err) = run($bad, 'attention', '--since', 'soon');
is($rc, 2, 'attention --since soon: usage');
($rc, $out, $err) = run($bad, 'attention', '--help');
is($rc, 2, 'an unknown option prints usage');
($rc, $out, $err) = run($bad, '--help');
like($err, qr/hps-log attention \[--since 1h\]/, 'usage names attention');
like($err, qr/Exit: 0 ok, 1 failed, 2 usage, 4 no such host; attention 10 and 11/, 'usage names the exit codes');

done_testing;
