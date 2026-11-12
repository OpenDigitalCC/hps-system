#!/usr/bin/env perl
# IPS-34 item 1: when storage comes back, the healer tries at once. A
# storage-path issue that names a portal resolving (hps-issue-watch, on_resolve
# -> HPS::IssueHeal::resolved), or a storage host's storage-up finishing
# (hps-storage up -> HPS::IssueHeal::storage_back), sets heal.next_at = now on
# the open or healing mirror-leg issues with a leg on that portal, with the
# trail entry "retry storage <ip> back". s1 drill (issue 20261112-039): sch-002
# was back about 16:37 UTC and the 5-minute backoff step held the rejoin until
# 16:41:31.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Issues;
use HPS::IssueWatch;
use HPS::IssueHeal;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
for my $h ([ '525400000012', 'tch-002', '10.9.0.12' ], [ '525400000013', 'tch-003', '10.9.0.13' ]) {
    $reg->host_set($h->[0], 'HOSTNAME', $h->[1]);
    $reg->host_set($h->[0], 'IP', $h->[2]);
}
# two VMs: app's remote leg on sch-002 (10.113.0.20), db's on sch-003 (10.113.0.30)
my $APP_REMOTE = 'iscsi:10.113.0.20:iqn.2026-01.hps.s1:sch-002-app';
my $DB_REMOTE  = 'iscsi:10.113.0.30:3260:iqn.2026-01.hps.s1:sch-003-db';
$reg->cluster_set('lab', 'workload_t1', { state => 'running', vms => {
    'app' => { host => 'tch-002', disks => { root => { md => '/dev/md/t1-app-root', legs => [ 'local:s/app', $APP_REMOTE ] } } },
    'db'  => { host => 'tch-003', disks => { root => { md => '/dev/md/t1-db-root',  legs => [ 'local:s/db',  $DB_REMOTE ] } } },
} });

my $now = 1_794_500_000;
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });
my @calls;
my $runner = bless {}, 'Rec';
sub Rec::call { my ($s, %a) = @_; push @calls, $a{script}; return { rc => 0, stdout => "MIRROR $a{args}[0] clean\n", stderr => '' } }
my $heal = HPS::IssueHeal->new(issues => $is, runner => $runner, now => sub { $now });

sub leg_issue {
    my (%f) = @_;
    my ($r) = $is->open_issue(kind => 'mirror-leg', key_fields => [qw(host mirror)], fields => \%f);
    $is->update($r->{id}, sub { my ($x) = @_; $x->{heal} = { attempts => 3, next_at => $now + 300 } });
    return $r->{id};
}
sub retries { my ($id) = @_; return [ map { $_->{detail} } grep { $_->{event} eq 'retry' } @{ $is->get($id)->{trail} } ] }

my $app = leg_issue(host => 'tch-002', mirror => 't1-app-root');          # leg found from the workload record
my $db  = leg_issue(host => 'tch-003', mirror => 't1-db-root');           # spec written <ip>:3260
my $hint = leg_issue(host => 'tch-003', mirror => 'gone', leg => 'iqn.2026-01.hps.s1:sch-002-x@10.113.0.20:3260');
my $human = leg_issue(host => 'tch-002', mirror => 't1-app-other', leg => 'iqn.x@10.113.0.20:3260');
$is->update($human, sub { my ($x) = @_; $is->set_state($x, 'needs-human', 'DIVERGED') });

#--- a storage-path issue for 10.113.0.20 resolves
my ($sp) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], fields => { host => 'tch-002', portal => '10.113.0.20:3260' });
my @due = $heal->resolved($is->resolve($sp->{id}, 'log tch-002 iscsid: operational'));
is_deeply([ sort @due ], [ sort $app, $hint ], 'the mirror-leg issues on 10.113.0.20 are due: by workload leg spec and by the marker leg=');
is($is->get($app)->{heal}{next_at}, $now, 'heal.next_at = now');
is($is->get($app)->{heal}{attempts}, 3, 'the attempts are kept (the backoff resumes if this try fails)');
is_deeply(retries($app), ['storage 10.113.0.20 back'], 'trail: retry storage 10.113.0.20 back');
is($is->get($db)->{heal}{next_at}, $now + 300, 'a leg on another portal keeps its wait');
is($is->get($human)->{state}, 'needs-human', 'needs-human is left to the human');
ok(!grep({ $_->{event} eq 'retry' } @{ $is->get($human)->{trail} }), 'and gets no retry');
ok((grep { /^info hps-issue: retry \Q$app\E mirror-leg:tch-002:t1-app-root: storage 10\.113\.0\.20 back/ } @log), 'logged');

is_deeply([ $heal->resolved($is->get($sp->{id})) ], [], 'again: already due, nothing changes');
is_deeply(retries($app), ['storage 10.113.0.20 back'], 'no second trail entry');
my ($other) = $is->open_issue(kind => 'om3-hb', key_fields => [qw(host peer)], fields => { host => 'tch-002', peer => 'sch-002' });
is_deeply([ $heal->resolved($is->resolve($other->{id}, 'x')) ], [], 'another kind resolving: nothing');
my ($noportal) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], fields => { host => 'tch-003' });
is_deeply([ $heal->resolved($is->resolve($noportal->{id}, 'x')) ], [], 'a storage-path issue without a portal: nothing');

#--- the healer runs them at its next tick
@calls = ();
is($heal->tick, 2, 'next tick: both due issues are healed');
is($is->get($app)->{state}, 'resolved', 'mirror-status clean: resolved');

#--- storage-up of sch-003 finished: its export portals, written either way
@due = $heal->storage_back('10.113.0.30', '10.113.0.30:3260');
is_deeply(\@due, [$db], 'storage_back: the issue on 10.113.0.30, once for the two spellings');
is_deeply(retries($db), ['storage 10.113.0.30 back'], 'one trail entry');
is_deeply([ $heal->storage_back() ], [], 'no portals: nothing');

#--- hps-issue-watch: a resolve rule calls on_resolve with the resolved record
{
    my $rules = HPS::IssueWatch::load_rules("$Bin/../lib/hps-issue-rules.conf");
    my @seen;
    my $w = HPS::IssueWatch->new(issues => $is, rules => $rules, log_dir => "$base/log", now => sub { $now },
        on_resolve => sub { push @seen, $_[0] });
    my $l = 'Nov 12 16:37:0%d 10.9.0.12 [tch-002] iscsid: iscsid: %s';
    $w->line(sprintf($l, $_, 'connect to 10.113.0.20:3260 failed (No route to host)'), 2026, 11) for 1 .. 3;
    ok($is->find_open('storage-path:tch-002'), 'three failures: storage-path open');
    $w->line(sprintf($l, 5, 'connection2:0 is operational after recovery (9 attempts)'), 2026, 11);
    is(scalar @seen, 1, 'the resolve called on_resolve once');
    is($seen[0]{kind}, 'storage-path', 'with the resolved record');
    is($seen[0]{state}, 'resolved', 'after the resolve');
    is($seen[0]{fields}{portal}, '10.113.0.20:3260', 'its portal field is what the healer reads');
    $w->line(sprintf($l, 6, 'connection2:0 is operational after recovery (9 attempts)'), 2026, 11);
    is(scalar @seen, 1, 'a resolve line with nothing open: not called');

    my $wf = HPS::IssueWatch->new(issues => $is, rules => $rules, log_dir => "$base/log", now => sub { $now },
        logger => sub { push @log, "$_[0] $_[1]" }, on_resolve => sub { die "boom\n" });
    $wf->line(sprintf($l, $_, 'connect to 10.113.0.20:3260 failed (x)'), 2026, 11) for 1 .. 3;
    $wf->line(sprintf($l, 7, 'connection2:0 is operational now'), 2026, 11);
    ok(!$is->find_open('storage-path:tch-002'), 'an on_resolve that dies: the resolve stands');
    ok((grep { /^err hps-issue: after resolving .*: boom/ } @log), 'and the failure is logged');
}

done_testing;
