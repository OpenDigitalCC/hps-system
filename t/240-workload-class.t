#!/usr/bin/env perl
# The workload class (plans/upgradability.md U1): the definition key,
# its default, the record, list and status, and set-class.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use DrainFixture;
use HPS::Workload::List;

sub slurp { my ($p) = @_; open(my $h, '<', $p) or die "$p: $!"; local $/; return scalar <$h> }
sub refusal { my ($def) = @_; return eval { HPS::Workload::validate($def); 1 } ? undef : $@ }

#--- the definition key
{
    is(HPS::Workload::validate(DrainFixture::wdef('a', undef))->{class}, 3, 'no class key: class 3');
    for my $p (1 .. 4) {
        is(HPS::Workload::validate(DrainFixture::wdef('a', $p))->{class}, $p, "class $p is accepted");
    }
    my %bad = (0 => 0, 5 => 5, 'minus one' => -1, 'a fraction' => 3.5, 'a string' => '3', 'a word' => 'high',
        'true' => JSON::PP::true, 'a list' => [3], 'an object' => { class => 3 });
    for my $what (sort keys %bad) {
        my $e = refusal(DrainFixture::wdef('a', $bad{$what}));
        is($e && $e->kind, 'refused', "class $what is refused");
        like($e && $e->message, qr/^workload: class must be a whole number 1 to 4 \(1 core, 2 customer-facing, 3 ordinary, 4 batch and test; default 3\)/,
            "class $what: the refusal names the field and the classes");
    }
    my $null = DrainFixture::wdef('a', 1);
    $null->{class} = undef;
    is((refusal($null) // die)->kind, 'refused', 'class null is refused');
    # The per-VM priority (start order, 1-5) is another field and keeps its range.
    my $d = DrainFixture::wdef('a', 4);
    $d->{vms}[0]{priority} = 5;
    my $ok = HPS::Workload::validate($d);
    is_deeply([ $ok->{class}, $ok->{vms}[0]{priority} ], [ 4, 5 ], 'workload class 4 with a VM start priority 5: two fields');
}

#--- define refuses a bad class and stores a good one
{
    my ($f, $wl) = DrainFixture::setup();
    my $js = JSON::PP->new->canonical;
    my $e = eval { $wl->define('a', $js->encode(DrainFixture::wdef('a', 7))); 1 } ? undef : $@;
    is($e && $e->kind, 'refused', 'define: class 7 refused');
    ok(!-e $wl->definition_path('a'), 'and nothing is written');
    $wl->define('a', $js->encode(DrainFixture::wdef('a', 2)));
    is(decode_json(slurp($wl->definition_path('a')))->{class}, 2, 'define: class 2 stored in the definition');
}

#--- the record, list and status
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'core', 1);
    DrainFixture::make($f, $wl, 'plain', undef);
    is(DrainFixture::rec($f, 'core')->{class}, 1, 'create records the class');
    is(DrainFixture::rec($f, 'plain')->{class}, 3, 'create records the default as 3');

    # A record made before the key existed: reads as 3 and is not rewritten by a read.
    DrainFixture::set_rec($f, 'plain', sub { delete $_[0]{class} });
    my $file = "$f->{base}/clusters/lab/cluster.db/workload_plain.json";
    my $before = slurp($file);
    my $rows = HPS::Workload::List::list($wl);
    is_deeply({ map { $_->{name} => $_->{class} } @$rows }, { core => 1, plain => 3 }, 'list: class per workload, 3 for a record without the key');
    my $text = HPS::Workload::List::render_list($rows);
    like($text, qr/^NAME\s+PROJECT\s+STATE\s+CLASS\s+HOST\s+VMS\s+ADDRESS\s+CREATED$/m, 'list: a CLASS column after STATE');
    like($text, qr/^core\s+lab\s+running\s+1\s+sch-001\s/m, 'list: the class of core');
    like($text, qr/^plain\s+lab\s+running\s+3\s+sch-001\s/m, 'list: the default of plain');
    my $st = $wl->run('status', 'plain');
    is($st->{class}, 3, 'status: class 3 for a record without the key');
    is($wl->run('status', 'core')->{class}, 1, 'status: the recorded class');
    is(slurp($file), $before, 'list and status did not rewrite the record');
    ok(!exists DrainFixture::rec($f, 'plain')->{class}, 'the record still has no class key');

    DrainFixture::set_rec($f, 'plain', sub { $_[0]{class} = 9 });
    is(HPS::Workload::class_of(DrainFixture::rec($f, 'plain')), undef, 'a recorded class that is not 1 to 4 is not read as any class');
    like(HPS::Workload::List::render_list(HPS::Workload::List::list($wl)), qr/^plain\s+lab\s+running\s+\?\s/m, 'list shows it as ?');
}

#--- set-class
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'job', undef);
    DrainFixture::reset_calls($f);
    my $r = $wl->set_class('job', 4, dry_run => 1);
    is_deeply([ @$r{qw(class was dry_run)} ], [ 4, 3, 1 ], 'dry run: says 3 -> 4');
    is(DrainFixture::rec($f, 'job')->{class}, 3, 'dry run: record unchanged');
    ok(!exists decode_json(slurp($wl->definition_path('job')))->{class}, 'dry run: definition unchanged');

    $r = $wl->set_class('job', 4);
    is_deeply([ @$r{qw(class was definition record)} ], [ 4, 3, 1, 1 ], 'set-class 4: definition and record');
    is(DrainFixture::rec($f, 'job')->{class}, 4, 'the record has class 4');
    is(decode_json(slurp($wl->definition_path('job')))->{class}, 4, 'the definition has class 4');
    is($wl->load('job')->{class}, 4, 'and still loads');
    is(scalar(() = $f->{ce}->calls), 0, 'no node call');
    is_deeply([ grep { /set-class/ } @{ $f->{log} } ], ['notice set-class job: class 3 -> 4 by tester (definition, record)'], 'logged as one event');
    is(DrainFixture::state($f, 'job'), 'running', 'the guest is untouched');

    for my $bad (0, 5, 'x', '', '03', '2.0') {
        my $e = eval { $wl->set_class('job', $bad); 1 } ? undef : $@;
        is($e && $e->kind, 'usage', "set-class '$bad': usage");
    }
    my $e = eval { $wl->set_class('ghost', 2); 1 } ? undef : $@;
    is($e && $e->kind, 'notfound', 'no definition and no record: not found');

    # a definition that was never created: the definition alone
    StorageFixture::write_def($f, DrainFixture::wdef('later', 2));
    $r = $wl->set_class('later', 1);
    is_deeply([ @$r{qw(class was definition record)} ], [ 1, 2, 1, 0 ], 'defined, not created: the definition alone');
    is(decode_json(slurp($wl->definition_path('later')))->{class}, 1, 'written');
    ok(!defined DrainFixture::rec($f, 'later'), 'no record is made');
    $wl->run('create', 'later');
    is(DrainFixture::rec($f, 'later')->{class}, 1, 'a later create records it');

    # a record whose definition is gone: the record alone
    unlink $wl->definition_path('job');
    $r = $wl->set_class('job', 2);
    is_deeply([ @$r{qw(class was definition record)} ], [ 2, 4, 0, 1 ], 'definition gone: the record alone');
    is(DrainFixture::rec($f, 'job')->{class}, 2, 'the record has class 2');
}

#--- the CLI
{
    my ($f, $wl) = DrainFixture::setup();
    DrainFixture::make($f, $wl, 'web', 2);
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    local $ENV{SUDO_USER}              = 'tester';
    my $run = sub {
        my $q = join ' ', map {"'$_'"} ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_);
        my $out = qx($q 2>&1);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $run->('list');
    like($out, qr/^web\s+lab\s+running\s+2\s/m, 'cli list: the CLASS column');
    ($rc, $out) = $run->('list', '--json');
    is(decode_json($out)->{workloads}[0]{class}, 2, 'cli list --json: class');
    ($rc, $out) = $run->('set-class', 'web', '1');
    is($rc, 0, 'cli set-class: exit 0');
    like($out, qr/set-class ok: workload web class 2 -> 1 in the definition and the record/, 'says what changed');
    like($out, qr/hps-workload: set-class web: class 2 -> 1 by tester/, 'and logs the event');
    is(DrainFixture::rec($f, 'web')->{class}, 1, 'recorded');
    ($rc, $out) = $run->('set-class', 'web', '4', '--json', '--dry-run');
    is($rc, 0, 'cli set-class --dry-run --json');
    is(DrainFixture::rec($f, 'web')->{class}, 1, 'dry run changes nothing');
    ($rc, $out) = $run->('set-class', 'web', '9');
    is($rc, 2, 'cli set-class 9: usage (2)');
    like($out, qr/class must be a whole number 1 to 4/, 'names the range');
    ($rc, $out) = $run->('set-class', 'web');
    is($rc, 2, 'cli set-class without a class: usage');
    ($rc, $out) = $run->('set-class', 'ghost', '2');
    is($rc, 4, 'cli set-class of an unknown workload: not found (4)');
    my $bad = JSON::PP->new->encode(DrainFixture::wdef('nope', 0));
    open(my $p, '|-', "'$^X' '-I$Bin/../lib/perl' '$Bin/../bin/hps-workload' define nope > '$f->{base}/define.out' 2>&1") or die;
    print {$p} $bad;
    close $p;
    is($? >> 8, 3, 'cli define with class 0: refused (3)');
    like(slurp("$f->{base}/define.out"), qr/workload: class must be a whole number 1 to 4/, 'with the reason');
}

done_testing;
