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

# --- create: no approval, the disks and the wipe flag are arguments
my %d2 = (disks => [ 'ata-SSD1', 'ata-SSD2' ]);
$plan = $st->plan('create', pool => 'lab', %d2);
is_deeply([ scripts($plan) ], [ 'storage-pool-create', 'storage-pool-import', 'dataset-unlock' ], 'create without any approval = create then up');
is_deeply($plan->[0]{args}, [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2' ], 'create arguments carry the named disks, no --approval-file');
my $in = decode_json($plan->[0]{input});
is_deeply([ sort keys %$in ], ['key_hex'], 'create input is the pool key only');
like($in->{key_hex}, qr/^<redacted/, 'the key is redacted in the plan');
is_deeply($st->plan('create', pool => 'lab', %d2, wipe => 1)->[0]{args}, [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2', '--wipe' ], 'wipe => 1 adds --wipe');
is_deeply($st->plan('create', pool => 'lab', disks => [ '/dev/disk/by-id/ata-SSD1', 'ata-SSD2', 'ata-SSD3' ])->[0]{args},
    [ 'lab', '--disk', 'ata-SSD1', '--disk', 'ata-SSD2', '--disk', 'ata-SSD3' ], 'three disks (three-way mirror); the by-id directory is dropped');
is(scalar(@{ $st->plan('create', pool => 'lab', disks => [ map {"ata-SSD$_"} 1 .. 4 ])->[0]{args} }), 9, 'four disks accepted');
is_deeply($st->plan('create', pool => 'lab', disks => ['ata-SSD1'])->[0]{args}, [ 'lab', '--disk', 'ata-SSD1' ],
    'one disk: a single-vdev pool, the normal SCH shape (the mirror is across storage hosts)');

# --- the disk and wipe arguments are validated (what the approval used to check)
for my $case (
    [ {}, qr/one to four --disk/, 'no disks' ],
    [ { disks => [] }, qr/one to four --disk/, 'an empty list' ],
    [ { disks => [ map {"ata-SSD$_"} 1 .. 5 ] }, qr/one to four --disk/, 'five disks' ],
    [ { disks => [ 'ata-SSD1', 'ata-SSD1' ] }, qr/disk listed twice: ata-SSD1/, 'a disk twice' ],
    [ { disks => [ 'ata-SSD1', '/dev/disk/by-id/ata-SSD1' ] }, qr/disk listed twice/, 'a disk twice, once with the directory' ],
    [ { disks => [ 'ata-SSD1', '/dev/sdb' ] }, qr/not a \/dev\/disk\/by-id name/, 'a /dev/sdX path' ],
    [ { disks => [ 'ata-SSD1', 'x; rm -rf /' ] }, qr/not a \/dev\/disk\/by-id name/, 'shell characters' ],
    [ { disks => [ 'ata-SSD1', '-x' ] }, qr/not a \/dev\/disk\/by-id name/, 'a leading dash' ],
    [ { disks => 'ata-SSD1' }, qr/disks must be a list/, 'not a list' ],
    [ { %d2, wipe => 2 }, qr/wipe must be 0 or 1/, 'wipe 2' ],
) {
    my $e = err_of(sub { $st->plan('create', pool => 'lab', %{ $case->[0] }) });
    is($e && $e->kind, 'usage', "create refused: $case->[2] (usage)");
    like($e && $e->message, $case->[1], "... $case->[2]: message");
}

# --- an unassigned or HELD host gets no pool (a refusal that stays)
for my $state ('', 'HELD') {
    $reg->host_set($mac, 'STATE', $state);
    my $e = err_of(sub { $st->plan('create', pool => 'lab', %d2) });
    is($e && $e->kind, 'refused', "create on a host with STATE '$state' is refused");
    like($e && $e->message, qr/not assigned.*hps-onboard assign/, '... and says what to run');
}
$reg->host_set($mac, 'STATE', 'NETWORK_BOOT');

# --- the ruling on pool names
is(err_of(sub { $st->plan('create', pool => 'zp03', %d2) })->kind, 'refused', 'non-cluster pool name refused');
like(err_of(sub { $st->plan('create', pool => 'zp03', %d2) })->message, qr/--allow-any-pool-name/, 'message names the override');
my $any = $f->{mk}->(allow_any_pool_name => 1);
is(($any->plan('create', pool => 'zp03', %d2))->[0]{args}[0], 'zp03', 'override allows it');
is(err_of(sub { $st->plan('create', pool => 'Bad Pool', %d2) })->kind, 'usage', 'bad pool syntax is usage');
is(err_of(sub { $st->plan('destroy', pool => 'zp03') })->kind, 'refused', 'destroy: non-cluster pool name refused');

# --- destroy: no approval, one call, no input
$plan = $st->plan('destroy', pool => 'lab');
is_deeply([ scripts($plan) ], ['storage-pool-destroy'], 'destroy without any approval is one call');
is_deeply($plan->[0]{args}, ['lab'], 'destroy arguments: the pool only');
is($plan->[0]{input}, undef, 'destroy has no input');

# --- redaction: no 64-hex anywhere in any plan text
my $key_hex = unpack('H*', $f->{ks}->get_or_create_key($mac, 'enc'));
for my $op (qw(up down create destroy trim-check status)) {
    my $p = text($st->plan($op, pool => 'lab', ($op eq 'create' ? %d2 : ())));
    unlike($p, qr/[0-9a-f]{64}/i, "plan($op) carries no 64-hex value");
    ok(index($p, $key_hex) < 0, "plan($op) does not carry the key");
}
ok(!grep({ /[0-9a-f]{64}/i } @{ $f->{log} }), 'nothing logged by planning carries a 64-hex value');
done_testing;
