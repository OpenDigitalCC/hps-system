#!/usr/bin/env perl
# CS-3.6: the workload job kinds of HPS::Jobs: allowlist, command table, timeouts,
# and the runner (bin/hps-jobs) calling bin/hps-workload.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Jobs;

my @KINDS = qw(workload-create workload-start workload-stop workload-destroy workload-status);
my %have = map { $_ => 1 } HPS::Jobs::kinds();
ok($have{$_}, "$_ is a job kind") for @KINDS;

for my $ok (
    [ 'workload-create', 't0' ], [ 'workload-create', 't0', '--resume' ],
    [ 'workload-start', 't0' ], [ 'workload-start', 't0', '--vm', 't0-app' ],
    [ 'workload-stop', 't0' ], [ 'workload-stop', 't0', '--vm', 't0-app' ],
    [ 'workload-status', 't0' ], [ 'workload-status', 'odoo-test', '--vm', 'odoo-test-db' ],
    [ 'workload-destroy', 't0' ], [ 'workload-destroy', 't0', '--forget' ],
) {
    is(HPS::Jobs::validate(@$ok), undef, "allowed: @$ok");
}

for my $bad (
    [ 'workload-create' ], [ 'workload-create', 'T0' ], [ 'workload-create', '0t' ], [ 'workload-create', 't0', '--vm', 'x' ],
    [ 'workload-create', 't0', '--force' ], [ 'workload-create', 't0', '--resume', 'x' ], [ 'workload-create', 'a' x 33 ],
    [ 'workload-create', 't0;rm' ], [ 'workload-create', "t0\n" ], [ 'workload-create', '../t0' ],
    [ 'workload-start' ], [ 'workload-start', 't0', '--vm' ], [ 'workload-start', 't0', 'app' ], [ 'workload-start', 't0', '--resume' ],
    [ 'workload-start', 't0', '--vm', 'App' ], [ 'workload-start', 't0', '--vm', 'a;b' ], [ 'workload-start', 't0', '--dry-run' ],
    [ 'workload-stop', 't0', '--vm', 'x', 'y' ], [ 'workload-status', '' ],
    [ 'workload-destroy' ], [ 'workload-destroy', 't0', '--vm', 'x' ], [ 'workload-destroy', 't0', '--resume' ],
    [ 'workload-destroy', 'T0' ],
) {
    my $why = HPS::Jobs::validate(@$bad);
    ok(defined $why, 'refused: ' . join(' ', map { s/\n/\\n/gr } @$bad));
}
like(HPS::Jobs::validate('workload-destroy', 't0', 'x'), qr/^workload-destroy: the second argument can only be --forget/, 'the reason carries the kind');

is_deeply([ HPS::Jobs::command('workload-create', ['t0'], workload => 'hw') ], [qw(hw create t0)], 'create');
is_deeply([ HPS::Jobs::command('workload-create', [ 't0', '--resume' ], workload => 'hw') ], [qw(hw create t0 --resume)], 'create --resume');
is_deeply([ HPS::Jobs::command('workload-start', [ 't0', '--vm', 'a' ], workload => 'hw') ], [qw(hw start t0 --vm a)], 'start --vm');
is_deeply([ HPS::Jobs::command('workload-stop', ['t0'], workload => 'hw') ], [qw(hw stop t0)], 'stop');
is_deeply([ HPS::Jobs::command('workload-destroy', ['t0'], workload => 'hw') ], [qw(hw destroy t0)], 'destroy');
is_deeply([ HPS::Jobs::command('workload-status', ['t0'], workload => 'hw') ], [qw(hw status t0 --json)], 'status asks for JSON');
is((HPS::Jobs::command('workload-status', ['t0']))[0], 'hps-workload', 'default command name');

cmp_ok(HPS::Jobs::timeout_for('workload-create'), '>=', 1800, 'create may take minutes (image write)');
cmp_ok(HPS::Jobs::timeout_for($_), '>', 60, "$_ has more than the default timeout") for @KINDS;

# the runner: fixed argument lists, no shell
my $root = tempdir(CLEANUP => 1);
open(my $fh, '>', "$root/hps-workload") or die;
print {$fh} <<"SH";
#!/usr/bin/env bash
echo "workload \$*" >> "$root/calls.log"
echo "workload said: \$*"
exit \$(cat "$root/rc" 2>/dev/null || echo 0)
SH
close $fh;
chmod 0755, "$root/hps-workload";
my $j = HPS::Jobs->new(dir => "$root/jobs");
$j->ensure_dirs;
my $id1 = $j->submit('workload-create', 't0', '--resume');
my $id2 = $j->submit('workload-status', 't0');
my $id3 = $j->submit('workload-destroy', 't0');
local $ENV{HPS_WORKLOAD_CMD} = "$root/hps-workload";
my $log = `perl "$Bin/../bin/hps-jobs" --once --dir "$root/jobs" 2>&1`;
open($fh, '<', "$root/calls.log") or die;
my @calls = map { s/\n//r } <$fh>;
close $fh;
is_deeply([ sort @calls ], [ 'workload create t0 --resume', 'workload destroy t0', 'workload status t0 --json' ], 'the runner ran each job as an argument list');
is($j->result($id1)->{exit}, 0, 'result: exit 0');
is($j->result($id1)->{stdout}, "workload said: create t0 --resume\n", 'result: stdout');
open($fh, '>', "$root/rc") or die;
print {$fh} "3\n";
close $fh;
my $id4 = $j->submit('workload-start', 't0', '--vm', 'a');
$log = `perl "$Bin/../bin/hps-jobs" --once --dir "$root/jobs" 2>&1`;
is($j->result($id4)->{exit}, 3, 'a refusal (3) is the job result exit');
ok(-f "$root/jobs/failed/$id4.result.json", 'a failed job lands in failed/');

done_testing;
