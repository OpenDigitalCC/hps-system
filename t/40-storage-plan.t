#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $f  = StorageFixture::setup();
my $st = $f->{mk}->();
my $reg = $f->{reg};
my $mac = $StorageFixture::MAC;

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub scripts { return map { $_->{script} } @{ $_[0] } }
sub text { return JSON::PP->new->canonical->encode($_[0]) }

# --- host resolution
is($st->mac, $mac, 'host given as MAC');
is(HPS::Storage->new(host => 'sch-001', registry => $reg, keysafe => $f->{ks})->mac, $mac, 'host given as HOSTNAME');
is(err_of(sub { HPS::Storage->new(host => 'nope', registry => $reg, keysafe => $f->{ks}) })->kind, 'notfound', 'unknown host is notfound');
is(err_of(sub { HPS::Storage->new(host => '52:54:00:00:00:99', registry => $reg, keysafe => $f->{ks}) })->kind, 'notfound', 'unknown MAC is notfound');

# --- up: refused without a key, planned with one
is(err_of(sub { $st->plan('up') })->kind, 'notfound', 'up without a key: notfound');
like(err_of(sub { $st->plan('up') })->message, qr/pool not created by HPS/, 'message says so');
ok(!$f->{ks}->has_key($mac, 'enc'), 'the refused plan did not create a key');
$f->{ks}->get_or_create_key($mac, 'enc');
$reg->host_set($mac, 'storage_exports', [
    { zvol => 'lab/enc/t0', iqn => 'iqn.2026-11.example.lab:t0', initiator => 'iqn.2026-11.example.lab:ips', portal => '192.0.2.10' },
]);
my $plan = $st->plan('up');
is_deeply([ scripts($plan) ], [ 'storage-pool-import', 'dataset-unlock', 'iscsi-export' ], 'up: import, unlock, export');
is_deeply($plan->[0]{args}, ['lab'], 'import takes the cluster-named pool');
is_deeply($plan->[1]{args}, ['lab/enc'], 'unlock takes <pool>/enc');
is_deeply($plan->[2]{args}, [ 'lab/enc/t0', '--iqn', 'iqn.2026-11.example.lab:t0', '--initiator', 'iqn.2026-11.example.lab:ips', '--portal', '192.0.2.10' ], 'export arguments');
like($plan->[1]{input}, qr/"key_hex":"<redacted/, 'unlock input described, redacted');
is($plan->[0]{input}, undef, 'import has no input');
is_deeply([ map { $_->{n} } @$plan ], [ 1, 2, 3 ], 'steps are numbered');

# --- down / trim-check / status
is_deeply([ scripts($st->plan('down')) ], ['iscsi-unexport'], 'down unexports each target only');
is_deeply($st->plan('down')->[0]{args}, ['iqn.2026-11.example.lab:t0'], 'unexport takes the target iqn');
is_deeply([ scripts($st->plan('trim-check')) ], ['storage-trim-check'], 'trim-check');
is_deeply([ scripts($st->plan('status')) ], [ 'storage-status' ], 'status = the read-only storage-status (imports nothing)');
like(err_of(sub { $st->plan('explode') })->message, qr/unknown operation/, 'unknown op');

# --- bad exports are malformed, not passed to the node
$reg->host_set($mac, 'storage_exports', [ { zvol => 'lab/enc/t0; rm', iqn => 'iqn.x:y', initiator => 'iqn.x:z', portal => '1.2.3.4' } ]);
is(err_of(sub { $st->plan('down') })->kind, 'malformed', 'bad zvol in storage_exports refused');
$reg->host_unset($mac, 'storage_exports');

# --- create / destroy need approvals
is(err_of(sub { $st->plan('create', pool => 'lab') })->kind, 'refused', 'create without an approval: refused');
like(err_of(sub { $st->plan('create', pool => 'lab') })->message, qr/no pool-create approval/, 'message names the missing approval');
is(err_of(sub { $st->plan('destroy', pool => 'lab') })->kind, 'refused', 'destroy without an approval: refused');
StorageFixture::approve($f, 'pool-create');
$plan = $st->plan('create', pool => 'lab');
is_deeply([ scripts($plan) ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock' ], 'create = create then up');
is_deeply($plan->[0]{args}, [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2', '--approval-file', '-' ], 'create arguments carry the approved disks');
is_deeply($st->approval_info->{disks}, [ 'ata-SSD1', 'ata-SSD2' ], 'approval_info exposes the disks for display');
my $in = decode_json($plan->[0]{input});
is_deeply([ sort keys %$in ], [ 'approval', 'key_hex', 'secret' ], 'create input has the three members');
is($in->{approval}{hmac}, '<redacted>', 'approval signature redacted');
is($in->{approval}{pool}, 'lab', 'approval fields shown');

# --- the ruling on pool names
StorageFixture::approve($f, 'pool-create', pool => 'zp03');
is(err_of(sub { $st->plan('create', pool => 'zp03') })->kind, 'refused', 'non-cluster pool name refused');
like(err_of(sub { $st->plan('create', pool => 'zp03') })->message, qr/--allow-any-pool-name/, 'message names the override');
my $any = $f->{mk}->(allow_any_pool_name => 1);
is(($any->plan('create', pool => 'zp03'))->[0]{args}[0], 'zp03', 'override allows it');
is(err_of(sub { $st->plan('create', pool => 'Bad Pool') })->kind, 'usage', 'bad pool syntax is usage');

# --- approval problems
$reg->host_unset($mac, 'approval_pool-create_zp03');
my $doc = $f->{ap}->get($mac, 'pool-create', 'lab');
(my $bad = $doc) =~ s/ata-SSD1/ata-SSD9/;
$reg->host_set($mac, 'approval_pool-create_lab', decode_json($bad));
is(err_of(sub { $st->plan('create', pool => 'lab') })->kind, 'tampered', 'tampered approval refused');
StorageFixture::approve($f, 'pool-create', expires => $StorageFixture::NOW + 1);
$StorageFixture::NOW += 10;
is(err_of(sub { $st->plan('create', pool => 'lab') })->kind, 'expired', 'expired approval refused');

# --- destroy
StorageFixture::approve($f, 'pool-destroy', expires => $StorageFixture::NOW + 600);
$plan = $st->plan('destroy', pool => 'lab');
is_deeply([ scripts($plan) ], ['storage-pool-destroy'], 'destroy is one call');
is_deeply($plan->[0]{args}, [ 'lab', '--approval-file', '-' ], 'destroy arguments');
is_deeply([ sort keys %{ decode_json($plan->[0]{input}) } ], [ 'approval', 'secret' ], 'destroy input has no key_hex');

# --- redaction: no 64-hex anywhere in any plan text
StorageFixture::approve($f, 'pool-create', expires => $StorageFixture::NOW + 600);
my $key_hex = unpack('H*', $f->{ks}->get_or_create_key($mac, 'enc'));
my $sec_hex = unpack('H*', $f->{ks}->cluster_secret('approval'));
for my $op (qw(up down create destroy trim-check status)) {
    my $p = text($st->plan($op, pool => 'lab'));
    unlike($p, qr/[0-9a-f]{64}/i, "plan($op) carries no 64-hex value");
    ok(index($p, $key_hex) < 0 && index($p, $sec_hex) < 0, "plan($op) carries neither the key nor the secret");
}
ok(!grep({ /[0-9a-f]{64}/i } @{ $f->{log} }), 'nothing logged by planning carries a 64-hex value');
done_testing;
