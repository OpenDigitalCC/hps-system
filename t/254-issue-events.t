#!/usr/bin/env perl
# The issue register's event lines (HPS::Issues event and remind; docs/LOGGING.md):
# open and resolve as event lines of kind issue, and a standing issue repeated
# every HPS::Event::REMIND seconds until it is resolved.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Event;
use HPS::Registry;
use HPS::Issues;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $now = 1_794_470_400;
my @log;
my $is = HPS::Issues->new(registry => $reg, now => sub { $now }, logger => sub { push @log, [@_] });

sub events { return map { HPS::Event::parse($_->[1]) // () } @log }

my ($w) = $is->open_issue(kind => 'zfs-vdev', key_fields => [qw(host pool vdev)], severity => 'warning',
    fields => { host => 'sch-001.lab.hps', pool => 's1', vdev => 'virtio-d3' });
my ($u) = $is->open_issue(kind => 'storage-path', key_fields => ['host'], severity => 'urgent', fields => { host => 'tch-001.lab.hps' });
is_deeply([ map { "$_->{pri} $_->{kind} $_->{state}" } events() ], [ 'warning issue open', 'urgent issue open' ], 'opening: a warning and an urgent event');
is_deeply([ map { $_->[0] } @log ], [ 'warning', 'err' ], 'syslog levels warning and err');
is((events())[0]{subject}, $w->{key}, 'the subject is the issue key');
like((events())[0]{text}, qr/\Ahps-issue: opened \Q$w->{id}\E /, 'the text keeps the old line');

#--- remind ---------------------------------------------------------------------------------
@log = ();
my %memo;
is($is->remind(\%memo), 2, 'remind: the first call logs every open issue');
is_deeply([ map { "$_->{pri} $_->{state} $_->{subject}" } events() ],
    [ "warning open $w->{key}", "urgent escalated $u->{key}" ], 'remind: a warning issue is open, an urgent one escalated');
@log = ();
$now += HPS::Event::REMIND - 1;
is($is->remind(\%memo), 0, 'remind: nothing before the period is up');
$now += 1;
is($is->remind(\%memo), 2, 'remind: both again at the period');
@log = ();
$is->update($w->{id}, sub { my $rec = shift; $rec->{state} = 'needs-human' });
$now += HPS::Event::REMIND;
$is->remind(\%memo);
is_deeply([ map { "$_->{pri} $_->{state}" } events() ], [ 'urgent needs-human', 'urgent escalated' ], 'remind: needs-human is urgent and says so');
@log = ();
$is->resolve($w->{id}, 'test');
is_deeply([ map { "$_->{pri} $_->{state} $_->{class}" } events() ], [ 'notice resolved clearing' ], 'resolve: a notice event of a clearing state');
@log = ();
$now += HPS::Event::REMIND;
is($is->remind(\%memo), 1, 'remind: a resolved issue is not repeated');
is((events())[0]{subject}, $u->{key}, '... the open one is');
@log = ();
$is->resolve($u->{id}, 'test');
$now += HPS::Event::REMIND;
is($is->remind(\%memo), 0, 'remind: nothing open, nothing logged');

#--- the whole chain: what hps-log attention says about it -------------------------------------
require HPS::Log;
my $ld = "$base/log";
make_path($ld);
my $n = $now;
my @lines;
my $t = sub { my @g = gmtime($_[0]); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, $g[3], @g[2, 1, 0]) };
my $sink = sub { my ($l, $m) = @_; push @lines, $t->($n) . " ips.lab $m" };
my $is2 = HPS::Issues->new(registry => $reg, now => sub { $n }, logger => $sink);
my ($o) = $is2->open_issue(kind => 'zfs-vdev', key_fields => ['host'], severity => 'warning', fields => { host => 'sch-009.lab.hps' });
$n += 600;
my %m2;
$is2->remind(\%m2);
open(my $fh, '>', "$ld/events.log") or die; print {$fh} map { "$_\n" } @lines; close $fh;
my $a = HPS::Log->new(log_dir => $ld, now => $n + 60)->attention;
is($a->{status}, 'attention', 'attention sees the open issue');
is($a->{problems}[0]{subject}, $o->{key}, 'attention names it');
is($a->{problems}[0]{lines}, 2, 'two lines of the run: the opening and the reminder');
$is2->resolve($o->{id}, 'test');
open($fh, '>', "$ld/events.log") or die; print {$fh} map { "$_\n" } @lines; close $fh;
is(HPS::Log->new(log_dir => $ld, now => $n + 60)->attention->{status}, 'clear', 'attention is clear once it is resolved');

done_testing;
