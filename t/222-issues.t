#!/usr/bin/env perl
# The issue register (HPS::Issues, bin/hps-issues; docs/ISSUES.md): one record
# per issue, dedupe by key, the trail (counted repeats, the seen cap), resolve,
# re-occurrence after resolve, notes, secrets refused, and the CLI.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Issues;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

my $now = 1_794_470_400;    # 2026-11-12T08:00:00Z
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });

is($is->dir, "$base/clusters/lab/issues", 'the register is <cluster dir>/issues');

my %leg = (kind => 'mirror-leg', key_fields => [qw(host mirror)],
    fields => { host => 'tch-002.lab.hps', mirror => 'probe-tch-002-root', component => 'sdb', event => 'Fail' });

my ($r, $new) = $is->open_issue(%leg, detail => 'log tch-002 hps-issue: HPS-ISSUE open ...');
ok($new, 'the first open is a new issue');
is($r->{id}, '20261112-001', 'id is <date>-<seq>');
is($r->{key}, 'mirror-leg:tch-002:probe-tch-002-root', 'key = kind and the key fields, host as its short name');
is($r->{state}, 'open', 'state open');
is($r->{severity}, 'warning', 'default severity warning');
is($r->{opened_at}, '2026-11-12T08:00:00Z', 'opened_at is ISO UTC');
ok(!defined $r->{resolved_at}, 'resolved_at null');
is($r->{summary}, $r->{key}, 'summary defaults to the key');
is($r->{fields}{component}, 'sdb', 'the other fields are kept');
is($r->{trail}[0]{event}, 'opened', 'trail starts with opened');
ok(-f "$base/clusters/lab/issues/20261112-001.json", 'one JSON file per issue');
like($log[-1], qr/\Awarning hps-issue: opened 20261112-001 mirror-leg:tch-002:probe-tch-002-root\z/, 'opening is logged');

# a second open of the same key: same issue, trail and counter
$now += 10;
($r, $new) = $is->open_issue(%leg, detail => 'same line');
ok(!$new, 'a second open of an open key is not a new issue');
is($r->{id}, '20261112-001', 'same id');
is($r->{seen}, 2, 'seen counts');
is($r->{trail}[-1]{event}, 'seen', 'a seen entry');
$is->open_issue(%leg, detail => 'same line') for 1 .. 3;
$r = $is->get('20261112-001');
is($r->{seen}, 5, 'seen 5');
my @seen = grep { $_->{event} eq 'seen' } @{ $r->{trail} };
is(scalar @seen, 1, 'identical repeats fold into one trail entry');
is($seen[0]{count}, 4, 'with a count');
$is->open_issue(%leg, detail => "line $_") for 1 .. 20;
$r = $is->get('20261112-001');
is($r->{seen}, 25, 'every repeat is counted');
@seen = grep { $_->{event} eq 'seen' } @{ $r->{trail} };
cmp_ok(scalar @seen, '<=', HPS::Issues::SEEN_TRAIL, 'past the cap repeats are counted, not kept');
is(scalar $is->all, 1, 'still one issue');

# severity: an urgent report escalates
($r) = $is->open_issue(%leg, severity => 'urgent', detail => 'urgent now');
is($r->{severity}, 'urgent', 'an urgent open escalates an open issue');
is((grep { $_->{event} eq 'escalated' } @{ $r->{trail} })[0]{detail}, 'reported as urgent', 'escalation in the trail');

# a different key is a different issue
my ($r2, $new2) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host mirror)],
    fields => { host => 'tch-002', mirror => 'probe-tch-002-data' });
ok($new2, 'another mirror is another issue');
is($r2->{id}, '20261112-002', 'next sequence number');

# note
$is->note('20261112-001', 'looking at the NAS', 'alice');
is($is->get('20261112-001')->{trail}[-1]{detail}, 'alice: looking at the NAS', 'a note in the trail');

# list
is(scalar $is->list, 2, 'list: the unresolved ones');

# resolve
$now += 60;
$r = $is->resolve('20261112-001', 'log tch-002 hps-issue: HPS-ISSUE resolve kind=mirror-leg');
is($r->{state}, 'resolved', 'resolved');
is($r->{resolved_at}, '2026-11-12T08:01:10Z', 'resolved_at set');
like($r->{trail}[-1]{detail}, qr/\Aby log tch-002/, 'the trail says what resolved it');
like($log[-1], qr/hps-issue: resolved 20261112-001 by log tch-002/, 'resolving is logged');
is(scalar $is->list, 1, 'a resolved issue leaves the default list');
is(scalar $is->list(all => 1), 2, 'and stays in --all (history)');
my $e = eval { $is->resolve('20261112-001', 'again'); 1 } ? undef : $@;
is(ref $e && $e->kind, 'refused', 'resolving a resolved issue is refused');
ok(!defined $is->resolve_key('mirror-leg:tch-002:probe-tch-002-root', 'x'), 'resolve_key of a key with nothing open: undef');

# re-occurrence after resolve: a new issue naming the previous one
$now += 3600;
($r, $new) = $is->open_issue(%leg, detail => 'again');
ok($new, 'a re-occurrence after resolve is a new issue');
is($r->{id}, '20261112-003', 'with a new id');
is($r->{previous}, '20261112-001', 'naming the previous issue');
is($r->{trail}[1]{event}, 'reoccurred', 'and saying so in the trail');
ok(-f "$base/clusters/lab/issues/20261112-001.json", 'the resolved issue is kept');

# next day restarts the sequence
$now += 86400;
($r) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], fields => { host => 'tch-001' });
is($r->{id}, '20261113-001', 'a new day starts at 001');

# validation and secrets
for my $bad (
    [ 'kind', { kind => 'Bad Kind', key_fields => ['host'], fields => { host => 'a' } } ],
    [ 'missing key field', { kind => 'x', key_fields => [qw(host mirror)], fields => { host => 'a' } } ],
    [ 'value with space', { kind => 'x', key_fields => ['host'], fields => { host => 'a b' } } ],
    [ 'value with ..', { kind => 'x', key_fields => ['host'], fields => { host => 'a', p => '../etc' } } ],
    [ 'secret field', { kind => 'x', key_fields => ['host'], fields => { host => 'a', token => 'abc' } } ],
    [ 'severity', { kind => 'x', key_fields => ['host'], fields => { host => 'a' }, severity => 'meh' } ],
) {
    my $err = eval { $is->open_issue(%{ $bad->[1] }); 1 } ? undef : $@;
    is(ref $err && $err->kind, 'usage', "refused: $bad->[0]");
}
my $err = eval { HPS::Issues::caller_text('the note', 'password=hunter2'); 1 } ? undef : $@;
is(ref $err && $err->kind, 'usage', 'a secret-looking note is refused');
is(HPS::Issues::clean_text("x\n-----BEGIN PRIVATE KEY-----"), '[redacted]', 'a secret-looking log line is redacted');
is(length HPS::Issues::clean_text('z' x 1000), HPS::Issues::TEXT_MAX, 'texts are capped');
$err = eval { $is->get('../x'); 1 } ? undef : $@;
is(ref $err && $err->kind, 'usage', 'an id is never a path');
$err = eval { $is->get('20991231-001'); 1 } ? undef : $@;
is(ref $err && $err->kind, 'notfound', 'unknown id: notfound');

# the trail cap
{
    my ($t) = $is->open_issue(kind => 'cap', key_fields => ['host'], fields => { host => 'z' });
    $is->update($t->{id}, sub { my $x = shift; $is->trail($x, 'n', "e$_") for 1 .. HPS::Issues::TRAIL_MAX + 10 });
    my $x = $is->get($t->{id});
    is(scalar @{ $x->{trail} }, HPS::Issues::TRAIL_MAX + 1, 'the trail stops at its cap plus one counting entry');
    is($x->{trail}[-1]{event}, 'trail-full', 'which says so');
}

#--- the CLI ------------------------------------------------------------------------
my $bin = "$Bin/../bin/hps-issues";
$ENV{HPS_CONFIG_BASE}      = $base;
$ENV{HPS_SYSTEM_REGISTRY}  = "$base/system.db";
$ENV{HPS_ISSUES_NO_SYSLOG} = 1;
$ENV{HPS_ISSUE_RULES}      = "$Bin/../lib/hps-issue-rules.conf";
$ENV{USER}                 = 'tester';
delete $ENV{SUDO_USER};

sub cli { my $o = qx($^X $bin @_ 2>&1); return ($? >> 8, $o) }

my ($rc, $out) = cli('list');
is($rc, 0, 'cli list exit 0');
like($out, qr/^20261112-002 +open +warning +mirror-leg:tch-002:probe-tch-002-data/m, 'cli list shows open issues');
unlike($out, qr/^20261112-001 /m, 'not the resolved ones');
($rc, $out) = cli('list', '--all', '--json');
my $j = decode_json($out);
ok((grep { $_->{id} eq '20261112-001' } @{ $j->{issues} }), 'list --all --json has the resolved ones');

($rc, $out) = cli('open', '--kind', 'mirror-leg', '--key-field', 'host=tch-009', '--key-field', 'mirror=m1',
    '--key-field', 'component=sdc', '--summary', 'leg', 'lost', 'by', 'hand');
is($rc, 0, 'cli open exit 0') or diag $out;
my ($id) = $out =~ /^opened (\S+) mirror-leg:tch-009:m1$/m;
ok($id, 'cli open: the key is the rules file\'s host,mirror');
($rc, $out) = cli('show', $id, '--json');
$j = decode_json($out);
is($j->{summary}, 'leg lost by hand', 'words after the options join the summary');
is($j->{trail}[0]{detail}, 'filed by tester', 'the trail says who filed it');
($rc, $out) = cli('open', '--kind', 'mirror-leg', '--key-field', 'host=tch-009');
is($rc, 2, 'cli open without a key field of the kind: usage');
like($out, qr/mirror is missing/, 'naming the missing field');
($rc, $out) = cli('open', '--kind', 'disk', '--key-field', 'host=tch-009', '--key-field', 'dev=sdc');
like($out, qr/^opened \S+ disk:tch-009:sdc$/m, 'an undeclared kind is keyed by the fields given, in order');
($rc, $out) = cli('note', $id, 'swapped', 'the', 'cable');
is($rc, 0, 'cli note');
($rc, $out) = cli('show', $id);
like($out, qr/note tester: swapped the cable/, 'show prints the trail');
($rc, $out) = cli('note', $id, 'token=abc');
is($rc, 2, 'a secret-looking note is refused');
# retry: a needs-human issue back to open, its backoff reset
$is->update($id, sub { my $x = shift; $is->set_state($x, 'needs-human', 'mirror-rejoin exit 3'); $x->{heal} = { attempts => 4, next_at => undef, last_result => 'human: x' } });
($rc, $out) = cli('retry', $id);
is($rc, 0, 'cli retry: exit 0') or diag $out;
like($out, qr/^retry \Q$id\E mirror-leg:tch-009:m1: open/m, 'says so');
my $rt = $is->get($id);
is($rt->{state}, 'open', 'retry: needs-human back to open');
is($rt->{heal}{attempts}, 0, 'retry: no attempts counted');
ok(defined $rt->{heal}{next_at} && $rt->{heal}{next_at} <= time + 1, 'retry: the next attempt is due at once');
is_deeply([ map { $_->{event} } @{ $rt->{trail} }[-2, -1] ], [qw(retry open)], 'retry: in the trail, then back to open');
is($rt->{trail}[-2]{detail}, 'retry by operator tester', 'retry by operator <who>');
($rc, $out) = cli('retry', $id);
is($rc, 0, 'retry of an open issue: resets its backoff too');
($rc, $out) = cli('retry');
is($rc, 2, 'retry without an id: usage');
($rc, $out) = cli('retry', '20991231-009');
is($rc, 4, 'retry of an unknown id: exit 4');
($rc, $out) = cli('resolve', '--kind', 'mirror-leg', '--key-field', 'host=tch-009', '--key-field', 'mirror=m1', '--by', 'cable', 'replaced');
is($rc, 0, 'cli resolve by key') or diag $out;
like($out, qr/^resolved \Q$id\E/m, 'resolves that issue');
($rc, $out) = cli('resolve', $id, '--by', 'again');
is($rc, 3, 'resolving it again: refused');
($rc, $out) = cli('retry', $id);
is($rc, 3, 'retry of a resolved issue: refused');
like($out, qr/is resolved/, 'saying so');
($rc, $out) = cli('resolve', '20261112-002', '--by', 'fixed');
is($rc, 0, 'cli resolve by id');
($rc, $out) = cli('show', '20991231-009');
is($rc, 4, 'unknown id: exit 4');
($rc, $out) = cli('purge');
is($rc, 2, 'unknown verb: usage');
($rc, $out) = cli('--help');
is($rc, 2, '--help: usage');

done_testing;
