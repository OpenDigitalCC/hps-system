#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Jobs;

sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; return $t }
sub spit  { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub files { opendir(my $dh, $_[0]) or return (); return sort grep { !/^\./ } readdir $dh }
sub nfiles { return scalar(my @f = files(@_)) }

sub fresh {
    my %o = @_;
    my $dir = tempdir(CLEANUP => 1) . '/jobs';
    my $j = HPS::Jobs->new(dir => $dir, now => sub { 1_800_000_000 }, %o);
    $j->ensure_dirs;
    return $j;
}

# --- the queue directories
{
    my $j = fresh();
    for my $d (qw(new run done failed)) {
        my $p = $j->sub_dir($d);
        ok(-d $p, "$d/ exists");
        is(sprintf('%04o', (stat $p)[2] & 07777), '2775', "$d/ is setgid and group-writable");
    }
    ok($j->ensure_dirs, 'ensure_dirs is idempotent');
}

# --- submit: the file shape
{
    my $j  = fresh();
    my $id = $j->submit('pairing-approve', 'abc123', '--replace');
    like($id, qr/^[0-9a-f]{8}$/, 'the id is 8 hex digits');
    my @f = files($j->sub_dir('new'));
    is(scalar @f, 1, 'one job file in new/');
    like($f[0], qr/^1800000000-$$-$id\.json$/, 'named <epoch>-<pid>-<id>.json');
    my $job = decode_json(slurp($j->sub_dir('new') . "/$f[0]"));
    is($job->{id}, $id, 'id');
    is($job->{kind}, 'pairing-approve', 'kind');
    is_deeply($job->{args}, [ 'abc123', '--replace' ], 'args');
    like($job->{requested_by}, qr{^\d+/\S+$}, 'requested_by is uid/program');
    is($job->{requested_at}, '2027-01-15T08:00:00Z', 'requested_at is the UTC time');
    is(sprintf('%04o', (stat $j->sub_dir('new') . "/$f[0]")[2] & 07777), '0664', 'the file is group-writable');
    is(scalar(grep { /^\.tmp/ } do { opendir(my $dh, $j->sub_dir('new')); readdir $dh }), 0, 'no temp file is left');
}

# --- the allowlist
{
    my $j = fresh();
    for my $ok (
        [ 'pairing-window-open' ], [ 'pairing-window-open', 1 ], [ 'pairing-window-open', 600 ],
        [ 'pairing-window-close' ], [ 'pairing-list' ],
        [ 'pairing-approve', 'deadbeef' ], [ 'pairing-approve', 'deadbeef', '--replace' ],
        [ 'storage-up', '525400000001' ], [ 'storage-down', '525400000001' ],
        [ 'storage-trim-check', '525400000001' ], [ 'storage-status', '525400000001' ],
      ) {
        is(HPS::Jobs::validate(@$ok), undef, "allowed: @$ok");
    }
    for my $bad (
        [ 'rm' ], [ '' ], [ 'pairing-window-open', 0 ], [ 'pairing-window-open', 601 ], [ 'pairing-window-open', 'x' ],
        [ 'pairing-window-open', 1, 2 ], [ 'pairing-window-close', 'now' ], [ 'pairing-list', 'x' ],
        [ 'pairing-approve' ], [ 'pairing-approve', 'DEADBEEF' ], [ 'pairing-approve', 'a;b' ],
        [ 'pairing-approve', 'ab', '--force' ], [ 'pairing-approve', 'a' x 65 ],
        [ 'storage-up' ], [ 'storage-up', '52:54:00:00:00:01' ], [ 'storage-up', '52540000000' ],
        [ 'storage-up', '52540000000G' ], [ 'storage-up', '525400000001', 'x' ], [ 'storage-status', "525400000001\n" ],
      ) {
        my $why = HPS::Jobs::validate(@$bad);
        ok(defined $why, "refused: " . join(' ', map { length $_ > 20 ? substr($_, 0, 20) . '...' : $_ } @$bad));
    }
    eval { $j->submit('nonesuch') };
    like($@, qr/unknown kind 'nonesuch'/, 'submit refuses an unknown kind');
    eval { $j->submit('storage-up', 'bad') };
    like($@, qr/storage-up: needs exactly <mac>/, 'submit refuses a bad argument');
    is(nfiles($j->sub_dir('new')), 0, 'nothing was queued');
    is_deeply([ HPS::Jobs::kinds() ], [ sort qw(pairing-window-open pairing-window-close pairing-list pairing-approve storage-up storage-down storage-trim-check storage-status workload-create workload-start workload-stop workload-destroy workload-status) ], 'the kind list is the allowlist');
}

# --- the command table: argument lists, never a shell string
{
    is_deeply([ HPS::Jobs::command('pairing-window-open', [], dispatcher => 'ced') ], [qw(ced pairing-mode start --timeout 300)], 'window open default');
    is_deeply([ HPS::Jobs::command('pairing-window-open', [90], dispatcher => 'ced') ], [qw(ced pairing-mode start --timeout 90)], 'window open 90');
    is_deeply([ HPS::Jobs::command('pairing-window-close', [], dispatcher => 'ced') ], [qw(ced pairing-mode stop)], 'window close');
    is_deeply([ HPS::Jobs::command('pairing-list', [], dispatcher => 'ced') ], [qw(ced list-requests)], 'list');
    is_deeply([ HPS::Jobs::command('pairing-approve', [ 'ab', '--replace' ], dispatcher => 'ced') ], [qw(ced approve ab --replace)], 'approve');
    is_deeply([ HPS::Jobs::command('storage-up', ['525400000001'], storage => 'hs') ], [ 'hs', '525400000001', 'up', '--wait', 120 ], 'storage-up waits 120');
    is_deeply([ HPS::Jobs::command('storage-down', ['525400000001'], storage => 'hs') ], [qw(hs 525400000001 down)], 'storage-down');
    is_deeply([ HPS::Jobs::command('storage-trim-check', ['525400000001'], storage => 'hs') ], [qw(hs 525400000001 trim-check)], 'trim-check');
    is_deeply([ HPS::Jobs::command('storage-status', ['525400000001'], storage => 'hs') ], [qw(hs 525400000001 status)], 'status');
    eval { HPS::Jobs::command('rm', []) };
    like($@, qr/no command for kind/, 'no command for an unknown kind');
}

# --- claim, finish, result, wait: the round trip
{
    my $j  = fresh();
    my $id = $j->submit('pairing-list');
    my @p  = $j->pending;
    is(scalar @p, 1, 'pending sees the job');
    my ($job, $problem) = $j->claim($p[0]);
    is($problem, undef, 'claimed without a problem');
    is($job->{kind}, 'pairing-list', 'claimed job has its kind');
    is(nfiles($j->sub_dir('new')), 0, 'the job left new/');
    is(nfiles($j->sub_dir('run')), 1, 'the job is in run/');
    is($j->result($id), undef, 'no result while it runs');
    is($j->wait($id, 0), undef, 'wait times out with undef');
    is($j->finish($job, exit => 0, stdout => "table\n", stderr => '', duration => '0.2'), 'done', 'exit 0 goes to done/');
    is(nfiles($j->sub_dir('run')), 0, 'run/ is empty again');
    ok(-f $j->sub_dir('done') . "/$id.result.json", 'result file is <id>.result.json');
    my $r = $j->result($id);
    is($r->{exit}, 0, 'result exit');
    is($r->{stdout}, "table\n", 'result stdout');
    is($r->{kind}, 'pairing-list', 'result kind');
    is($r->{finished_at}, '2027-01-15T08:00:00Z', 'finished_at');
    is_deeply($j->wait($id, 1), $r, 'wait returns the result');

    my $id2 = $j->submit('storage-up', '525400000001');
    my ($job2) = $j->claim(($j->pending)[0]);
    is($j->finish($job2, exit => 3, stdout => '', stderr => "no key\n"), 'failed', 'a non-zero exit goes to failed/');
    is($j->result($id2)->{stderr}, "no key\n", 'failed result keeps stderr');
    ok(!-e $j->sub_dir('done') . "/$id2.result.json", 'not in done/');
}

# --- result capping
{
    my $j = fresh(cap => 100);
    my $id = $j->submit('pairing-list');
    my ($job) = $j->claim(($j->pending)[0]);
    $j->finish($job, exit => 0, stdout => 'x' x 250, stderr => 'e' x 50);
    my $r = $j->result($id);
    is(length $r->{stdout}, 100, 'stdout is cut at the cap');
    ok($r->{stdout_truncated}, 'and flagged');
    is(length $r->{stderr}, 50, 'stderr under the cap is whole');
    ok(!$r->{stderr_truncated}, 'and not flagged');
    is($HPS::Jobs::OUTPUT_CAP, 65536, 'the default cap is 64 KiB');
}

# --- claim refuses bad files, still giving an id for the result
{
    my $j = fresh();
    my $new = $j->sub_dir('new');
    spit("$new/1800000000-1-aaaaaaaa.json", '{not json');
    spit("$new/1800000000-1-bbbbbbbb.json", encode_json({ id => 'cccccccc', kind => 'pairing-list', args => [] }));
    spit("$new/1800000000-1-dddddddd.json", encode_json({ id => 'dddddddd', kind => 'format-disk', args => [] }));
    spit("$new/1800000000-1-eeeeeeee.json", encode_json({ id => 'eeeeeeee', kind => 'storage-up', args => ['x'] }));
    spit("$new/notes.txt", 'x');
    spit("$new/.tmp-1800000000-1-ffffffff.json", '{}');
    is_deeply([ $j->pending ], [ map {"1800000000-1-$_.json"} qw(aaaaaaaa bbbbbbbb dddddddd eeeeeeee) ], 'pending lists only well-named files, in order');
    my %why = map { my ($job, $p) = $j->claim($_); ($job->{id} => $p) } $j->pending;
    like($why{aaaaaaaa}, qr/not a JSON object/, 'broken JSON');
    like($why{bbbbbbbb}, qr/does not match the file name/, 'id differs from the file name');
    like($why{dddddddd}, qr/unknown kind 'format-disk'/, 'unknown kind');
    like($why{eeeeeeee}, qr/needs exactly <mac>/, 'bad argument');
}

# --- stale run/ and pruning
{
    my $j = fresh();
    spit($j->sub_dir('run') . '/1800000000-1-aaaaaaaa.json', '{}');
    spit($j->sub_dir('run') . '/ignored.txt', '');
    is_deeply([ $j->stale_run ], ['1800000000-1-aaaaaaaa.json'], 'stale_run lists run/ job files');
    spit($j->sub_dir('done') . '/old.result.json', '{}');
    utime(time - 10 * 86400, time - 10 * 86400, $j->sub_dir('done') . '/old.result.json');
    spit($j->sub_dir('failed') . '/new.result.json', '{}');
    is($j->prune(7), 1, 'prune drops the old result only');
    ok(-f $j->sub_dir('failed') . '/new.result.json', 'a recent result stays');
}

# --- ids are checked before they touch a path
{
    my $j = fresh();
    eval { $j->result('../etc/passwd') };
    like($@, qr/Invalid job id/, 'result refuses a path-like id');
}

# --- submit with no queue
{
    my $j = HPS::Jobs->new(dir => tempdir(CLEANUP => 1) . '/nowhere');
    eval { $j->submit('pairing-list') };
    like($@, qr/Job queue not available/, 'submit says so when new/ is missing');
}

done_testing;
