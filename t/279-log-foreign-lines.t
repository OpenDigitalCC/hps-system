#!/usr/bin/env perl
# docs/LOGGING.md "Whose lines": lines another cluster's IPS forwarded here (host name
# <prefix>.<hostname>) are not this cluster's events. rsyslog keeps them out of events.log,
# metrics.log and audit.log; the reader also leaves any that older files hold out of
# attention, events and audit. A reader that cannot tell (no domain known) hides nothing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;
use HPS::Log;

my $base = tempdir(CLEANUP => 1);
my $logd = "$base/log";
make_path($logd);
sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }
my $now = timegm(0, 0, 10, 12, 10, 2026);    # 2026-11-12 10:00:00 UTC
sub ev {
    my ($tm, $host, $pri, $kind, $subj, $state, $text) = @_;
    return "2026-11-12T${tm}Z $host " . HPS::Event::marker($pri) . " pri=$pri kind=$kind subject=$subj state=$state $text";
}
# a derived line, as rsyslog writes it: subject -, the original text after it
sub derived { my ($tm, $host, $pri, $text) = @_; return "2026-11-12T${tm}Z $host " . HPS::Event::marker($pri) . " pri=$pri kind=log subject=- state=error $text" }

#--- own_host
is(HPS::Log::own_host('ips', 'lab.example'), 1, 'own_host: the IPS');
is(HPS::Log::own_host('sch-001', 'lab.example'), 1, 'a single label');
is(HPS::Log::own_host('sch-001.lab.example', 'lab.example'), 1, 'label.domain');
is(HPS::Log::own_host('SCH-001.Lab.Example', 'lab.example'), 1, 'case does not matter');
is(HPS::Log::own_host('s1.ips', 'lab.example'), 0, 'a forwarded host (prefix.label)');
is(HPS::Log::own_host('s1.sch-001.lab.example', 'lab.example'), 0, 'prefix.label.domain');
is(HPS::Log::own_host('sch-001.other.example', 'lab.example'), 0, 'another domain');
is(HPS::Log::own_host('s3.tch-001', ''), 0, 'no domain set: a dotted host is not this cluster\'s');
is(HPS::Log::own_host('ips', ''), 1, 'no domain set: a single label is');
is(HPS::Log::own_host('s1.ips', undef), 1, 'domain unreadable: cannot tell, the line is kept');
is(HPS::Log::own_host('ips.lab', undef), 1, 'unreadable: kept');

#--- attention with foreign lines present (the lab: about 400 err lines in ten minutes)
my @foreign = (
    derived('09:50:00', 's1.ips', 'warning', 'rsyslogd: omfwd: remote server closed connection'),
    derived('09:51:00', 's3.tch-001', 'warning', '.libvirtd-wrapp[1311]: Cannot recv data: Connection reset by peer'),
    ev('09:52:00', 's1.ips', 'warning', 'issue', 'zfs-vdev:sch-001', 'open', 'hps-issue: opened I-9 (another cluster)'),
    ev('09:53:00', 's3.ips', 'urgent', 'monitor', 'sch-002/disk_log', 'critical', 'disk 99% (another cluster)'),
    ev('09:54:00', 's1.ips', 'info', 'boot', '-', 'started', 'hps: [sch-002] NixOS network boot (another cluster)'),
);
my @own = (
    ev('09:30:00', 'ips', 'info', 'service', 'hps-monitor', 'ok', 'hps-monitor: alive'),
    ev('09:40:00', 'ips', 'warning', 'issue', 'om3-hb:a:b', 'open', 'hps-issue: opened I-2'),
);
spew("$logd/events.log", @own, @foreign);
my $log = HPS::Log->new(log_dir => $logd, now => $now, domain => '');
my $a = $log->attention;
is($a->{status}, 'attention', 'attention: this cluster\'s own problem is there');
is($a->{counts}{warning}, 1, 'one warning: the foreign ones are not counted');
is($a->{counts}{urgent}, 0, 'and the foreign urgent line is not shown');
is_deeply([ map { "$_->{kind} $_->{subject}" } @{ $a->{problems} } ], ['issue om3-hb:a:b'], 'the problems list holds only this cluster\'s');
is($a->{events}, 2, 'the event count holds only this cluster\'s lines');

spew("$logd/events.log", ev('09:30:00', 'ips', 'info', 'service', 'hps-monitor', 'ok', 'hps-monitor: alive'), @foreign);
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => '');
$a = $log->attention;
is($a->{status}, 'clear', 'only the heartbeat of this cluster and foreign problems: clear');
is($a->{events}, 1, 'one event line counted');

spew("$logd/events.log", @foreign);
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => '');
$a = $log->attention;
is($a->{status}, 'silent', 'foreign lines only: this cluster has no event line in the window, which attention says (never "clear")');

spew("$logd/events.log", @own, @foreign);
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => undef);
$a = $log->attention;
is($a->{counts}{urgent}, 1, 'domain unreadable: nothing is hidden on a guess (the foreign urgent line shows)');

#--- events and audit views
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => 'lab.example');
my $r = $log->events_log(lines => 50);
is(scalar @{ $r->{lines} }, 2, 'events: only this cluster\'s lines');
ok(!(grep { $_->{host} =~ /\A[sS]\d\./ } @{ $r->{lines} }), 'no forwarded host in it');

spew("$logd/audit.log",
    '2026-11-12T09:00:00Z 10.1.1.1 [sch-001] ctrl-exec-api[1]:  ACTION=run own',
    '2026-11-12T09:01:00Z 10.1.1.12 [s1.ips] ctrl-exec-api[1]:  ACTION=run foreign');
$r = $log->audit_log(lines => 10);
is_deeply([ map { $_->{message} } @{ $r->{lines} } ], ['ACTION=run own'], 'audit: only this cluster\'s records');

#--- the err-level derived lines of other programs are info, not attention
spew("$logd/events.log",
    ev('09:30:00', 'ips', 'info', 'service', 'hps-monitor', 'ok', 'hps-monitor: alive'),
    derived('09:40:00', 'sch-001', 'info', 'libvirtd-wrapp[1]: Cannot recv data (a program HPS does not run)'));
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => '');
$a = $log->attention;
is($a->{status}, 'clear', 'an err line of another program, derived at info: visible in events, not in attention');
$r = $log->events_log(lines => 10);
is(scalar @{ $r->{lines} }, 2, 'events shows it');
spew("$logd/events.log",
    ev('09:30:00', 'ips', 'info', 'service', 'hps-monitor', 'ok', 'hps-monitor: alive'),
    derived('09:40:00', 'ips', 'warning', 'hps-monitor[1]: error reading registry'));
$log = HPS::Log->new(log_dir => $logd, now => $now, domain => '');
$a = $log->attention;
is($a->{status}, 'attention', 'an err line of an HPS program, derived at warning: attention');

done_testing;
