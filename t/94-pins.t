#!/usr/bin/env perl
# IPS-05: HPS::Pins list, verify, prune, delete and the references that protect.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Pins;

my $NOW = 1_800_000_000;
my $base = tempdir(CLEANUP => 1);
my $res  = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

sub spit { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub sha { Digest::SHA::sha256_hex($_[0]) }

# make_pin($name, $built_at, hashes => 1|0, profiles => [...]): real files, boot.json
# with sha256/size, SHA256SUMS, like nix/build.sh writes.
sub make_pin {
    my ($pin, $built, %o) = @_;
    my @profiles = @{ $o{profiles} // [qw(audit node-base)] };
    my @sums;
    for my $p (@profiles) {
        make_path("$res/nixos/$pin/$p");
        my %c = (bzImage => "kernel-$pin-$p", initrd => "initrd-$pin-$p");
        spit("$res/nixos/$pin/$p/$_", $c{$_}) for keys %c;
        my %b = (built_at => $built, pin => $pin, profile => $p, init => '/x');
        if ($o{hashes} // 1) {
            $b{sha256} = { map { $_ => sha($c{$_}) } keys %c };
            $b{size}   = { map { $_ => length $c{$_} } keys %c };
            push @sums, sha($c{bzImage}) . "  $p/bzImage\n", sha($c{initrd}) . "  $p/initrd\n";
        }
        spit("$res/nixos/$pin/$p/boot.json", JSON::PP->new->canonical->encode(\%b));
    }
    spit("$res/nixos/$pin/SHA256SUMS", join '', @sums) if @sums;
}

make_pin('pin-a', '2026-11-01T00:00:00Z');
make_pin('pin-b', '2026-11-02T00:00:00Z');
make_pin('pin-c', '2026-11-03T00:00:00Z');
make_pin('pin-d', '2026-11-04T00:00:00Z');
make_pin('pin-e', '2026-11-05T00:00:00Z');   # latest
make_pin('pin-legacy', '2026-10-01T00:00:00Z', hashes => 0);
spit("$res/nixos/latest", "pin-e\n");

my $h1 = '52:54:00:00:00:01';
my $h2 = '52:54:00:00:00:02';
my $h3 = '52:54:00:00:00:03';
$reg->host_set($h1, 'system_pin', 'pin-a');
$reg->host_set($h2, 'system_pin', 'pin-d');
$reg->host_set($h2, 'system_pin_previous', 'pin-c');
$reg->host_set($h3, 'STATE', 'HELD');
my @log;
sub mk { HPS::Pins->new(registry => $reg, resources => $res, now => sub { $NOW }, logger => sub { push @log, "@_" }, @_) }
sub err_of { my ($c) = @_; eval { $c->(); 1 } and return; my $e = $@; return ref $e ? $e : undef }

# --- list
{
    my @rows = mk()->list;
    is_deeply([ map { $_->{pin} } @rows ], [qw(pin-e pin-d pin-c pin-b pin-a pin-legacy)], 'list: newest first');
    my %by = map { $_->{pin} => $_ } @rows;
    is($by{'pin-e'}{latest}, 1, 'latest marked');
    is($by{'pin-d'}{latest}, 0, 'others not latest');
    is_deeply($by{'pin-a'}{hosts}, ['525400000001'], 'hosts pinned');
    is_deeply($by{'pin-c'}{hosts}, ['525400000002'], 'previous pin counts as pinned');
    is_deeply($by{'pin-b'}{hosts}, [], 'no hosts');
    is_deeply($by{'pin-a'}{profiles}, [qw(audit node-base)], 'profiles');
    my $want = 0;
    $want += -s $_ for glob("$res/nixos/pin-a/*/*");
    is($by{'pin-a'}{size}, $want, 'size sums every file');
    is($by{'pin-a'}{date}, '2026-11-01T00:00:00Z', 'date from built_at');
}

# --- verify
{
    my $p = mk();
    my $r = $p->verify_pin('pin-a');
    ok($r->{ok}, 'intact pin verifies');
    is_deeply($r->{unverified}, [], 'nothing unverified');
    $r = $p->verify_pin('pin-legacy');
    ok($r->{ok}, 'legacy pin (no hashes) does not fail');
    is_deeply($r->{unverified}, [qw(audit/bzImage audit/initrd node-base/bzImage node-base/initrd)], 'legacy pin reported unverified');

    # truncated initrd: size mismatch names the file
    my $f = "$res/nixos/pin-b/audit/initrd";
    my $orig = slurp($f);
    spit($f, substr($orig, 0, 5));
    $r = $p->verify_pin('pin-b');
    ok(!$r->{ok}, 'truncated initrd fails');
    is_deeply([ map { $_->{file} } @{ $r->{failures} } ], ['audit/initrd'], 'FAIL names the file');
    like($r->{failures}[0]{reason}, qr/size 5/, 'reason is the size');
    # same length, other bytes: sha mismatch
    spit($f, 'X' x length $orig);
    $r = $p->verify_pin('pin-b');
    like($r->{failures}[0]{reason}, qr/sha256/, 'same-size damage is a sha256 failure');
    # zeroed like the disk-full damage
    spit($f, "\0" x length $orig);
    ok(!$p->verify_pin('pin-b')->{ok}, 'zeroed file fails');
    spit($f, $orig);
    ok($p->verify_pin('pin-b')->{ok}, 'restored file verifies again');

    # missing file; bad kernel
    unlink "$res/nixos/pin-b/node-base/bzImage";
    $r = $p->verify_pin('pin-b');
    is_deeply([ map { "$_->{file}: $_->{reason}" } @{ $r->{failures} } ], ['node-base/bzImage: missing'], 'missing file named');
    spit("$res/nixos/pin-b/node-base/bzImage", 'kernel-pin-b-node-base');

    # SHA256SUMS alone catches damage when boot.json hashes are absent
    make_pin('pin-sums', '2026-11-06T00:00:00Z', profiles => ['audit']);
    my $bj = JSON::PP::decode_json(slurp("$res/nixos/pin-sums/audit/boot.json"));
    delete $bj->{sha256};
    delete $bj->{size};
    spit("$res/nixos/pin-sums/audit/boot.json", encode_json($bj));
    ok($p->verify_pin('pin-sums')->{ok}, 'SHA256SUMS alone verifies');
    spit("$res/nixos/pin-sums/audit/bzImage", 'damaged');
    my @n = map { $_->{file} } @{ $p->verify_pin('pin-sums')->{failures} };
    is_deeply(\@n, ['audit/bzImage'], 'SHA256SUMS catches damage');
    File::Path::remove_tree("$res/nixos/pin-sums");

    # bad boot.json
    make_pin('pin-badjson', '2026-11-07T00:00:00Z', profiles => ['audit']);
    spit("$res/nixos/pin-badjson/audit/boot.json", '{nope');
    $r = $p->verify_pin('pin-badjson');
    is($r->{failures}[0]{file}, 'audit/boot.json', 'unparseable boot.json fails, named');
    File::Path::remove_tree("$res/nixos/pin-badjson");

    my $e = err_of(sub { $p->verify_pin('pin-none') });
    is($e && $e->kind, 'notfound', 'missing pin: notfound');
    $e = err_of(sub { $p->verify_pin('../x') });
    is($e && $e->kind, 'usage', 'bad pin name: usage');
    my @all = $p->verify_all;
    is(scalar(grep { !$_->{ok} } @all), 0, 'verify_all: all intact now');
}

# --- delete refusals and success
{
    my $p = mk();
    @log = ();
    my %why = (
        'pin-e' => qr/latest/,
        'pin-a' => qr/system_pin of 525400000001/,
        'pin-d' => qr/system_pin of 525400000002/,
        'pin-c' => qr/system_pin_previous of 525400000002/,
    );
    for my $pin (sort keys %why) {
        my $e = err_of(sub { $p->delete($pin) });
        is($e && $e->kind, 'refused', "delete $pin refused");
        like($e->message, $why{$pin}, "  names the reason for $pin");
        ok(-d "$res/nixos/$pin", "  $pin still there");
    }
    my $e = err_of(sub { $p->delete('pin-missing') });
    is($e && $e->kind, 'notfound', 'delete missing pin');
    $e = err_of(sub { $p->delete('Bad/Pin') });
    is($e && $e->kind, 'usage', 'delete malformed name');

    $reg->cluster_set('lab', 'nixos_default_pin', 'pin-b');
    $e = err_of(sub { $p->delete('pin-b') });
    is($e && $e->kind, 'refused', 'cluster default protected');
    like($e->message, qr/nixos_default_pin/, '  names it');
    $reg->cluster_unset('lab', 'nixos_default_pin');

    # a host that booted 5 minutes ago resolves to the latest (no pin of its own)
    $reg->host_set($h3, 'last_boot_at', $NOW - 300);
    my $ref = $p->references;
    like(join(',', @{ $ref->{'pin-e'} }), qr/booting now: 525400000003/, 'recent boot protects the pin it is served');
    $reg->host_set($h3, 'last_boot_at', $NOW - 1000);
    unlike(join(',', @{ $p->references->{'pin-e'} }), qr/booting now/, 'a boot 1000 s ago does not');
    # booting host with a cluster default: that pin, not latest
    $reg->cluster_set('lab', 'nixos_default_pin', 'pin-b');
    $reg->host_set($h3, 'last_boot_at', $NOW - 10);
    like(join(',', @{ $p->references->{'pin-b'} }), qr/booting now: 525400000003/, 'booting host is served the cluster default');
    $reg->cluster_unset('lab', 'nixos_default_pin');
    $reg->host_unset($h3, 'last_boot_at');
    $reg->host_set($h3, 'last_boot_at', 'soon');
    ok(eval { $p->references; 1 }, 'a junk last_boot_at is ignored');
    $reg->host_unset($h3, 'last_boot_at');

    is(scalar(@log), 5, 'only the five refusals logged');
    like($log[0], qr/^warning delete of pin \S+ refused/, 'refusals are logged');

    @log = ();
    my $r = $p->delete('pin-b');
    is($r->{pin}, 'pin-b', 'delete of an unreferenced pin');
    ok(!-e "$res/nixos/pin-b", 'directory gone');
    is_deeply(\@log, ['info deleted pin pin-b (explicit delete; no host, cluster default or latest references it)'], 'delete logged with pin and reason');
    make_pin('pin-b', '2026-11-02T00:00:00Z');
}

# --- prune
{
    my $p = mk();
    @log = ();
    my $r = $p->prune(dry_run => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-legacy)], 'dry run: unreferenced and older than the newest one');
    is_deeply([ map { $_->{pin} } @{ $r->{kept} } ], [qw(pin-e pin-d pin-c pin-b pin-a)], 'kept: latest, hosts, and the newest unreferenced');
    ok(-d "$res/nixos/pin-legacy", 'dry run removes nothing');
    is_deeply(\@log, [], 'dry run logs nothing');

    $r = $p->prune(keep_previous => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-legacy)], 'prune keep 1 removes the older unreferenced pin');
    is(scalar(@log), 1, 'one log line per delete');
    like($log[0], qr/^info deleted pin pin-legacy \(unreferenced and older than the newest 1 unreferenced pin\)/, 'log has pin and reason');
    for my $keep (qw(pin-a pin-b pin-c pin-d pin-e)) { ok(-d "$res/nixos/$keep", "$keep survives") }
    ok(!-e "$res/nixos/pin-legacy", 'pin-legacy gone');

    # keep-previous counts only unreferenced pins
    make_pin('pin-f', '2026-11-08T00:00:00Z');
    make_pin('pin-g', '2026-11-09T00:00:00Z');
    make_pin('pin-h', '2026-10-15T00:00:00Z');
    $r = $p->prune(keep_previous => 2, dry_run => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-b pin-h)], 'keep 2: newest two unreferenced (g, f) kept');
    $r = $p->prune(keep_previous => 0, dry_run => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-g pin-f pin-b pin-h)], 'keep 0');

    my $e = err_of(sub { $p->prune(keep_previous => 'x') });
    is($e && $e->kind, 'usage', 'bad keep-previous');
    spit("$res/nixos/latest", "pin-gone\n");
    $e = err_of(sub { $p->prune });
    is($e && $e->kind, 'refused', 'latest naming a missing pin refuses');
    ok(-d "$res/nixos/pin-h", 'nothing removed on refusal');
    unlink "$res/nixos/latest";
    $e = err_of(sub { $p->prune });
    is($e && $e->kind, 'refused', 'no latest refuses');
    spit("$res/nixos/latest", "pin-e\n");
}

# --- unreadable registry: references unknown, so nothing is removed
{
    my $broken = HPS::Registry->new(config_base => "$base/nowhere", system_registry => "$base/nowhere/system.db");
    my $p = HPS::Pins->new(registry => $broken, resources => $res, logger => sub { });
    my $e = err_of(sub { $p->prune });
    is($e && $e->kind, 'failed', 'prune fails when the registry cannot be read');
    $e = err_of(sub { $p->delete('pin-h') });
    is($e && $e->kind, 'failed', 'delete fails when the registry cannot be read');
    ok(-d "$res/nixos/pin-h", 'nothing removed');
    ok(scalar(my @l = $p->list), 'list still works');
}

done_testing;
