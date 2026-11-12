#!/usr/bin/env perl
# bin/hps-jobs against a fake dispatcher and a fake hps-storage.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Jobs;

my $RUNNER = "$Bin/../bin/hps-jobs";

sub slurp { open(my $fh, '<:raw', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }
sub spit  { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; chmod 0755, $_[0] if $_[2] }
sub nfiles { opendir(my $dh, $_[0]) or return 0; return scalar grep { !/^\./ } readdir $dh }

# A scratch world: bin/ with the fakes, a log of every call, a queue.
sub world {
    my $root = tempdir(CLEANUP => 1);
    mkdir "$root/bin";
    spit("$root/bin/ctrl-exec-dispatcher", <<"SH", 1);
#!/usr/bin/env bash
echo "ced \$*" >> "$root/calls.log"
if [[ "\$1" == --help ]]; then
  [[ -f "$root/no-replace" ]] && echo "approve <reqid>" || echo "approve <reqid> [--replace]"
  exit 0
fi
[[ -f "$root/ced.out" ]] && cat "$root/ced.out"
[[ -f "$root/ced.err" ]] && cat "$root/ced.err" >&2
[[ -f "$root/ced.big" ]] && head -c 200000 /dev/zero | tr '\\0' 'x'
exit \$(cat "$root/ced.rc" 2>/dev/null || echo 0)
SH
    spit("$root/bin/hps-storage", <<"SH", 1);
#!/usr/bin/env bash
echo "storage \$*" >> "$root/calls.log"
echo "storage said: \$*"
exit \$(cat "$root/storage.rc" 2>/dev/null || echo 0)
SH
    my $clock = time - 1000;
    my $j = HPS::Jobs->new(dir => "$root/jobs", now => sub { $clock++ });
    $j->ensure_dirs;
    return ($root, $j);
}

# run_once($root, $j): the runner over whatever is queued; returns its log.
sub run_once {
    my ($root, $j, %env) = @_;
    local $ENV{PATH}                 = "$root/bin:$ENV{PATH}";
    local $ENV{HPS_STORAGE_CMD}      = "$root/bin/hps-storage";
    local $ENV{CTRL_EXEC_DISPATCHER} = delete $env{dispatcher} if exists $env{dispatcher};
    delete local $ENV{CTRL_EXEC_DISPATCHER} unless exists $ENV{CTRL_EXEC_DISPATCHER};
    my $out = `perl "$RUNNER" --once --dir "$root/jobs" 2>&1`;
    return $out;
}

sub calls { return split /\n/, slurp("$_[0]/calls.log") }

# --- every kind runs its fixed command (dispatcher found on PATH)
{
    my ($root, $j) = world();
    my %id = (
        open   => $j->submit('pairing-window-open'),
        open90 => $j->submit('pairing-window-open', 90),
        close  => $j->submit('pairing-window-close'),
        list   => $j->submit('pairing-list'),
        appr   => $j->submit('pairing-approve', 'ab12'),
        apprr  => $j->submit('pairing-approve', 'ab12', '--replace'),
        up     => $j->submit('storage-up', '525400000001'),
        down   => $j->submit('storage-down', '525400000001'),
        trim   => $j->submit('storage-trim-check', '525400000001'),
        status => $j->submit('storage-status', '525400000001'),
    );
    my $log = run_once($root, $j);
    # The two lanes run side by side, so only the order within a lane is fixed.
    is_deeply([ grep { /^ced / && !/--help/ } calls($root) ], [
        'ced pairing-mode start --timeout 300', 'ced pairing-mode start --timeout 90', 'ced pairing-mode stop',
        'ced list-requests', 'ced approve ab12', 'ced approve ab12 --replace',
    ], 'each pairing kind ran its command, oldest job first');
    is_deeply([ grep { /^storage / } calls($root) ], [
        'storage 525400000001 up --wait 120', 'storage 525400000001 down',
        'storage 525400000001 trim-check', 'storage 525400000001 status',
    ], 'each storage kind ran its command, oldest job first');
    is(nfiles($j->sub_dir('done')), 10, 'ten results in done/');
    is(nfiles($j->sub_dir('failed')), 0, 'none in failed/');
    is(nfiles($j->sub_dir('new')) + nfiles($j->sub_dir('run')), 0, 'new/ and run/ are empty');
    is($j->result($id{up})->{stdout}, "storage said: 525400000001 up --wait 120\n", 'stdout is in the result');
    like($log, qr/job $id{up}: start lane=work kind=storage-up args=\[525400000001\] requested_by=\d+\//, 'the start of a job is logged with its id, kind and requester');
    like($log, qr/job $id{up}: end lane=work kind=storage-up exit=0 duration=[\d.]+s result=done/, 'the end is logged with exit and duration');
}

# --- --replace follows what the dispatcher supports
{
    my ($root, $j) = world();
    spit("$root/no-replace", '');
    $j->submit('pairing-approve', 'ab12', '--replace');
    my $log = run_once($root, $j);
    is_deeply([ grep { !/--help/ } calls($root) ], ['ced approve ab12'], 'an old dispatcher gets a plain approve');
    like($log, qr/no approve --replace/, 'and the runner says so');
}

# --- exit codes route the result; output is carried
{
    my ($root, $j) = world();
    spit("$root/ced.rc", "3\n");
    spit("$root/ced.out", "approving...\n");
    spit("$root/ced.err", "refused: no such request\n");
    my $id = $j->submit('pairing-approve', 'ab12');
    run_once($root, $j);
    my $r = $j->result($id);
    is($r->{exit}, 3, 'the exit of the command');
    is($r->{stdout}, "approving...\n", 'stdout');
    is($r->{stderr}, "refused: no such request\n", 'stderr');
    ok(-f $j->sub_dir('failed') . "/$id.result.json", 'it is in failed/');
    ok(!-f $j->sub_dir('done') . "/$id.result.json", 'not in done/');
}

# --- output is capped at 64 KiB
{
    my ($root, $j) = world();
    spit("$root/ced.big", '');
    my $id = $j->submit('pairing-list');
    run_once($root, $j);
    my $r = $j->result($id);
    is(length $r->{stdout}, 65536, 'stdout cut at 64 KiB');
    ok($r->{stdout_truncated}, 'and flagged');
}

# --- a missing command is exit 127, not a crash of the runner
{
    my ($root, $j) = world();
    unlink "$root/bin/hps-storage";
    my $id  = $j->submit('storage-status', '525400000001');
    my $id2 = $j->submit('pairing-list');
    run_once($root, $j);
    is($j->result($id)->{exit}, 127, 'exit 127 for a missing command');
    like($j->result($id)->{stderr}, qr/cannot run/, 'with the reason');
    is($j->result($id2)->{exit}, 0, 'the next job still ran');
}

# --- the runner validates again: hand-written files are not trusted
{
    my ($root, $j) = world();
    my $new = $j->sub_dir('new');
    my $w = sub { my ($n, $doc) = @_; spit("$new/1800000000-1-$n.json", ref $doc ? encode_json($doc) : $doc) };
    $w->('aaaaaaaa', { id => 'aaaaaaaa', kind => 'format-disk', args => ['/dev/sda'] });
    $w->('bbbbbbbb', { id => 'bbbbbbbb', kind => 'storage-up', args => ['52:54:00:00:00:01'] });
    $w->('cccccccc', { id => 'cccccccc', kind => 'pairing-approve', args => ['AB12'] });
    $w->('dddddddd', { id => 'dddddddd', kind => 'pairing-window-open', args => [601] });
    $w->('eeeeeeee', { id => 'eeeeeeee', kind => 'pairing-approve', args => ['ab;rm'] });
    $w->('ffffffff', '{broken');
    $w->('11111111', { id => '22222222', kind => 'pairing-list', args => [] });
    $w->('33333333', { id => '33333333', kind => 'pairing-list', args => 'not-a-list' });
    spit("$new/readme.txt", 'x');
    my $log = run_once($root, $j);
    is(scalar(calls($root)), 0, 'no command ran for any of them');
    is(nfiles($j->sub_dir('failed')), 8, 'eight results in failed/');
    my $r = $j->result('aaaaaaaa');
    is($r->{exit}, 2, 'refused jobs exit 2');
    like($r->{stderr}, qr/unknown kind 'format-disk'/, 'unknown kind says so');
    like($j->result('bbbbbbbb')->{stderr}, qr/12 lowercase hex/, 'MAC with colons refused');
    like($j->result('dddddddd')->{stderr}, qr/seconds must be 1-600/, 'seconds out of range refused');
    like($j->result('ffffffff')->{stderr}, qr/not a JSON object/, 'broken JSON refused');
    like($j->result('11111111')->{stderr}, qr/does not match the file name/, 'id mismatch refused');
    ok(-f "$new/readme.txt", 'a file that is not a job is left alone');
    like($log, qr/job aaaaaaaa: refused/, 'the refusal is logged');
}

# --- a stale run/ entry is failed at startup and not re-run
{
    my ($root, $j) = world();
    spit($j->sub_dir('run') . '/1800000000-1-abababab.json', encode_json({ id => 'abababab', kind => 'pairing-window-open', args => [] }));
    my $log = run_once($root, $j);
    my $r = $j->result('abababab');
    is($r->{exit}, 125, 'stale job: exit 125');
    like($r->{stderr}, qr/stale: found in run\//, 'with a note');
    is($r->{kind}, 'pairing-window-open', 'the kind is kept in the result');
    ok(-f $j->sub_dir('failed') . '/abababab.result.json', 'it is in failed/');
    is(nfiles($j->sub_dir('run')), 0, 'run/ is empty');
    is(scalar(calls($root)), 0, 'the stale job did not run');
    like($log, qr/job abababab: stale run\/ entry at startup/, 'logged');
}

# --- the runner makes the directories itself
{
    my $root = tempdir(CLEANUP => 1);
    mkdir "$root/bin";
    my $out = `perl "$RUNNER" --once --dir "$root/q/jobs" 2>&1`;
    is($? >> 8, 0, 'exit 0 on an empty queue');
    ok(-d "$root/q/jobs/$_", "$_/ created") for qw(new run done failed);
    like($out, qr/started; queue /, 'start is logged');
}

# --- usage
{
    my $out = `perl "$RUNNER" --bogus 2>&1`;
    is($? >> 8, 2, 'a bad option is exit 2');
    like($out, qr/Usage: hps-jobs/, 'with the usage text');
}

done_testing;
