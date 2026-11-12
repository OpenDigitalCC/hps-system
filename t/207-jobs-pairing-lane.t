#!/usr/bin/env perl
# The pairing lane of the root job runner (incident 2026-11-12): pairing-* jobs
# run beside the work lane, so an approval never waits behind a long
# storage-up; each lane stays one job at a time, oldest first.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Jobs;

my $RUNNER = "$Bin/../bin/hps-jobs";

sub spit  { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; chmod 0755, $_[0] if $_[2] }
sub slurp { open(my $fh, '<:raw', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }

# --- lane_of
is(HPS::Jobs::lane_of($_), 'pairing', "$_ runs in the pairing lane")
    for qw(pairing-list pairing-approve pairing-window-open pairing-window-close);
is(HPS::Jobs::lane_of($_), 'work', "$_ runs in the work lane")
    for qw(storage-up net-up workload-start pins-prune);
is(HPS::Jobs::lane_of('pairing-bogus'), 'work', 'an unknown pairing- name is not a pairing kind');
is(HPS::Jobs::lane_of(undef), 'work', 'an unreadable kind goes to the work lane');

# A world whose storage-up blocks until the test releases it (no timing).
my $root = tempdir(CLEANUP => 1);
mkdir "$root/bin";
spit("$root/bin/ctrl-exec-dispatcher", <<"SH", 1);
#!/usr/bin/env bash
echo "ced \$*" >> "$root/calls.log"
[[ "\$1" == list-requests ]] && echo "ID HOSTNAME SOURCE"
exit 0
SH
spit("$root/bin/hps-storage", <<"SH", 1);
#!/usr/bin/env bash
echo "storage \$* begin" >> "$root/calls.log"
n=0
while [[ ! -e "$root/release" && \$n -lt 300 ]]; do sleep 0.1; n=\$((n+1)); done
echo "storage \$* end" >> "$root/calls.log"
exit 0
SH
# A clock that ticks per submit: the queue orders by the epoch in the name.
my $clock = time - 1000;
my $j = HPS::Jobs->new(dir => "$root/jobs", now => sub { $clock++ });
$j->ensure_dirs;

# --- peek_kind reads the kind without claiming
{
    my $id = $j->submit('storage-up', '525400000001');
    my ($name) = $j->pending;
    is($j->peek_kind($name), 'storage-up', 'peek_kind names the kind');
    ok(-f $j->sub_dir('new') . "/$name", 'and leaves the job in new/');
    is($j->peek_kind('1-1-00000000.json'), undef, 'a missing file has no kind');

    my $up2  = $j->submit('storage-up', '525400000002');
    my $list = $j->submit('pairing-list');
    my $appr = $j->submit('pairing-approve', 'ab12');

    local $ENV{PATH}                 = "$root/bin:$ENV{PATH}";
    local $ENV{HPS_STORAGE_CMD}      = "$root/bin/hps-storage";
    local $ENV{CTRL_EXEC_DISPATCHER} = "$root/bin/ctrl-exec-dispatcher";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open(STDOUT, '>', "$root/runner.log") or exit 126;
        open(STDERR, '>&', \*STDOUT) or exit 126;
        exec 'perl', $RUNNER, '--interval', '0.05', '--dir', "$root/jobs";
        exit 127;
    }

    my $rl = $j->wait($list, 10);
    my $ra = $j->wait($appr, 10);
    ok($rl && $rl->{exit} == 0, 'pairing-list finished while storage-up still runs');
    ok($ra && $ra->{exit} == 0, 'pairing-approve finished while storage-up still runs');
    is($j->result($id), undef, 'storage-up has not finished yet');
    like(slurp("$root/calls.log"), qr/storage 525400000001 up --wait 120 begin/, 'storage-up was running');
    unlike(slurp("$root/calls.log"), qr/525400000002/, 'the second storage-up waits for the first (one work job at a time)');

    spit("$root/release", '');
    my $r1 = $j->wait($id, 30);
    my $r2 = $j->wait($up2, 30);
    ok($r1 && $r1->{exit} == 0, 'the first storage-up finished once released');
    ok($r2 && $r2->{exit} == 0, 'then the second');
    my @storage = grep { /^storage / } split /\n/, slurp("$root/calls.log");
    is_deeply(\@storage, [
        'storage 525400000001 up --wait 120 begin', 'storage 525400000001 up --wait 120 end',
        'storage 525400000002 up --wait 120 begin', 'storage 525400000002 up --wait 120 end',
    ], 'the work lane ran its jobs one after the other, oldest first');

    kill 'TERM', $pid;
    waitpid($pid, 0);
    my $log = slurp("$root/runner.log");
    like($log, qr/start lane=pairing kind=pairing-list/, 'the runner logs the lane of a pairing job');
    like($log, qr/start lane=work kind=storage-up/, 'and of a work job');
    like($log, qr/stopped/, 'it stops on TERM');
}

done_testing;
