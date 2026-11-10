#!/usr/bin/env perl
# CS-2.5: HPS::Storage zvol and export operations, the read-only status, and the
# trim verdict capture (stdout verdict, never a stderr trace line).
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Find;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $mac = $StorageFixture::MAC;
my $DS  = 'lab/enc/t0';
my $IQN = 'iqn.2026-11.example.lab:t0';
my $INI = 'iqn.2026-11.example.lab:ips';

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub fresh { my %o = @_; my $f = StorageFixture::setup(%o); $f->{st} = $f->{mk}->(); return $f }
sub nexp { my @e = exports(@_); return scalar @e }
sub scripts { return map { $_->{script} } @{ $_[0] } }
sub exports { my $f = shift; return $f->{reg}->host_exists($mac, 'storage_exports') ? @{ $f->{reg}->host_get_json($mac, 'storage_exports') } : () }
sub approve_zvol {
    my ($f, %x) = @_;
    return $f->{ap}->issue({ action => 'zvol-destroy', mac => $mac, pool => $DS, issued_by => 'tester', %x });
}
sub registry_text {
    my $base = shift;
    my $all = '';
    find({ no_chdir => 1, wanted => sub {
        return unless -f $_ && $_ !~ m{/keysafe/};
        open(my $fh, '<:raw', $_) or die; local $/; $all .= <$fh>;
    } }, $base);
    return $all;
}

# --- ops are listed
for my $op (qw(zvol-create zvol-destroy zvol-list export unexport status trim-check)) {
    ok(scalar(grep { $_ eq $op } HPS::Storage::ops()), "op $op is known");
}

# --- zvol-create
{
    my $f = fresh();
    my $r = $f->{st}->run('zvol-create', dataset => $DS, size => '1G');
    is_deeply([ $f->{ce}->scripts ], ['storage-zvol-create'], 'one call');
    is_deeply(($f->{ce}->calls)[0]{args}, [ $DS, '1G' ], 'arguments: dataset, size');
    is(($f->{ce}->calls)[0]{input}, undef, 'no input');
    ok($r->{ok}, 'ok');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{op}, 'zvol-create', 'storage_last records the op');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'zvol-create sets no pool state');
    for my $bad (undef, '', 'lab', 'lab/enc', 'lab/enc/a/b', 'lab/t0', 'lab/enc/t0;x', 'Lab/enc/t0') {
        my $e = err_of(sub { $f->{st}->run('zvol-create', dataset => $bad, size => '1G') });
        is(ref $e && $e->kind, 'usage', 'bad dataset ' . ($bad // 'undef') . ': usage');
    }
    for my $bad (undef, '', '1', '0G', '1g', '1X', '-1G', '1.5G', '1G; x') {
        my $e = err_of(sub { $f->{st}->run('zvol-create', dataset => $DS, size => $bad) });
        is(ref $e && $e->kind, 'usage', 'bad size ' . ($bad // 'undef') . ': usage');
    }
    is(err_of(sub { $f->{st}->run('zvol-create', dataset => 'other/enc/t0', size => '1G') })->kind, 'refused', 'a dataset in another pool is refused');
    is(scalar($f->{ce}->calls), 1, 'refusals called nothing');
}

# --- zvol-create node failure is reported
{
    my $f = fresh(ce => { rc => { 'storage-zvol-create' => 3 } });
    my $e = err_of(sub { $f->{st}->run('zvol-create', dataset => $DS, size => '1G') });
    is($e->kind, 'refused', 'node exit 3 -> refused');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{ok}, 0, 'recorded as failed');
}

# --- zvol-list and status
{
    my $f = fresh();
    $f->{st}->run('zvol-list');
    is_deeply([ $f->{ce}->scripts ], ['storage-zvol-list'], 'zvol-list call');
    is_deeply(($f->{ce}->calls)[0]{args}, ['lab'], 'with the pool');
    $f->{ce}{calls} = [];
    $f->{st}->run('status');
    is_deeply([ $f->{ce}->scripts ], ['storage-status'], 'status is the single read-only storage-status call');
    is_deeply(($f->{ce}->calls)[0]{args}, ['lab'], 'with the pool');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'status changes no state');
}

# --- export / unexport / up
{
    my $f = fresh();
    $f->{reg}->host_set($mac, 'IP', '192.0.2.10');
    $f->{ks}->get_or_create_key($mac, 'enc');
    my $r = $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI);
    is_deeply([ $f->{ce}->scripts ], ['iscsi-export'], 'export runs iscsi-export');
    is_deeply(($f->{ce}->calls)[0]{args}, [ $DS, '--iqn', $IQN, '--initiator', $INI, '--portal', '192.0.2.10' ], 'portal defaults to the host IP');
    is_deeply([ exports($f) ], [ { zvol => $DS, iqn => $IQN, initiator => $INI, portal => '192.0.2.10' } ], 'recorded in storage_exports');

    $f->{ce}{calls} = [];
    $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI, portal => '192.0.2.11');
    is(nexp($f), 1, 're-export replaces the entry of the same iqn');
    is((exports($f))[0]{portal}, '192.0.2.11', 'with the new portal');

    # refusals: nothing called, nothing recorded
    $f->{ce}{calls} = [];
    is(err_of(sub { $f->{st}->run('export', dataset => 'lab/enc/t1', iqn => $IQN, initiator => $INI) })->kind, 'refused', 'iqn already used by another zvol');
    is(err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => 'iqn.2026-11.example.lab:t9', initiator => $INI) })->kind, 'refused', 'zvol already exported under another iqn');
    is(err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => 'bogus', initiator => $INI) })->kind, 'usage', 'bad target iqn');
    is(err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => 'bogus') })->kind, 'usage', 'bad initiator iqn');
    is(err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI, portal => '0.0.0.0') })->kind, 'usage', 'wildcard portal refused');
    is(err_of(sub { $f->{st}->run('export', iqn => $IQN, initiator => $INI) })->kind, 'usage', 'no dataset');
    is(scalar($f->{ce}->calls), 0, 'refusals called nothing');
    is(nexp($f), 1, 'and changed nothing');

    # up re-exports every recorded export after unlock
    $f->{st}->run('up');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-pool-import', 'dataset-unlock', 'iscsi-export' ], 'up: import, unlock, then the recorded export');
    is(($f->{ce}->calls)[2]{args}[0], $DS, 'the recorded zvol');

    # unexport
    $f->{ce}{calls} = [];
    $f->{st}->run('unexport', iqn => $IQN);
    is_deeply([ $f->{ce}->scripts ], ['iscsi-unexport'], 'unexport call');
    is_deeply(($f->{ce}->calls)[0]{args}, [$IQN], 'with the iqn');
    is(nexp($f), 0, 'entry removed');
    ok(!$f->{reg}->host_exists($mac, 'storage_exports'), 'the key is gone with the last entry');
    $f->{st}->run('unexport', iqn => $IQN);
    is(scalar($f->{ce}->calls), 2, 'unexport of an unknown iqn still asks the node (idempotent there)');
    is(err_of(sub { $f->{st}->run('unexport', iqn => 'x') })->kind, 'usage', 'bad iqn');
}

# --- export without a portal and without an IP
{
    my $f = fresh();
    my $e = err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI) });
    is($e->kind, 'usage', 'no portal and no registry IP: usage');
    like($e->message, qr/--portal/, 'says so');
}

# --- export failure records nothing
{
    my $f = fresh(ce => { rc => { 'iscsi-export' => 1 } });
    $f->{reg}->host_set($mac, 'IP', '192.0.2.10');
    err_of(sub { $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI) });
    is(nexp($f), 0, 'a failed export is not recorded');
}

# --- zvol-destroy
{
    my $f = fresh();
    is(err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) })->kind, 'refused', 'no approval: refused');
    like(err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) })->message, qr/hps-approve zvol-destroy \Q$mac\E --dataset \Q$DS\E/, 'says what a human runs');
    is(scalar($f->{ce}->calls), 0, 'nothing sent');
    StorageFixture::approve($f, 'pool-destroy');
    is(err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) })->kind, 'refused', 'a pool-destroy approval is not a zvol approval');

    my $doc = approve_zvol($f);
    my $plan = $f->{st}->plan('zvol-destroy', dataset => $DS);
    is_deeply([ scripts($plan) ], ['storage-zvol-destroy'], 'plan: one call');
    like($plan->[0]{input}, qr/"hmac":"<redacted>"/, 'plan input is redacted');
    unlike(JSON::PP->new->encode($plan), qr/[0-9a-f]{64}/, 'no 64-hex in the plan');
    $f->{st}->run('zvol-destroy', dataset => $DS);
    my @c = $f->{ce}->calls;
    is_deeply($c[0]{args}, [ $DS, '--approval-file', '-' ], 'arguments');
    my $in = decode_json($c[0]{input});
    is_deeply([ sort keys %$in ], [ 'approval', 'secret' ], 'input is approval + secret');
    is(JSON::PP->new->canonical->encode($in->{approval}), $doc, 'approval as stored');
    is($in->{approval}{pool}, $DS, 'pool member carries the dataset');
    is_deeply([ sort keys %{ $in->{approval} } ], [qw(action disks expires hmac issued_by mac pool wipe)], 'eight members');
    unlike(registry_text($f->{base}), qr/\Q$in->{secret}\E/, 'the secret is in no registry file');
    ok(!grep({ index($_, $in->{secret}) >= 0 } @{ $f->{log} }), 'the secret is in no log line');
}

# --- zvol-destroy: wrong dataset, exported, expired, the cluster ruling
{
    my $f = fresh();
    approve_zvol($f, pool => 'lab/enc/other');
    is(err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) })->kind, 'refused', 'an approval for another dataset does not apply');
    approve_zvol($f);
    $f->{reg}->host_set($mac, 'storage_exports', [ { zvol => $DS, iqn => $IQN, initiator => $INI, portal => '192.0.2.10' } ]);
    my $e = err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) });
    is($e->kind, 'refused', 'an exported zvol is refused on the IPS too');
    like($e->message, qr/unexport/, 'says to unexport first');
    is(scalar($f->{ce}->calls), 0, 'nothing sent');
    $f->{reg}->host_unset($mac, 'storage_exports');
    $StorageFixture::NOW += 4000;
    is(err_of(sub { $f->{st}->run('zvol-destroy', dataset => $DS) })->kind, 'expired', 'an expired approval is refused');

    my $g = fresh();
    $g->{ap}->issue({ action => 'zvol-destroy', mac => $mac, pool => 'zp03/enc/x', issued_by => 'tester' });
    is(err_of(sub { $g->{st}->run('zvol-destroy', dataset => 'zp03/enc/x') })->kind, 'refused', 'a pool not named after the cluster is refused');
    my $any = $g->{mk}->(allow_any_pool_name => 1);
    $any->run('zvol-destroy', dataset => 'zp03/enc/x');
    is(($g->{ce}->calls)[0]{args}[0], 'zp03/enc/x', '--allow-any-pool-name lets it through');
}

# --- dry runs change nothing
{
    my $f = fresh();
    approve_zvol($f);
    $f->{reg}->host_set($mac, 'IP', '192.0.2.10');
    $f->{st}->run('zvol-create', dataset => $DS, size => '1G', dry_run => 1);
    $f->{st}->run('zvol-destroy', dataset => $DS, dry_run => 1);
    $f->{st}->run('export', dataset => $DS, iqn => $IQN, initiator => $INI, dry_run => 1);
    $f->{st}->run('unexport', iqn => $IQN, dry_run => 1);
    is(scalar($f->{ce}->calls), 0, 'dry runs sent nothing');
    is(nexp($f), 0, 'and recorded nothing');
}

# --- the trim verdict: stdout, never a stderr trace
package TrimCE {
    sub new { my ($c, %o) = @_; return bless { %o }, $c }
    sub call { my ($s, %c) = @_; return { rc => $s->{rc} // 0, stdout => $s->{stdout}, stderr => $s->{stderr} // '' } }
}
package main;
{
    my $trace = "+ lsblk -D -b -n -o NAME,DISC-GRAN,DISC-MAX /dev/disk/by-id/ata-A\n+ zpool trim -w lab\n+ zpool status -t lab\n";
    my $out   = "ata-A-part1 4096 2147483648\n  pool: lab\n state: ONLINE\nTRIM OK\n";
    my @cases = (
        [ 'stdout verdict, stderr trace kept apart',      { stdout => $out, stderr => $trace }, 'TRIM OK', 1 ],
        [ 'trace lines appended after the verdict',       { stdout => $out . $trace, stderr => '' }, 'TRIM OK', 1 ],
        [ 'trailing blank lines',                         { stdout => $out . "\n\n", stderr => $trace }, 'TRIM OK', 1 ],
        [ 'no verdict line: last non-empty stdout line',  { stdout => "one\ntwo\n", stderr => $trace }, 'two', 0 ],
        [ 'empty stdout, trace only on stderr',           { stdout => '', stderr => $trace }, '', 0 ],
    );
    for my $c (@cases) {
        my $f = StorageFixture::setup();
        my $st = $f->{mk}->(runner => TrimCE->new(%{ $c->[1] }));
        $st->run('trim-check');
        is($f->{reg}->host_get($mac, 'storage_trim_verdict'), $c->[2], "verdict: $c->[0]");
        is($f->{reg}->host_get($mac, 'storage_trim_ok'), $c->[3], "storage_trim_ok: $c->[0]");
        unlike($f->{reg}->host_get($mac, 'storage_trim_verdict'), qr/^\+ /, 'never a "+ cmd" trace');
        like($f->{reg}->host_get($mac, 'storage_trim_at'), qr/^\d{4}-\d\d-\d\d /, 'time recorded');
    }
    my $f = StorageFixture::setup();
    my $bad = TrimCE->new(rc => 3, stdout => "x\nTRIM NOT REACHING ata-A\n", stderr => $trace);
    my $st = $f->{mk}->(runner => $bad);
    is(err_of(sub { $st->run('trim-check') })->kind, 'refused', 'a TRIM NOT REACHING exit 3 is refused');
    is($f->{reg}->host_get($mac, 'storage_trim_verdict'), 'TRIM NOT REACHING ata-A', 'the failing verdict is recorded too');
    is($f->{reg}->host_get($mac, 'storage_trim_ok'), 0, 'storage_trim_ok=0');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{ok}, 0, 'storage_last records the failure');
}

done_testing;
