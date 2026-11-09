#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Find;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $mac = $StorageFixture::MAC;

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; return $t }
sub fresh { my %o = @_; my $f = StorageFixture::setup(%o); $f->{st} = $f->{mk}->(); return $f }
sub with_exports {
    my $f = shift;
    $f->{reg}->host_set($mac, 'storage_exports', [
        { zvol => 'lab/enc/t0', iqn => 'iqn.2026-11.example:t0', initiator => 'iqn.2026-11.example:ips', portal => '192.0.2.10' } ]);
}
# every byte of every registry file under the temp base, keysafe excluded
sub registry_text {
    my $base = shift;
    my $all = '';
    find({ no_chdir => 1, wanted => sub { $all .= slurp($_) if -f $_ && $_ !~ m{/keysafe/} } }, $base);
    return $all;
}

# --- up: order, inputs, registry
{
    my $f = fresh();
    with_exports($f);
    my $key = $f->{ks}->get_or_create_key($mac, 'enc');
    my $r = $f->{st}->run('up');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-pool-import', 'dataset-unlock', 'iscsi-export' ], 'up: calls in order');
    my @c = $f->{ce}->calls;
    is($c[0]{mac}, $mac, 'calls are addressed by MAC');
    is_deeply($c[0]{args}, ['lab'], 'import lab');
    is($c[0]{input}, undef, 'import sends no input');
    is_deeply($c[1]{args}, ['lab/enc'], 'unlock lab/enc');
    is($c[1]{input}, '{"key_hex":"' . unpack('H*', $key) . '"}', 'unlock input is exactly {"key_hex":"<64 hex>"}');
    is($c[2]{input}, undef, 'export sends no input');
    is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'storage_state=up');
    like($f->{reg}->host_get($mac, 'storage_up_at'), qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC$/, 'storage_up_at recorded');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{ok}, 1, 'storage_last records success');
    ok($r->{ok}, 'run returns ok');
    is(scalar @{ $r->{steps} }, 3, 'result lists the steps');
    unlike(registry_text($f->{base}), qr/\Q@{[ unpack('H*', $key) ]}\E/, 'the key is in no registry file');
    ok(!grep({ index($_, unpack('H*', $key)) >= 0 } @{ $f->{log} }), 'the key is in no log line');

    # idempotent: the same again
    $f->{ce}{calls} = [];
    $f->{st}->run('up');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-pool-import', 'dataset-unlock', 'iscsi-export' ], 'up twice: the same calls');
    is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'still up');
}

# --- up refuses without a key
{
    my $f = fresh();
    my $e = err_of(sub { $f->{st}->run('up') });
    is($e->kind, 'notfound', 'up without a key: notfound');
    like($e->message, qr/pool not created by HPS/, 'message');
    is(scalar($f->{ce}->calls), 0, 'no node call was made');
    ok(!$f->{ks}->has_key($mac, 'enc'), 'no key was created');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'no state recorded');
}

# --- create
{
    my $f = fresh();
    with_exports($f);
    is(err_of(sub { $f->{st}->run('create', pool => 'lab') })->kind, 'refused', 'create without approval refused');
    is(scalar($f->{ce}->calls), 0, 'nothing sent without approval');
    ok(!$f->{ks}->has_key($mac, 'enc'), 'no key generated without approval');
    my $doc = StorageFixture::approve($f, 'pool-create');
    $f->{st}->run('create', pool => 'lab');
    my @c = $f->{ce}->calls;
    is_deeply([ map { $_->{script} } @c ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock', 'iscsi-export' ], 'create then up');
    is(scalar(grep { $_->{script} eq 'storage-pool-create' } @c), 1, 'create sent exactly once');
    is_deeply($c[0]{args}, [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2', '--approval-file', '-' ], 'create arguments');
    my $key_hex = unpack('H*', $f->{ks}->get_or_create_key($mac, 'enc'));
    my $sec_hex = unpack('H*', $f->{ks}->cluster_secret('approval'));
    my $in = decode_json($c[0]{input});
    is_deeply([ sort keys %$in ], [ 'approval', 'key_hex', 'secret' ], 'create input members');
    is($in->{key_hex}, $key_hex, 'key_hex is the keysafe enc key');
    is($in->{secret}, $sec_hex, 'secret is the cluster approval secret');
    is(JSON::PP->new->canonical->encode($in->{approval}), $doc, 'the approval travels as stored (signature intact)');
    is(scalar(grep { defined $_->{input} && index($_->{input}, $sec_hex) >= 0 } @c), 1, 'the secret is sent exactly once');
    is(scalar(grep { defined $_->{input} && index($_->{input}, $key_hex) >= 0 } @c), 2, 'the key goes to create and to the unlock only');
    is($c[2]{input}, "{\"key_hex\":\"$key_hex\"}", 'unlock after create uses the same key');
    is($f->{reg}->host_get($mac, 'storage_pool'), 'lab', 'storage_pool recorded');
    ok($f->{reg}->host_exists($mac, 'storage_created_at'), 'storage_created_at recorded');
    is($f->{reg}->host_get($mac, 'storage_state'), 'up', 'state up after create');
    my $reg_text = registry_text($f->{base});
    ok(index($reg_text, $key_hex) < 0 && index($reg_text, $sec_hex) < 0, 'neither key nor secret in any registry file');
    ok(!grep({ index($_, $key_hex) >= 0 || index($_, $sec_hex) >= 0 } @{ $f->{log} }), 'neither in any log line');
}

# --- create: a failing create stops everything and records nothing but the failure
{
    my $f = fresh(ce => { rc => { 'storage-pool-create' => 3 } });
    StorageFixture::approve($f, 'pool-create');
    my $e = err_of(sub { $f->{st}->run('create', pool => 'lab') });
    is($e->kind, 'refused', 'node exit 3 is a refusal');
    like($e->message, qr/storage-pool-create exited 3: boom from storage-pool-create/, 'message names step, rc and the node stderr');
    is(scalar($f->{ce}->calls), 1, 'no call after the failure');
    ok(!$f->{reg}->host_exists($mac, 'storage_state') && !$f->{reg}->host_exists($mac, 'storage_pool'), 'no pool state recorded');
    is($f->{reg}->host_get_json($mac, 'storage_last')->{ok}, 0, 'storage_last records the failure');
}

# --- up: a failing unlock stops before the exports and leaves state alone
{
    my $f = fresh(ce => { rc => { 'dataset-unlock' => 1 } });
    with_exports($f);
    $f->{ks}->get_or_create_key($mac, 'enc');
    my $e = err_of(sub { $f->{st}->run('up') });
    is($e->kind, 'failed', 'node exit 1 is a failure');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-pool-import', 'dataset-unlock' ], 'no export after a failed unlock');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'state not set to up');
}

# --- retry while the agent is not there yet
{
    my $f = fresh(ce => { rc => { 'storage-pool-import' => [ 4, 4, 0 ] } });
    $f->{ks}->get_or_create_key($mac, 'enc');
    my $st = $f->{mk}->(wait => 60);
    $st->run('up');
    is(scalar(grep { $_ eq 'storage-pool-import' } $f->{ce}->scripts), 3, 'first call retried while the agent is missing (wait 60)');
    my $g = fresh(ce => { rc => { 'storage-pool-import' => [ 4, 0 ] } });
    $g->{ks}->get_or_create_key($mac, 'enc');
    ok(err_of(sub { $g->{st}->run('up') }), 'without --wait the first failure ends the run');
    is(scalar($g->{ce}->calls), 1, 'one attempt');
}

# --- down never touches the pool
{
    my $f = fresh();
    with_exports($f);
    $f->{reg}->host_set($mac, 'storage_state', 'up');
    $f->{st}->run('down');
    is_deeply([ $f->{ce}->scripts ], ['iscsi-unexport'], 'down: unexport only');
    is_deeply(($f->{ce}->calls)[0]{args}, ['iqn.2026-11.example:t0'], 'target iqn');
    is($f->{reg}->host_get($mac, 'storage_state'), 'down', 'storage_state=down');
    ok($f->{reg}->host_exists($mac, 'storage_down_at'), 'storage_down_at');
    $f->{ce}{calls} = [];
    $f->{st}->run('down');
    is_deeply([ $f->{ce}->scripts ], ['iscsi-unexport'], 'down twice: the same call');
    my $none = fresh();
    $none->{st}->run('down');
    is(scalar($none->{ce}->calls), 0, 'down with no exports calls nothing');
    is($none->{reg}->host_get($mac, 'storage_state'), 'down', 'but records down');
    ok(!grep({ /import|export|create|destroy|unlock|trim/ && !/unexport/ } $f->{ce}->scripts), 'no pool script was ever called by down');
}

# --- destroy
{
    my $f = fresh();
    $f->{ks}->get_or_create_key($mac, 'enc');
    $f->{reg}->host_set($mac, $_->[0], $_->[1]) for [ storage_state => 'up' ], [ storage_pool => 'lab' ], [ storage_up_at => 'x' ];
    with_exports($f);
    is(err_of(sub { $f->{st}->run('destroy', pool => 'lab') })->kind, 'refused', 'destroy without approval refused');
    is(scalar($f->{ce}->calls), 0, 'nothing sent');
    my $doc = StorageFixture::approve($f, 'pool-destroy');
    $f->{st}->run('destroy', pool => 'lab');
    my @c = $f->{ce}->calls;
    is_deeply([ map { $_->{script} } @c ], ['storage-pool-destroy'], 'one destroy call');
    is_deeply($c[0]{args}, [ 'lab', '--approval-file', '-' ], 'arguments');
    my $in = decode_json($c[0]{input});
    is_deeply([ sort keys %$in ], [ 'approval', 'secret' ], 'input is approval + secret, no key');
    is(JSON::PP->new->canonical->encode($in->{approval}), $doc, 'approval as stored');
    ok(!$f->{reg}->host_exists($mac, $_), "$_ cleared") for qw(storage_state storage_up_at storage_pool storage_exports);
    ok($f->{ks}->has_key($mac, 'enc'), 'the key is NOT deleted');
}

# --- trim-check and status
{
    my $f = fresh();
    $f->{st}->run('trim-check');
    is_deeply([ $f->{ce}->scripts ], ['storage-trim-check'], 'trim-check call');
    is($f->{reg}->host_get($mac, 'storage_trim_verdict'), 'out of storage-trim-check', 'verdict (last stdout line) recorded');
    $f->{ce}{calls} = [];
    $f->{st}->run('status');
    is_deeply([ $f->{ce}->scripts ], [ 'storage-pool-import', 'iscsi-status' ], 'status calls');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'status changes no state');
}

# --- dry run sends nothing and changes nothing
{
    my $f = fresh();
    with_exports($f);
    StorageFixture::approve($f, 'pool-create');
    StorageFixture::approve($f, 'pool-destroy');
    for my $op (qw(create destroy)) {
        my $r = $f->{st}->run($op, pool => 'lab', dry_run => 1);
        ok($r->{dry_run} && @{ $r->{plan} }, "dry-run $op returns the plan");
    }
    ok(!$f->{ks}->has_key($mac, 'enc'), 'dry-run create generated no key');
    $f->{ks}->get_or_create_key($mac, 'enc');
    for my $op (qw(up down trim-check status)) { $f->{st}->run($op, dry_run => 1) }
    is(scalar($f->{ce}->calls), 0, 'dry runs sent nothing');
    ok(!$f->{reg}->host_exists($mac, 'storage_state'), 'dry runs set no state');
    ok(!$f->{reg}->host_exists($mac, 'storage_last'), 'dry runs record nothing');
}

# --- forget-key
{
    my $f = fresh();
    $f->{ks}->get_or_create_key($mac, 'enc');
    $f->{reg}->host_set($mac, 'storage_state', 'down');
    is(err_of(sub { $f->{st}->forget_key })->kind, 'refused', 'forget-key refused while a pool is recorded');
    ok($f->{ks}->has_key($mac, 'enc'), 'key still there');
    my $d = $f->{st}->forget_key(yes => 1, dry_run => 1);
    ok($d->{dry_run} && $f->{ks}->has_key($mac, 'enc'), 'dry-run keeps the key');
    is($f->{st}->forget_key(yes => 1)->{forgot}, 1, '--yes deletes it');
    ok(!$f->{ks}->has_key($mac, 'enc'), 'key gone');
    is($f->{st}->forget_key(yes => 1)->{forgot}, 0, 'forgetting again is a no-op');
}

done_testing;
