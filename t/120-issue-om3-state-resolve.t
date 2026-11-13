#!/usr/bin/env perl
# om3-hb issues resolve by state (IPS-34 item 16; docs/ISSUES.md, Resolving by
# state): the healer runs osvc-status on the issue's host and, when the peer
# named in the key is beating, resolves it "by osvc_hb: peer <peer> beating" with
# a resolution record. A daemon restarted between "begin" and "end" never logs the
# end line; this is the way out.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use StorageFixture;
use HPS::Issues;
use HPS::IssueHeal;

my $f   = StorageFixture::setup();
my $now = 1_794_470_400;
my @log;
my $is = HPS::Issues->new(registry => $f->{reg}, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });

my $OK    = "== om3\n{}\nOSVC sch-001 peers=1 beating=1 stale=- frozen=no\n";
my $OK_ST = "OSVC sch-001 peers=2 beating=1 stale=sch-003.s1.hps frozen=no\n";

sub open_hb {
    my ($peer) = @_;
    my ($r) = $is->open_issue(kind => 'om3-hb', key_fields => [qw(host peer)], urgent_after => 600,
        fields => { host => 'sch-001', peer => $peer }, detail => 'log begin a send error period');
    return $r->{id};
}
sub healer {
    my $ce = FakeCE->new(@_);
    return (HPS::IssueHeal->new(issues => $is, runner => $ce, now => sub { $now }), $ce);
}

#--- units: the summary line ----------------------------------------------------------
is_deeply([ HPS::IssueHeal::osvc_peer_state($OK, 'sch-002') ], [ 'beating', "OSVC sch-001 peers=1 beating=1 stale=- frozen=no" ],
    'osvc_peer_state: no stale peer: beating');
is((HPS::IssueHeal::osvc_peer_state($OK_ST, 'sch-003'))[0], 'stale', 'a peer in the stale list (fqdn or short) is stale');
is((HPS::IssueHeal::osvc_peer_state($OK_ST, 'sch-002'))[0], 'beating', 'a peer not in the list beats');
is((HPS::IssueHeal::osvc_peer_state("OSVC sch-001 peers=0 beating=0 stale=- frozen=no\n", 'sch-002'))[0], 'unknown',
    'no peer beating at all: not proof');
is((HPS::IssueHeal::osvc_peer_state("garbage\n", 'sch-002'))[0], 'unknown', 'no summary line: unknown');

#--- the peer beats: resolved by state ------------------------------------------------
my $id = open_hb('sch-002');
my ($h, $ce) = healer(out => { 'osvc-status' => $OK });
is($h->tick, 0, 'tick: not before 30 s have passed since the last report');
is(scalar($ce->calls), 0, 'nothing is run before that');
$now += 31;
is($h->tick, 1, 'tick: 31 s after the report the issue is checked');
my @c = $ce->calls;
is($c[0]{script}, 'osvc-status', 'osvc-status ran');
is($c[0]{mac}, $StorageFixture::MAC, 'on the issue\'s host');
my $r = $is->get($id);
is($r->{state}, 'resolved', 'the peer beats: the issue is resolved');
is($r->{trail}[-1]{event}, 'resolved', 'the trail ends with the resolve');
is($r->{trail}[-1]{detail}, 'by osvc_hb: peer sch-002 beating', 'resolved by osvc_hb: peer <peer> beating');
is($r->{resolution}{by}, 'healer', 'resolution by: healer');
is($r->{resolution}{action}, 'osvc_hb check: osvc-status on sch-001', 'resolution action: the check run');
is($r->{resolution}{result}, 'osvc_hb: peer sch-002 beating (OSVC sch-001 peers=1 beating=1 stale=- frozen=no)',
    'resolution result: the evidence, the OSVC line');
is($r->{resolution}{at}, $r->{resolved_at}, 'resolution at: the resolved_at');
ok((grep { /resolved \Q$id\E by osvc_hb: peer sch-002 beating; .*resolution by healer: osvc_hb check/ } @log),
    'the syslog line says both');
$now += 600;
is($h->tick, 0, 'a resolved issue is not checked again');

#--- a peer that comes back later in the list of several ------------------------------
my $id2 = open_hb('sch-003');
$now += 100;
($h, $ce) = healer(out => { 'osvc-status' => $OK_ST });
$h->tick;
is($is->get($id2)->{state}, 'open', 'a stale peer: the issue stays open');

done_testing;
