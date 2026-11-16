#!/usr/bin/env perl
# The guest-paused trigger (lib/hps-issue-rules.conf; docs/ISSUES.md "A paused
# guest"): the each=1 rule option, the shipped rule against check_vms's monitor
# line, one issue per paused guest from a line that names several, the host
# carried from the start of the line, and what the rules never do: open for a
# pause that is not an I/O error, for a line of a node whose image prints no
# paused figure, or resolve an issue because a line no longer names the guest.
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

my $RULES = "$Bin/../lib/hps-issue-rules.conf";
my $rules = HPS::IssueWatch::load_rules($RULES);

#--- the option --------------------------------------------------------------------------
my $r = HPS::IssueWatch::parse_rules('open k warning host from=ips each=1 (?<host>h)');
ok($r->{rules}[0]{each}, 'each=1 is parsed');
ok(!HPS::IssueWatch::parse_rules('open k warning host x')->{rules}[0]{each}, 'a rule without it is not each');
my $e = eval { HPS::IssueWatch::parse_rules('open k warning host each=2 x'); 1 } ? undef : $@;
like(ref $e ? $e->message : "$e", qr/each=2: the only value is each=1/, 'each=2 is refused');
is_deeply($rules->{marker}{'guest-paused'}, { severity => 'warning', key_fields => [qw(host guest)] }, 'shipped: guest-paused markers keyed by host,guest');
my ($shipped) = grep { $_->{kind} eq 'guest-paused' } @{ $rules->{rules} };
ok($shipped->{each} && $shipped->{from} eq 'ips' && $shipped->{action} eq 'open', 'shipped: an open rule, each, from=ips');
is(scalar(grep { $_->{kind} eq 'guest-paused' && $_->{action} eq 'resolve' } @{ $rules->{rules} }), 0, 'shipped: no resolve rule (the healer resolves by state)');

#--- the generic option, on a line that names several things ------------------------------------
my $gen = HPS::IssueWatch::parse_rules('open k warning host,item from=ips each=1 (?:^hps: host=(?<host>\S+) items: |(?!\A)\G)(?<item>[a-z]+)(?:,|\z)');
my @m = HPS::IssueWatch::match($gen, { host => 'ips', tag => 'hps', message => 'host=n1 items: a,b,c' }, 1);
is_deeply([ map { "$_->{fields}{host}/$_->{fields}{item}" } @m ], [ 'n1/a', 'n1/b', 'n1/c' ], 'each: every match, the host of the first carried to the others');
@m = HPS::IssueWatch::match($gen, { host => 'ips', tag => 'hps', message => 'something else' }, 1);
is(scalar @m, 0, 'each: no match, no action (the \G alternative does not start a line)');

#--- the shipped rule on check_vms's line -----------------------------------------------------------
sub mon { return { host => 'ips', tag => 'hps', message => "hps-monitor: host=$_[0] check=vms state=$_[1]" } }
my $line = 'WARNING VMS WARNING - 1 running VMs (rss 0.5 GiB), 1 paused: web (ioerror) | vms=1 paused=1 web_paused_ioerror=1 app_vcpus=2 app_rss=1B';
@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', $line), 1);
is(scalar @m, 1, 'one paused guest: one action');
is_deeply([ @{ $m[0] }{qw(action kind severity)} ], [qw(open guest-paused warning)], 'opens guest-paused, warning');
is_deeply($m[0]{key_fields}, [qw(host guest)], 'keyed by host and guest');
is_deeply([ @{ HPS::Issues::check_fields($m[0]{fields}) }{qw(host guest reason)} ], [qw(tch-001 web ioerror)], 'host (stored short), guest, reason');

$line = 'WARNING VMS WARNING - no running VMs, 3 paused: a (ioerror), b (user), c (ioerror) | vms=0 paused=3 a_paused_ioerror=1 b_paused_user=1 c_paused_ioerror=1';
@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', $line), 1);
is_deeply([ map { "$_->{fields}{host} $_->{fields}{guest}" } @m ], [ 'tch-001.s1.hps a', 'tch-001.s1.hps c' ],
    'several guests: one issue each, and only the I/O-error ones (b was paused by an operator)');

$line = 'WARNING VMS WARNING - 2 running VMs (rss 1.0 GiB), 2 paused: web-1 (ioerror), db-2 (ioerror) | vms=2 paused=2 web-1_paused_ioerror=1 db-2_paused_ioerror=1 x_vcpus=1 y_vcpus=1';
@m = HPS::IssueWatch::match($rules, mon('tch-002.s1.hps', $line), 1);
is_deeply([ map { $_->{fields}{guest} } @m ], [ 'web-1', 'db-2' ], 'guest names with a hyphen and a digit; the labels are in line order');

@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', 'OK VMS OK - 1 running VMs (rss 0.5 GiB) | vms=1 paused=0 web_vcpus=2 web_paused_ioerror=1'), 1);
is(scalar @m, 0, 'a line that is not WARNING opens nothing');
@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', 'OK VMS OK - 1 running VMs (rss 0.5 GiB), 1 paused: db (user) | vms=1 paused=1 db_paused_user=1 web_vcpus=2'), 1);
is(scalar @m, 0, 'a guest an operator paused opens nothing');
@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', 'OK VMS OK - 1 running VMs (rss 0.5 GiB) | vms=1 web_vcpus=2'), 1);
is(scalar @m, 0, 'a node on an older image (no paused figure): nothing opened');
@m = HPS::IssueWatch::match($rules, mon('tch-001.s1.hps', $line), 0);
is(scalar(grep { $_->{kind} eq 'guest-paused' } @m), 0, 'the same line from a node\'s own file: nothing (a node cannot speak for the monitor)');
@m = HPS::IssueWatch::match($rules, { host => 'tch-001', tag => 'hps-issue', message => 'HPS-ISSUE open kind=guest-paused host=tch-001 guest=web' }, 0);
is_deeply([ map { "$_->{action} $_->{kind} @{$_->{key_fields}}" } @m ], ['open guest-paused host guest'], 'a node marker for the kind is keyed by host and guest');

#--- the watcher: lines through to the register, and nothing resolves by absence -------------------------
my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->host_set('525400000012', 'HOSTNAME', 'tch-001');
$reg->host_set('525400000012', 'IP', '10.9.0.12');
my $now = 1_794_470_400;
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, "$_[0] $_[1]" });
my $w = HPS::IssueWatch->new(issues => $is, rules => $rules, log_dir => "$base/log", now => sub { $now });
sub ips_line { my $m = shift; return "Nov 12 08:00:00 127.0.0.1 [ips] hps: hps-monitor: host=tch-001.lab.hps check=vms state=$m" }

$w->line(ips_line('WARNING VMS WARNING - no running VMs, 2 paused: a (ioerror), b (ioerror) | vms=0 paused=2 a_paused_ioerror=1 b_paused_ioerror=1'), 2026, 11, 1);
my @open = $is->list;
is_deeply([ map { $_->{key} } @open ], [ 'guest-paused:tch-001:a', 'guest-paused:tch-001:b' ], 'two paused guests, two issues');
is($open[0]{fields}{reason}, 'ioerror', 'the reason is a field');
is($open[0]{severity}, 'warning', 'warning');
$w->line(ips_line('WARNING VMS WARNING - no running VMs, 2 paused: a (ioerror), b (ioerror) | vms=0 paused=2 a_paused_ioerror=1 b_paused_ioerror=1'), 2026, 11, 1);
is(scalar $is->list, 2, 'the next monitor tick adds to them, no new issue');
is($is->find_open('guest-paused:tch-001:a')->{seen}, 2, 'seen counts');

$w->line(ips_line('OK VMS OK - 1 running VMs (rss 0.0 GiB) | vms=1 paused=0 a_vcpus=1'), 2026, 11, 1);
$w->line(ips_line('OK VMS OK - 1 running VMs (rss 0.0 GiB) | vms=1 a_vcpus=1'), 2026, 11, 1);
is(scalar $is->list, 2, 'a line that no longer names the guests resolves nothing, with or without the paused figure (the healer checks the node)');
$w->line(ips_line('UNREACHABLE x'), 2026, 11, 1);
is(scalar $is->list, 2, 'nor does an unreachable host');

done_testing;
