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
$reg->host_set('aa:bb:cc:dd:ee:ff', 'STATE', 'NETWORK_BOOT');
my $now = 1_800_000_000;
my $ks  = HPS::Keysafe->new(registry => $reg);
my $ap  = HPS::Approval->new(registry => $reg, keysafe => $ks, now => sub { $now });
my $secret = $ks->cluster_secret('approval');

sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my @legs = ('iscsi:10.99.1.2:iqn.2026-01.hps.example:vm1-disk0', 'local:lab/enc/vm/vm1-disk0');
ok((grep { $_ eq 'peer-gone' } HPS::Approval::actions()), 'peer-gone is an action');
ok((grep { $_ eq 'mirror-create' } HPS::Approval::actions()), 'mirror-create is an action');

for my $action (qw(peer-gone mirror-create)) {
    my %f = (action => $action, mac => 'aa:bb:cc:dd:ee:ff', pool => 'vm1-disk0',
             disks => [ reverse @legs ], wipe => ($action eq 'mirror-create' ? 1 : 0), issued_by => 'tester');
    my $doc = $ap->issue({%f});
    my $d = decode_json($doc);
    is_deeply($d->{disks}, [ sort @legs ], "$action: legs sorted");
    is($d->{pool}, 'vm1-disk0', "$action: pool is the mirror name");
    like($doc, qr/^\{"action":"\Q$action\E","disks":\["iscsi:[^"]+","local:lab\/enc\/vm\/vm1-disk0"\],"expires":1800003600,"hmac":"[0-9a-f]{64}","issued_by":"tester","mac":"aabbccddeeff","pool":"vm1-disk0","wipe":[01]\}$/, "$action: canonical form");
    is($ap->get('aabbccddeeff', $action, 'vm1-disk0'), $doc, "$action: stored under approval_${action}_<mirror>");
    is($ap->verify($doc, $secret)->{action}, $action, "$action: verifies");
    (my $t = $doc) =~ s/vm1-disk0","wipe/vm2-disk0","wipe/;
    is(err_of(sub { $ap->verify($t, $secret) })->kind, 'tampered', "$action: changed mirror refused");
    (my $t2 = $doc) =~ s/local:lab/local:xxx/;
    is(err_of(sub { $ap->verify($t2, $secret) })->kind, 'tampered', "$action: changed leg refused");
    is(err_of(sub { $ap->verify($doc, $secret, now => $now + 3600) })->kind, 'expired', "$action: expires");
    is(err_of(sub { $ap->issue({ %f, disks => [ $legs[0] ] }) })->kind, 'usage', "$action: one leg refused");
    is(err_of(sub { $ap->issue({ %f, disks => [ $legs[0], 'ata-DISK-A' ] }) })->kind, 'usage', "$action: a disk id is not a leg");
    is(err_of(sub { $ap->issue({ %f, disks => [ $legs[0], 'local:../x y' ] }) })->kind, 'usage', "$action: bad leg characters");
    ok($ap->revoke('aabbccddeeff', $action, 'vm1-disk0'), "$action: revoke");
}

# pool-create still takes disk ids and refuses leg specs
is(err_of(sub { $ap->issue({ action => 'pool-create', mac => 'aabbccddeeff', pool => 'lab', disks => [ 'local:x/y' ] }) })->kind,
   'usage', 'pool-create still refuses a leg spec');

# fixtures, for the Bash verifier
(my $sec = slurp("$Bin/fixtures/approval-canonical.secret.hex")) =~ s/\s+\z//;
for my $action (qw(peer-gone mirror-create)) {
    my $fx = "$Bin/fixtures/approval-$action";
    my $payload = slurp("$fx.json");
    (my $hex = slurp("$fx.hmac")) =~ s/\s+\z//;
    is(HPS::Approval::canonical({ action => $action, mac => 'aa:bb:cc:dd:ee:ff', pool => 'vm1-disk0',
        disks => [ reverse @legs ], wipe => ($action eq 'mirror-create' ? 1 : 0),
        expires => 4102444800, issued_by => 'operator' }), $payload, "$action fixture payload is canonical()");
    is(hmac_sha256_hex($payload, pack 'H*', $sec), $hex, "$action fixture hmac");
    my $fdoc = $payload =~ s/"issued_by"/"hmac":"$hex","issued_by"/r;
    ok(HPS::Approval->verify($fdoc, pack('H*', $sec), now => 1800000000), "$action fixture document verifies");
}

done_testing;
