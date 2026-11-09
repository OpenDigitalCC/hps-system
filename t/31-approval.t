#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Digest::SHA qw(hmac_sha256_hex);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Keysafe;
use HPS::Approval;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->host_set('52:54:00:00:00:01', 'STATE', 'NETWORK_BOOT');
my $now = 1_800_000_000;
my $ks  = HPS::Keysafe->new(registry => $reg);
my $ap  = HPS::Approval->new(registry => $reg, keysafe => $ks, now => sub { $now });
my $secret = $ks->cluster_secret('approval');

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my %f = (action => 'pool-create', mac => '52:54:00:00:00:01', pool => 'lab',
         disks => [ 'ata-B', 'ata-A' ], wipe => 1, issued_by => 'tester');
my $doc = $ap->issue({%f});
my $d = decode_json($doc);
is_deeply($d->{disks}, [ 'ata-A', 'ata-B' ], 'disks sorted');
is($d->{expires}, $now + 3600, 'default expiry is one hour');
is($d->{mac}, '525400000001', 'mac normalised');
like($doc, qr/^\{"action":"pool-create","disks":\["ata-A","ata-B"\],"expires":1800003600,"hmac":"[0-9a-f]{64}","issued_by":"tester","mac":"525400000001","pool":"lab","wipe":1\}$/, 'canonical, sorted, no whitespace, numbers bare');
is($ap->get('525400000001', 'pool-create', 'lab'), $doc, 'stored approval reads back byte-identical');
ok($reg->host_exists('525400000001', 'approval_pool-create_lab'), 'stored under approval_<action>_<pool>');

my $v = $ap->verify($doc, $secret);
is($v->{pool}, 'lab', 'verify returns the fields');
is(HPS::Approval->verify($doc, $secret)->{wipe}, 1, 'verify works as a class method too');

# tamper
(my $t1 = $doc) =~ s/ata-A/ata-Z/;
is(err_of(sub { $ap->verify($t1, $secret) })->kind, 'tampered', 'changed disk refused');
(my $t2 = $doc) =~ s/"wipe":1/"wipe":0/;
is(err_of(sub { $ap->verify($t2, $secret) })->kind, 'tampered', 'changed wipe refused');
(my $t3 = $doc) =~ s/"expires":1800003600/"expires":1900003600/;
is(err_of(sub { $ap->verify($t3, $secret) })->kind, 'tampered', 'extended expiry refused');
(my $t4 = $doc) =~ s/"pool":"lab"/"pool":"zp03"/;
is(err_of(sub { $ap->verify($t4, $secret) })->kind, 'tampered', 'changed pool refused');
is(err_of(sub { $ap->verify($doc, 'x' x 32) })->kind, 'tampered', 'wrong secret refused');
(my $t5 = $doc) =~ s/,/, /;
is(err_of(sub { $ap->verify($t5, $secret) })->kind, 'tampered', 'non-canonical whitespace refused');
(my $t6 = $doc) =~ s/\}$/,"extra":1}/;
is(err_of(sub { $ap->verify($t6, $secret) })->kind, 'tampered', 'extra member refused');
is(err_of(sub { $ap->verify('not json', $secret) })->kind, 'malformed', 'garbage refused');
(my $t7 = $doc) =~ s/"hmac":"[0-9a-f]{64}",//;
is(err_of(sub { $ap->verify($t7, $secret) })->kind, 'malformed', 'missing hmac refused');

# expiry
is(err_of(sub { $ap->verify($doc, $secret, now => $now + 3600) })->kind, 'expired', 'expired refused');
ok($ap->verify($doc, $secret, now => $now + 3599), 'one second before expiry is fine');
$now += 7200;
is(err_of(sub { $ap->verify($doc, $secret) })->kind, 'expired', 'expired by the object clock');
my ($row) = $ap->list('525400000001');
is($row->{status}, 'expired', 'list reports expired');
my $doc2 = $ap->issue({%f, disks => ['ata-A'], wipe => 0});
is($ap->get('525400000001', 'pool-create', 'lab'), $doc2, 'reissue overwrites the expired approval');
($row) = $ap->list('525400000001');
is($row->{status}, 'valid', 'list reports valid');

# issue validation
for my $case (
    [ { %f, action => 'format-all' }, 'unknown action' ],
    [ { %f, pool => 'a b' },          'bad pool' ],
    [ { %f, disks => [] },            'pool-create without disks' ],
    [ { %f, disks => ['x', 'x'] },    'duplicate disk' ],
    [ { %f, disks => ['../x'] },      'bad disk name' ],
    [ { %f, wipe => 2 },              'bad wipe' ],
    [ { %f, expires => $now - 1 },    'expiry in the past' ],
    [ { %f, issued_by => "a\nb" },    'bad issued_by' ],
    [ { %f, mac => 'zz' },            'bad mac' ],
) {
    is(err_of(sub { $ap->issue($case->[0]) })->kind, 'usage', "refused: $case->[1]");
}
is(err_of(sub { $ap->issue({ %f, mac => '52:54:00:00:00:99' }) })->kind, 'notfound', 'unknown host');
my $dd = decode_json($ap->issue({ action => 'pool-destroy', mac => '525400000001', pool => 'zp03' }));
is_deeply($dd->{disks}, [], 'pool-destroy needs no disks');
ok($dd->{issued_by} && length $dd->{issued_by}, 'issued_by defaulted');

# revoke
ok($ap->revoke('525400000001', 'pool-destroy', 'zp03'), 'revoke');
ok(!$ap->revoke('525400000001', 'pool-destroy', 'zp03'), 'revoke twice is 0');
ok(!defined $ap->get('525400000001', 'pool-destroy', 'zp03'), 'gone');

# constant-time compare
ok(HPS::Approval->can('ct_equal'), 'ct_equal exists');
ok(HPS::Approval::ct_equal('abc', 'abc'), 'ct_equal equal');
ok(!HPS::Approval::ct_equal('abc', 'abd'), 'ct_equal differs');
ok(!HPS::Approval::ct_equal('abc', 'ab'), 'ct_equal length');
ok(!HPS::Approval::ct_equal(undef, 'ab'), 'ct_equal undef');
my $src = slurp("$Bin/../lib/perl/HPS/Approval.pm");
unlike($src, qr/\$\w+\s+eq\s+\$hmac|_sign\([^)]*\)\s+eq\b/, 'no plain eq on the signature');

# fixture: byte-for-byte for the Bash verifier
my $fx = "$Bin/fixtures/approval-canonical";
my $payload = slurp("$fx.json");
(my $hex = slurp("$fx.hmac")) =~ s/\s+\z//;
(my $sec = slurp("$fx.secret.hex")) =~ s/\s+\z//;
my $bin = pack 'H*', $sec;
is(HPS::Approval::canonical({ action => 'pool-create', mac => '52:54:00:00:00:01', pool => 'lab',
    disks => [ 'ata-FAKE_2', 'ata-FAKE_1' ], wipe => 1, expires => 1800003600, issued_by => 'operator' }),
    $payload, 'fixture payload is what canonical() produces');
is(hmac_sha256_hex($payload, $bin), $hex, 'fixture hmac matches');
my $fdoc = $payload =~ s/"issued_by"/"hmac":"$hex","issued_by"/r;
is(HPS::Approval::signed_payload($fdoc), $payload, 'signed_payload strips the hmac member');
ok(HPS::Approval->verify($fdoc, $bin, now => 1800000000), 'verify accepts the fixture document');
SKIP: {
    my $ssl = qx(command -v openssl 2>/dev/null); chomp $ssl;
    skip 'no openssl', 1 unless $ssl;
    open(my $p, '-|', $ssl, 'dgst', '-sha256', '-mac', 'HMAC', '-macopt', "hexkey:$sec", '-r', "$fx.json") or die;
    my $out = <$p>; close $p;
    like($out, qr/^\Q$hex\E /, 'openssl dgst produces the same hmac');
}

done_testing;
