#!/usr/bin/env perl
# CS-2.5: the zvol-destroy approval. The fixtures t/fixtures/approval-zvol-destroy.*
# are what the Bash verifier in storage-zvol-destroy is tested against
# (scripts/tests/test_p2_71_*.bats); this test pins them to HPS::Approval.
# HPS_REGEN_FIXTURES=1 rewrites them (the expiry is far in the future so they do
# not go stale).
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

sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; return $t }
sub spew  { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }

my $fx  = "$Bin/fixtures/approval-zvol-destroy";
my $sec = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
my $bin = pack 'H*', $sec;
my %f = (action => 'zvol-destroy', mac => '52:54:00:00:00:01', pool => 'lab/enc/t0',
         disks => [], wipe => 0, expires => 4102444800, issued_by => 'operator');
my $canon = HPS::Approval::canonical({%f});
my $hex = hmac_sha256_hex($canon, $bin);
if ($ENV{HPS_REGEN_FIXTURES}) {
    spew("$fx.json", $canon);
    spew("$fx.hmac", "$hex\n");
    spew("$fx.secret.hex", "$sec\n");
}

is($canon, '{"action":"zvol-destroy","disks":[],"expires":4102444800,"issued_by":"operator","mac":"525400000001","pool":"lab/enc/t0","wipe":0}',
   'canonical form: eight members once hmac is added, pool = the dataset');
is(slurp("$fx.json"), $canon, 'fixture payload is what canonical() produces');
(my $fhex = slurp("$fx.hmac")) =~ s/\s+\z//;
is($fhex, $hex, 'fixture hmac matches');
(my $fsec = slurp("$fx.secret.hex")) =~ s/\s+\z//;
is($fsec, $sec, 'fixture secret');
my $doc = $canon =~ s/"issued_by"/"hmac":"$hex","issued_by"/r;
ok(HPS::Approval->verify($doc, $bin, now => 1800000000), 'verify accepts the fixture document');
is(HPS::Approval::signed_payload($doc), $canon, 'signed_payload strips the hmac');
my @members = sort keys %{ decode_json($doc) };
is_deeply(\@members, [qw(action disks expires hmac issued_by mac pool wipe)], 'the eight members of every approval');

# the same checks the other actions get
for my $bad ('lab', 'lab/enc', 'lab/t0', 'lab/enc/a/b', 'lab/enc/x__y', 'Lab/enc/t0;x', '/lab/enc/t0') {
    my $e = err_of(sub { HPS::Approval::canonical({ %f, pool => $bad }) });
    is(ref $e && $e->kind, 'usage', "zvol-destroy refuses pool '$bad'");
}
is(err_of(sub { HPS::Approval::canonical({ %f, disks => ['ata-X'] }) })->kind, 'usage', 'zvol-destroy takes no disks');
is(err_of(sub { HPS::Approval::canonical({ %f, wipe => 1 }) })->kind, 'usage', 'zvol-destroy takes wipe 0');
is(err_of(sub { HPS::Approval::canonical({ %f, action => 'pool-destroy' }) })->kind, 'usage', 'a dataset is not a pool name for pool-destroy');
ok(grep({ $_ eq 'zvol-destroy' } HPS::Approval::actions()), 'zvol-destroy is an allowed action');
is(HPS::Approval::canonical({ action => 'pool-create', mac => '52:54:00:00:00:01', pool => 'lab',
    disks => [ 'ata-FAKE_2', 'ata-FAKE_1' ], wipe => 1, expires => 1800003600, issued_by => 'operator' }),
   slurp("$Bin/fixtures/approval-canonical.json"), 'the pool-create canonical form is unchanged');

# issue / get / list / revoke with a slash-bearing pool
my $base = tempdir(CLEANUP => 1);
my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->host_set('52:54:00:00:00:01', 'STATE', 'NETWORK_BOOT');
my $now = 1_800_000_000;
my $ap = HPS::Approval->new(registry => $reg, keysafe => HPS::Keysafe->new(registry => $reg), now => sub { $now });
my $issued = $ap->issue({ action => 'zvol-destroy', mac => '52:54:00:00:00:01', pool => 'lab/enc/t0', issued_by => 'tester' });
like($issued, qr/"pool":"lab\/enc\/t0"/, 'issued with the dataset as pool');
ok($reg->host_exists('525400000001', 'approval_zvol-destroy_lab__enc__t0'), 'stored under a slash-free registry key');
is($ap->get('525400000001', 'zvol-destroy', 'lab/enc/t0'), $issued, 'get reads it back byte-identical');
my ($row) = $ap->list('525400000001');
is($row->{status}, 'valid', 'list: valid');
is($ap->revoke('525400000001', 'zvol-destroy', 'lab/enc/t0'), 1, 'revoke removes it');
is($ap->get('525400000001', 'zvol-destroy', 'lab/enc/t0'), undef, 'gone');

done_testing;
