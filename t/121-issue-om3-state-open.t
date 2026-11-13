#!/usr/bin/env perl
# om3-hb issues the state check leaves open (IPS-34 item 16): the peer stale, the
# daemon not answering, no summary line; the cadence of the check (quiet period,
# every 60 s), the trail (a check entry, repeats counted), severity untouched, and
# the end line of the log still resolving as before.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use StorageFixture;
use HPS::Issues;
use HPS::IssueHeal;
use HPS::IssueWatch;

my $f   = StorageFixture::setup();
my $now = 1_794_470_400;
my $is = HPS::Issues->new(registry => $f->{reg}, now => sub { $now }, logger => sub { });

my $STALE = "OSVC sch-001 peers=1 beating=0 stale=sch-002.s1.hps frozen=no\n";
my $OK    = "OSVC sch-001 peers=1 beating=1 stale=- frozen=no\n";
my ($r0) = $is->open_issue(kind => 'om3-hb', key_fields => [qw(host peer)], urgent_after => 600,
    fields => { host => 'sch-001', peer => 'sch-002' }, detail => 'begin');
my $id = $r0->{id};

my $ce = FakeCE->new(out => { 'osvc-status' => [ $STALE, $STALE, "garbage\n", $OK ] },
    rc => { 'osvc-status' => [ 2, 2, 1, 0 ] });
my $h = HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $now });

$now += 31;
is($h->tick, 1, 'first check after the quiet period');
my $r = $is->get($id);
is($r->{state}, 'open', 'peer stale: still open');
is($r->{severity}, 'warning', 'severity untouched');
ok(defined $r->{urgent_at}, 'urgent_at untouched');
is($r->{trail}[-1]{event}, 'check', 'a check entry in the trail');
like($r->{trail}[-1]{detail}, qr/^osvc_hb: peer sch-002 stale \(OSVC sch-001 peers=1 beating=0 stale=sch-002\.s1\.hps/, 'naming the peer and the line');
is($h->tick, 0, 'not again before 60 s');
$now += 59;
is($h->tick, 0, 'still not at 59 s');
$now += 1;
is($h->tick, 1, 'again at 60 s');
$r = $is->get($id);
is($r->{trail}[-1]{count}, 2, 'an identical check only counts up');
$now += 60;
$h->tick;
$r = $is->get($id);
is($r->{state}, 'open', 'om not answering (exit 1): open');
like($r->{trail}[-1]{detail}, qr/^osvc_hb: osvc-status exit 1: /, 'the trail says the check failed');
is(scalar(grep { $_->{event} eq 'check' } @{ $r->{trail} }), 2, 'a different entry is a new trail line');
is(($is->get($id)->{heal} // {})->{attempts}, undef, 'no heal attempts are counted for om3-hb');

# a new report of the problem restarts the quiet period
$now += 60;
$is->open_issue(kind => 'om3-hb', key_fields => [qw(host peer)], fields => { host => 'sch-001', peer => 'sch-002' }, detail => 'begin again');
is($h->tick, 0, 'a fresh report: the check waits 30 s again');
$now += 31;
is($h->tick, 1, 'then runs');
is($is->get($id)->{state}, 'resolved', 'and the peer now beats: resolved');
is(scalar($ce->calls), 4, 'four osvc-status runs in all');

# the end line of the log still resolves (the rule is unchanged)
my $rules = HPS::IssueWatch::load_rules("$Bin/../lib/hps-issue-rules.conf");
my ($r2) = $is->open_issue(kind => 'om3-hb', key_fields => [qw(host peer)], fields => { host => 'sch-001', peer => 'sch-009' });
my @m = HPS::IssueWatch::match($rules, { host => 'sch-001.s1.hps', tag => 'om',
    message => 'daemon: hb: ucast: tx: hb#1: end a send error period for node sch-009.s1.hps: ok' });
is($m[0]{action}, 'resolve', 'the end line is still a resolve rule');
is($m[0]{rule}{settle}, 30, 'with settle=30');
is($m[0]{kind}, 'om3-hb', 'for om3-hb');

done_testing;
