#!/usr/bin/env perl
# HPS::Event (docs/LOGGING.md "Event lines"): the marker grammar, its fixed
# vocabulary, format and parse, the logger hand-off and the reminder clock.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;

#--- vocabulary -------------------------------------------------------------------------
is_deeply([ HPS::Event::priorities() ], [ qw(urgent warning notice info) ], 'priorities, worst first');
is_deeply([ HPS::Event::kinds() ], [ sort qw(issue monitor workload storage node power job pairing boot auth service log) ], 'kinds');
ok(( grep { $_ eq 'unreachable' } HPS::Event::states() ), 'states include unreachable');
is(HPS::Event::syslog_level('urgent'), 'err', 'urgent is syslog err');
is(HPS::Event::syslog_level('warning'), 'warning', 'warning is syslog warning');
is(HPS::Event::syslog_level('notice'), 'notice', 'notice');
is(HPS::Event::syslog_level('info'), 'info', 'info');
is(HPS::Event::syslog_level('bogus'), 'info', 'an unknown priority maps to info');
ok(HPS::Event::needs_attention('urgent') && HPS::Event::needs_attention('warning'), 'urgent and warning need attention');
ok(!HPS::Event::needs_attention('notice') && !HPS::Event::needs_attention('info'), 'notice and info do not');
is(HPS::Event::marker('warning'), 'HPS-ALERT', 'an attention priority takes the alert marker');
is(HPS::Event::marker('notice'), 'HPS-EVENT', 'the others the event marker');
ok(HPS::Event::rank('urgent') > HPS::Event::rank('warning') && HPS::Event::rank('warning') > HPS::Event::rank('notice')
   && HPS::Event::rank('notice') > HPS::Event::rank('info'), 'rank orders the priorities');
is(HPS::Event::rank('x'), -1, 'rank of an unknown priority');
ok(HPS::Event::is_priority('info') && !HPS::Event::is_priority('debug') && !HPS::Event::is_priority(undef), 'is_priority');
is(HPS::Event::state_class('open'), 'standing', 'open is standing');
is(HPS::Event::state_class('resolved'), 'clearing', 'resolved is clearing');
is(HPS::Event::state_class('done'), 'point', 'done is a point');
is(HPS::Event::state_class('nonsense'), undef, 'an unknown state has no class');

#--- subject_token ----------------------------------------------------------------------
is(HPS::Event::subject_token('sch-001.s1.hps/zpool'), 'sch-001.s1.hps/zpool', 'a subject keeps its . - / characters');
is(HPS::Event::subject_token('a b=c'), 'a_b_c', 'space and = become _');
is(HPS::Event::subject_token(''), '-', 'empty is -');
is(HPS::Event::subject_token(undef), '-', 'undef is -');
is(HPS::Event::subject_token('  _x'), 'x', 'leading junk dropped');
is(length HPS::Event::subject_token('a' x 300), 128, 'a long subject is cut at 128');

#--- line -------------------------------------------------------------------------------
is(HPS::Event::line(pri => 'warning', kind => 'issue', subject => 'zfs-vdev:sch-001', state => 'open', text => "hps-issue: opened\nI-7"),
    'HPS-ALERT pri=warning kind=issue subject=zfs-vdev:sch-001 state=open hps-issue: opened I-7',
    'an alert line: marker, fixed fields, text with control characters flattened');
is(HPS::Event::line(pri => 'notice', kind => 'job', subject => 'j7', state => 'ended'),
    'HPS-EVENT pri=notice kind=job subject=j7 state=ended', 'no text, no trailing space');
for my $bad ([ pri => 'debug' ], [ kind => 'weather' ], [ state => 'sunny' ]) {
    my %f = (pri => 'info', kind => 'job', subject => 's', state => 'done', @$bad);
    ok(!eval { HPS::Event::line(%f); 1 } && $@ =~ /unknown $bad->[0]/s, "a word outside the vocabulary dies: $bad->[0]") or diag $@;
}

#--- parse ------------------------------------------------------------------------------
my $ev = HPS::Event::parse('hps: HPS-ALERT pri=urgent kind=monitor subject=sch-001.s1.hps state=unreachable hps-monitor: host=x state=UNREACHABLE no route');
is_deeply($ev, { pri => 'urgent', kind => 'monitor', subject => 'sch-001.s1.hps', state => 'unreachable',
    text => 'hps-monitor: host=x state=UNREACHABLE no route', class => 'standing', attention => 1 }, 'parse: every field, from inside a longer message');
$ev = HPS::Event::parse('HPS-EVENT pri=info kind=job subject=- state=done');
is($ev->{text}, '', 'parse: no text');
is($ev->{attention}, 0, 'parse: info is not attention');
is(HPS::Event::parse('HPS-EVENT pri=warning kind=job subject=x state=failed')->{attention}, 1,
    'the priority decides attention, never the marker word');
is(HPS::Event::parse('HPS-EVENT pri=bogus kind=job subject=x state=done'), undef, 'parse: a priority outside the list');
is(HPS::Event::parse('HPS-EVENT pri=info kind=nope subject=x state=done'), undef, 'parse: a kind outside the list');
is(HPS::Event::parse('HPS-EVENT pri=info kind=job subject=x state=nope'), undef, 'parse: a state outside the list');
is(HPS::Event::parse('HPS-EVENT pri=info kind=job subject=a=b state=done'), undef, 'parse: a subject with = is not one');
is(HPS::Event::parse('HPS-ISSUE open kind=mirror-leg'), undef, 'parse: the nodes\' HPS-ISSUE marker is not an event');
is(HPS::Event::parse('just a line'), undef, 'parse: no marker');
is(HPS::Event::parse(undef), undef, 'parse: undef');
my $rt = HPS::Event::parse(HPS::Event::line(pri => 'notice', kind => 'pairing', subject => 'cnh-001', state => 'paired', text => 'ce_approve: approving'));
is($rt->{text}, 'ce_approve: approving', 'line then parse round-trips');

#--- log_event ----------------------------------------------------------------------------
my @got;
HPS::Event::log_event(sub { push @got, [@_] }, pri => 'urgent', kind => 'issue', subject => 'k', state => 'escalated', text => 't');
is_deeply(\@got, [ [ 'err', 'HPS-ALERT pri=urgent kind=issue subject=k state=escalated t' ] ], 'log_event: the syslog level and the line');
ok(!eval { HPS::Event::log_event(sub { }, pri => 'x', kind => 'job', subject => 's', state => 'done'); 1 }, 'log_event dies on a bad word');

#--- remind_due ---------------------------------------------------------------------------
my %memo;
ok(HPS::Event::remind_due(\%memo, 'k', 1000), 'remind_due: the first time is due');
ok(!HPS::Event::remind_due(\%memo, 'k', 1000 + HPS::Event::REMIND - 1), 'not due just before the period');
ok(HPS::Event::remind_due(\%memo, 'k', 1000 + HPS::Event::REMIND), 'due at the period');
ok(!HPS::Event::remind_due(\%memo, 'k', 1000 + HPS::Event::REMIND + 5), 'the due time is noted');
ok(HPS::Event::remind_due(\%memo, 'other', 1000 + HPS::Event::REMIND + 5), 'another key has its own clock');
ok(HPS::Event::remind_due(\%memo, 'short', 10, 5) && !HPS::Event::remind_due(\%memo, 'short', 12, 5) && HPS::Event::remind_due(\%memo, 'short', 15, 5), 'a period can be given');
cmp_ok(HPS::Event::REMIND, '<', 3600, 'the reminder is shorter than the attention window (one hour)');

done_testing;
