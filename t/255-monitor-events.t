#!/usr/bin/env perl
# The monitor's event lines (HPS::Monitor mark, check_events, service_event,
# heartbeat; docs/LOGGING.md): the host-state lines carry the marker, a check that
# changes state is an event, a standing one is repeated every REMIND seconds.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;
use HPS::Monitor;
use HPS::Metrics;

sub ev { my $e = HPS::Event::parse($_[0][1]) or return undef; return $e }

#--- mark ---------------------------------------------------------------------------------
my $m = HPS::Monitor::mark([ 'err', 'hps-monitor: host=n1.lab.hps state=UNREACHABLE no route' ]);
is($m->[0], 'warning', 'mark: UNREACHABLE is syslog warning (was err)');
my $e = ev($m);
is_deeply([ @$e{qw(pri kind subject state attention)} ], [ 'warning', 'monitor', 'n1.lab.hps', 'unreachable', 1 ], 'mark: UNREACHABLE is a warning alert, standing');
is($e->{class}, 'standing', 'mark: unreachable is a standing state');
is($e->{text}, 'hps-monitor: host=n1.lab.hps state=UNREACHABLE no route', 'mark: the original line follows the marker');
$e = ev(HPS::Monitor::mark([ 'info', 'hps-monitor: host=n1.lab.hps state=REACHABLE after 660s unreachable' ]));
is_deeply([ @$e{qw(pri state class)} ], [ 'notice', 'reachable', 'clearing' ], 'mark: REACHABLE is a notice, clearing');
$m = HPS::Monitor::mark([ 'err', 'hps-monitor: host=n2.lab.hps state=PAIR_FAILED since=2026-11-12T08:00:00Z reboots=3 the node missed its pairing window' ]);
is($m->[0], 'err', 'mark: PAIR_FAILED is syslog err');
$e = ev($m);
is_deeply([ @$e{qw(pri state)} ], [ 'urgent', 'pair-failed' ], 'mark: PAIR_FAILED is urgent');
$e = ev(HPS::Monitor::mark([ 'info', 'hps-monitor: host=n3.lab.hps state=STOPPED workload=media vm=a recorded state stopped; not checked' ]));
is_deeply([ @$e{qw(pri state attention)} ], [ 'info', 'stopped', 0 ], 'mark: STOPPED is info, not attention');
for my $other ([ 'info', 'hps-monitor: host=n1.lab.hps check=mem state=OK MEM OK' ], [ 'info', 'hps-monitor: tick hosts=3 duration=1.0' ], [ 'info', 'something else' ]) {
    is_deeply(HPS::Monitor::mark($other), $other, "mark: leaves '$other->[1]' alone");
}
my $metric = HPS::Metrics::parse_message(HPS::Monitor::mark([ 'err', 'hps-monitor: host=n1.lab.hps state=UNREACHABLE no route' ])->[1]);
is_deeply([ @$metric{qw(kind host text)} ], [ 'unreachable', 'n1.lab.hps', 'no route' ], 'hps-metrics still reads a marked host-state line');
$metric = HPS::Metrics::parse_message(HPS::Monitor::mark([ 'info', 'hps-monitor: host=n1.lab.hps state=REACHABLE after 5s unreachable' ])->[1]);
is($metric->{kind}, 'reachable', 'hps-metrics reads a marked REACHABLE line');
$metric = HPS::Metrics::parse_message('hps-monitor: host=n1.lab.hps check=mem state=OK MEM OK');
is($metric->{kind}, 'check', 'hps-metrics: an unmarked line is read as before');

#--- check_events -----------------------------------------------------------------------------
my $pair = sub { my ($check, $state, $text) = @_; return [ 'x', "hps-monitor: host=n1.lab.hps check=$check state=$state $text | perf=1" ] };
my %memo;
my @o = HPS::Monitor::check_events(\%memo, 1000, $pair->('mem', 'OK', 'MEM OK'), [ 'info', 'hps-monitor: host=n1.lab.hps checks=1 worst=OK duration=0.1' ]);
is(scalar @o, 0, 'check_events: OK and a summary line make no event');
@o = HPS::Monitor::check_events(\%memo, 1060, $pair->('mem', 'WARNING', 'MEM WARNING - 8% available'));
is(scalar @o, 1, 'check_events: OK to WARNING is an event');
is($o[0][0], 'warning', 'check_events: syslog level warning');
$e = ev($o[0]);
is_deeply([ @$e{qw(pri kind subject state)} ], [ 'warning', 'monitor', 'n1.lab.hps/mem', 'warning' ], 'check_events: subject is host/check');
is($e->{text}, 'hps-monitor: mem on n1.lab.hps is WARNING: MEM WARNING - 8% available', 'check_events: the text drops the perfdata and has no host= (metrics.log keeps the raw line)');
unlike($e->{text}, qr/hps-monitor: host=/, 'check_events: the text would not match the metrics.log rule');
@o = HPS::Monitor::check_events(\%memo, 1120, $pair->('mem', 'WARNING', 'MEM WARNING - 8% available'));
is(scalar @o, 0, 'check_events: the same state a minute later is quiet');
@o = HPS::Monitor::check_events(\%memo, 1060 + HPS::Event::REMIND - 1, $pair->('mem', 'WARNING', 'x'));
is(scalar @o, 0, 'check_events: still quiet just before the reminder');
@o = HPS::Monitor::check_events(\%memo, 1060 + HPS::Event::REMIND, $pair->('mem', 'WARNING', 'MEM WARNING'));
is(scalar @o, 1, 'check_events: the reminder at REMIND seconds');
@o = HPS::Monitor::check_events(\%memo, 1060 + HPS::Event::REMIND + 60, $pair->('mem', 'CRITICAL', 'MEM CRITICAL - 2%'));
$e = ev($o[0]);
is_deeply([ @$e{qw(pri state)} ], [ 'urgent', 'critical' ], 'check_events: a worse state is an event at once, urgent');
is($o[0][0], 'err', 'check_events: syslog level err for urgent');
@o = HPS::Monitor::check_events(\%memo, 9000, $pair->('mem', 'UNKNOWN', 'no data'));
is(ev($o[0])->{state}, 'unknown', 'check_events: UNKNOWN is a warning');
@o = HPS::Monitor::check_events(\%memo, 9060, $pair->('mem', 'OK', 'MEM OK - 60%'));
$e = ev($o[0]);
is_deeply([ @$e{qw(pri state class attention)} ], [ 'notice', 'ok', 'clearing', 0 ], 'check_events: back to OK is a clearing notice');
@o = HPS::Monitor::check_events(\%memo, 9120, $pair->('mem', 'OK', 'MEM OK'));
is(scalar @o, 0, 'check_events: and then quiet');
@o = HPS::Monitor::check_events(\%memo, 9120, $pair->('mem', 'WARNING', 'a'), $pair->('load', 'WARNING', 'b'));
is(scalar @o, 2, 'check_events: each check has its own clock');
@o = HPS::Monitor::check_events(undef, 9120, $pair->('mem', 'WARNING', 'a'));
is(scalar @o, 1, 'check_events: without a memo (a one-off run) a bad state is logged');
@o = HPS::Monitor::check_events(undef, 9121, $pair->('mem', 'OK', 'b'));
is(scalar @o, 0, 'check_events: and an OK is not');
@o = HPS::Monitor::check_events(\%memo, 9200, [ 'x', 'hps-monitor: host=n1.lab.hps check=odd state=WEIRD x' ]);
is(scalar @o, 0, 'check_events: a state outside the list makes no event');
@o = HPS::Monitor::check_events(\%memo, 9300, [ 'x', 'hps-monitor: host=n1.lab.hps check=big state=WARNING ' . ('y' x 400) ]);
cmp_ok(length(ev($o[0])->{text}), '<', 220, 'check_events: a long summary is cut');

#--- service_event and heartbeat ------------------------------------------------------------------
$e = ev(HPS::Monitor::service_event('started', 'started'));
is_deeply([ @$e{qw(pri kind subject state text)} ], [ 'info', 'service', 'hps-monitor', 'started', 'hps-monitor: started' ], 'service_event: started');
$e = ev(HPS::Monitor::service_event('failed', 'run failed: x', 'warning'));
is_deeply([ @$e{qw(pri state attention)} ], [ 'warning', 'failed', 1 ], 'service_event: a failure is a warning');
my %hb;
my @h = HPS::Monitor::heartbeat(\%hb, 1000, 60);
is(scalar @h, 1, 'heartbeat: the first call');
is(ev($h[0])->{text}, 'hps-monitor: alive interval=60s', 'heartbeat: text');
is(scalar(() = HPS::Monitor::heartbeat(\%hb, 1000 + HPS::Event::REMIND - 1, 60)), 0, 'heartbeat: quiet between');
is(scalar(() = HPS::Monitor::heartbeat(\%hb, 1000 + HPS::Event::REMIND, 60)), 1, 'heartbeat: again at REMIND');
is(ev((HPS::Monitor::heartbeat({}, 1, 0))[0])->{text}, 'hps-monitor: alive, checks off', 'heartbeat: with the checks off');
cmp_ok(HPS::Event::REMIND * 2, '<=', 3600 * 2, 'two heartbeats fit in the default two-hour read');

#--- hps-metrics reads the rotated metrics files ---------------------------------------------
use File::Temp qw(tempdir);
use IO::Compress::Gzip qw(gzip $GzipError);
my $ld = tempdir(CLEANUP => 1);
my $gzt = "2026-11-12T08:00:00Z metric ips hps: hps-monitor: host=n1.lab.hps check=mem state=OK MEM OK\n";
gzip(\$gzt => "$ld/metrics-2026-11-12.log.gz") or die $GzipError;
my ($sname, $sfiles) = HPS::Metrics->new(log_dir => $ld)->source;
is($sname, 'metrics.log', 'source: a rotated metrics file alone is the metrics source');
is_deeply([ map { $_->[0] =~ s{.*/}{}r } @$sfiles ], [ 'metrics-2026-11-12.log.gz' ], 'source: the rotated, compressed file is listed');
is((HPS::Metrics->new(log_dir => "$ld/none")->source)[0], 'none', 'source: nothing at all is none');

done_testing;
