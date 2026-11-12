#!/usr/bin/env perl
# hps-issue-watch (HPS::IssueWatch; docs/ISSUES.md): the rules file, matching
# marker and raw lines, and following the log tree: from the end at start (no
# replay), complete lines only, the state file across a restart (fresh: resume;
# stale: from the end), a new day file and a new sender. Fixture lines in
# t/data/issue-lines.log.
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
use HPS::IssueWatch;

my $RULES = "$Bin/../lib/hps-issue-rules.conf";

#--- the rules file ------------------------------------------------------------------
my $rules = HPS::IssueWatch::load_rules($RULES);
is_deeply($rules->{marker}{'mirror-leg'}, { severity => 'warning', key_fields => [qw(host mirror)] },
    'shipped: mirror-leg markers keyed by host,mirror');
is(scalar @{ $rules->{rules} }, 3, 'shipped: three raw-line rules');

for my $bad (
    [ 'nonsense', qr/line 1: a rule is/ ],
    [ "# c\nopen Kind warning host x", qr/line 2: kind 'Kind'/ ],
    [ 'open k sometimes host x', qr/severity 'sometimes'/ ],
    [ 'resolve k warning host x', qr/a resolve rule has severity -/ ],
    [ 'open k warning Host x', qr/key fields 'Host'/ ],
    [ 'open k warning host', qr/no regex/ ],
    [ 'open k warning host (unclosed', qr/does not compile/ ],
    [ 'marker k warning host extra', qr/takes no regex/ ],
    [ 'open k warning host after=0/10 x', qr/after=N\/S needs/ ],
    [ 'resolve k - host after=2/10 x', qr/after= is for open rules/ ],
) {
    my $e = eval { HPS::IssueWatch::parse_rules($bad->[0], 'r'); 1 } ? undef : $@;
    like(ref $e ? $e->message : "$e", $bad->[1], "bad rule refused: $bad->[0]");
}

#--- matching -------------------------------------------------------------------------
sub rec { my ($tag, $msg, $host) = @_; return { host => $host // 'tch-002.lab.hps', tag => $tag, message => $msg } }

my @m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=m1 component=/dev/sdb event=Fail'));
is(scalar @m, 1, 'a marker: one action');
is($m[0]{action}, 'open', 'open');
is_deeply($m[0]{key_fields}, [qw(host mirror)], 'keyed by the marker rule');
is($m[0]{fields}{component}, '/dev/sdb', 'every k=v is a field');
@m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=m1 component=- event=DegradedArray leg=iqn.2026-01.lab.nas:x@192.0.2.50:3260'));
is($m[0]{fields}{component}, '-', 'DegradedArray: component=- is a field');
is($m[0]{fields}{leg}, 'iqn.2026-01.lab.nas:x@192.0.2.50:3260', 'leg=<iqn>@<ip>:3260, last');
ok(eval { HPS::Issues::check_fields($m[0]{fields}); 1 }, 'both are valid field values');
@m = HPS::IssueWatch::match($rules, rec('hps-issue', 'HPS-ISSUE resolve kind=mirror-leg host=tch-002 mirror=m1 event=SpareActive'));
is($m[0]{action}, 'resolve', 'a resolve marker');
@m = HPS::IssueWatch::match($rules, rec('x', 'HPS-ISSUE open kind=fan severity=urgent slot=3'));
is_deeply($m[0]{key_fields}, ['host'], 'a kind with no marker rule is keyed by host');
is($m[0]{fields}{host}, 'tch-002', 'host from the line when the marker has none (short name)');
is($m[0]{severity}, 'urgent', 'the marker\'s severity wins');
ok(!exists $m[0]{fields}{severity}, 'severity is not a field');
@m = HPS::IssueWatch::match($rules, rec('x', 'HPS-ISSUE open host=a'));
is($m[0]{action}, 'bad', 'a marker without kind is bad');
@m = HPS::IssueWatch::match($rules, rec('kernel', 'md/raid1:md127: Disk failure on sdb, disabling device.'));
is($m[0]{kind}, 'mirror-leg', 'kernel md failure: mirror-leg');
is_deeply([ @{ $m[0]{fields} }{qw(host md component)} ], [qw(tch-002 md127 sdb)], 'keyed by host and md');
@m = HPS::IssueWatch::match($rules, rec('kernel', '[ 1234.5678] md/raid1:md5: Disk failure on dm-3, disabling device.'));
is($m[0]{fields}{md}, 'md5', 'a kernel time stamp in front is allowed');
@m = HPS::IssueWatch::match($rules, rec('iscsid', 'connect to 192.0.2.50:3260 failed (No route to host)'));
is($m[0]{kind}, 'storage-path', 'iscsid connect failure: storage-path');
is($m[0]{rule}{after_n}, 3, 'after 3');
@m = HPS::IssueWatch::match($rules, rec('sshd', 'Accepted publickey for root'));
is(scalar @m, 0, 'an ordinary line: nothing');

#--- following ------------------------------------------------------------------------------
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $logd = "$base/log";
make_path("$logd/10.9.0.12", "$logd/ips");

my $now = 1_794_470_400;    # 2026-11-12T08:00:00Z
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });
sub watcher { return HPS::IssueWatch->new(issues => $is, rules => $rules, log_dir => $logd, now => sub { $now }, @_) }
sub append { my ($f, $text) = @_; open(my $fh, '>>', $f) or die "$f: $!"; print {$fh} $text; close $fh }
my $f12 = "$logd/10.9.0.12/2026-11-12.log";

# history before the start: never replayed
append($f12, "Nov 12 07:00:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=old\n");
append("$logd/ips/2026-11-12.log", "Nov 12 07:00:00 127.0.0.1 [ips] hps: HPS-ISSUE open kind=x host=ips\n");
my $w = watcher();
$w->start;
is($w->poll, 0, 'start: nothing read from before the start');
is(scalar $is->all, 0, 'no issue from old lines');
ok(-f "$base/clusters/lab/issues/.watch-state.json", 'the state file is written');
like($log[-1], qr/watch started at the end of 1 file/, 'the start is logged');

# the fixture lines
open(my $fx, '<', "$Bin/data/issue-lines.log") or die $!;
my $fixture = do { local $/; <$fx> };
close $fx;
append($f12, $fixture);
@log = ();
is($w->poll, 11, 'the new lines are read');
my %by_key = map { $_->{key} => $_ } $is->list(all => 1);
my $leg = $by_key{'mirror-leg:tch-002:probe-tch-002-root'};
ok($leg, 'the marker opened mirror-leg:tch-002:probe-tch-002-root');
is($leg->{seen}, 2, 'its second open marker counted');
is($leg->{state}, 'resolved', 'the resolve marker resolved it');
like($leg->{trail}[-1]{detail}, qr/\Aby log tch-002 hps-issue: HPS-ISSUE resolve/, 'resolved by the line');
is($leg->{fields}{leg}, 'iqn.2026-01.lab.nas:hpslab-root@192.0.2.50:3260', 'the leg hint is a field');
is($leg->{fields}{component}, '/dev/sdb', 'the component is a field');
ok($by_key{'mirror-leg:tch-002:md127'}, 'the kernel line opened mirror-leg:tch-002:md127');
is($by_key{'mirror-leg:tch-002:md127'}{state}, 'open', 'and it stays open');
my $sp = $by_key{'storage-path:tch-002'};
ok($sp, 'three iscsid failures opened storage-path:tch-002');
is($sp->{seen}, 1, 'at the third (the first two only counted)');
is($sp->{state}, 'resolved', 'the operational line resolved it');
ok(!$by_key{'leak:tch-002'}, 'a marker with a secret-looking field opens nothing');
is(scalar(grep { /ignored a line from tch-002/ } @log), 2, 'the two bad markers are logged as ignored');
ok(!(grep { /abc|0123/ } @log), 'the ignored lines\' text is not logged');
ok((grep { /\Awarning hps-issue: opened \S+ mirror-leg:tch-002:probe-tch-002-root\z/ } @log), 'opened logged');
ok((grep { /\Anotice hps-issue: resolved \S+ by log tch-002/ } @log), 'resolved logged');
is(scalar $is->list, 1, 'one unresolved issue left');

# a partial line waits for its newline
append($f12, 'Nov 12 08:01:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=part');
is($w->poll, 0, 'a line without its newline is not read');
append($f12, "ial\n");
is($w->poll, 1, 'it is read once complete');
ok($is->find_open('mirror-leg:tch-002:partial'), 'whole');

# a restart with a fresh state file resumes
append($f12, "Nov 12 08:02:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=down1\n");
$now += 60;
my $w2 = watcher();
$w2->start;
like($log[-1], qr/resuming 1 file\(s\) from the state of 60s ago/, 'fresh state: resumed');
is($w2->poll, 1, 'the line written while it was down is read');
ok($is->find_open('mirror-leg:tch-002:down1'), 'and acted on');

# a restart with a stale state file starts at the end
append($f12, "Nov 12 08:20:00 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=down2\n");
$now += 1000;
my $w3 = watcher();
$w3->start;
like($log[-1], qr/older than 300s: lines in between are not read/, 'stale state: says so');
is($w3->poll, 0, 'nothing old is read');
ok(!$is->find_open('mirror-leg:tch-002:down2'), 'and nothing opened');

# a new day file: the rest of the old one, then the new one from its start
append($f12, "Nov 12 23:59:59 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=late\n");
append("$logd/10.9.0.12/2026-11-13.log", "Nov 13 00:00:01 10.9.0.12 [tch-002] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-002 mirror=early\n");
is($w3->poll, 2, 'day roll: both lines read');
ok($is->find_open('mirror-leg:tch-002:late') && $is->find_open('mirror-leg:tch-002:early'), 'both acted on');

# a new sender after the start: its file from the start
make_path("$logd/10.9.0.13");
append("$logd/10.9.0.13/2026-11-13.log", "Nov 13 00:00:02 10.9.0.13 [tch-003] hps-issue: HPS-ISSUE open kind=mirror-leg host=tch-003 mirror=r\n");
is($w3->poll, 1, 'a new sender is read from its start');
ok($is->find_open('mirror-leg:tch-003:r'), 'and acted on');

# a truncated file is read again from its start
open(my $tr, '>', "$logd/10.9.0.13/2026-11-13.log") or die $!;
print {$tr} "Nov 13 00:01:00 10.9.0.13 [tch-003] x: y\n";
close $tr;
is($w3->poll, 1, 'a file that shrank is read from its start');

# the IPS's own directory is never read
append("$logd/ips/2026-11-12.log", "Nov 12 09:00:00 127.0.0.1 [ips] hps: HPS-ISSUE open kind=x host=ips\n");
is($w3->poll, 0, 'ips/ is not a sender');

# max_read: a big backlog is read in pieces, in order
my $w4 = watcher(max_read => 200);
$w4->start;
append("$logd/10.9.0.12/2026-11-13.log", join "", map { "Nov 13 01:00:00 10.9.0.12 [tch-002] x: filler line $_\n" } 1 .. 10);
my $total = 0;
for (1 .. 10) { $total += $w4->poll }
is($total, 10, 'a backlog larger than max_read is read over several polls');

# the watcher binary checks its rules
my $o = qx($^X $Bin/../bin/hps-issue-watch check-rules $RULES 2>&1);
is($? >> 8, 0, 'hps-issue-watch check-rules: exit 0');
like($o, qr/1 marker rule\(s\), 3 line rule\(s\)/, 'and counts them');
my $badf = "$base/bad.conf";
append($badf, "open x\n");
$o = qx($^X $Bin/../bin/hps-issue-watch check-rules $badf 2>&1);
is($? >> 8, 1, 'a bad rules file: exit 1');
like($o, qr/line 1/, 'naming the line');

done_testing;
