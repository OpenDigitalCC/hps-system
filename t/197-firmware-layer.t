#!/usr/bin/env perl
# Firmware layers (nixos/firmware/<file>, named by a profile's boot.json
# extra_initrds): HPS::Pins verify, pin_names, prune and delete, and
# HPS::CnhPublish listing a layer once with the pins that name it.
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
use HPS::CnhPublish;

my $NOW = 1_800_000_000;
my $base = tempdir(CLEANUP => 1);
my $res  = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

sub spit { open(my $fh, '>:raw', $_[0]) or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub sha { Digest::SHA::sha256_hex($_[0]) }

my $L1 = ('1' x 32) . '-hps-firmware-layer-a.cpio';
my $L2 = ('2' x 32) . '-hps-firmware-layer-b.cpio';

# layer($name, $content, $age): a published layer file, $age seconds old.
sub layer {
    my ($name, $content, $age) = @_;
    make_path("$res/nixos/firmware");
    spit("$res/nixos/firmware/$name", $content);
    utime($NOW - $age, $NOW - $age, "$res/nixos/firmware/$name");
}

# make_pin($pin, $built_at, layer => name|undef, sums => 1): like nix/build.sh.
sub make_pin {
    my ($pin, $built, %o) = @_;
    my @sums;
    for my $p (qw(audit node-base)) {
        make_path("$res/nixos/$pin/$p");
        my %c = (bzImage => "kernel-$pin-$p", initrd => "initrd-$pin-$p");
        spit("$res/nixos/$pin/$p/$_", $c{$_}) for keys %c;
        my %b = (built_at => $built, pin => $pin, profile => $p, init => '/x',
            sha256 => { map { $_ => sha($c{$_}) } keys %c },
            size   => { map { $_ => length $c{$_} } keys %c });
        push @sums, sha($c{bzImage}) . "  $p/bzImage\n", sha($c{initrd}) . "  $p/initrd\n";
        if ($p eq 'audit' && $o{layer}) {
            my $f = "$res/nixos/firmware/$o{layer}";
            open(my $fh, '<:raw', $f) or die "$f: $!";
            my $t = do { local $/; <$fh> };
            close $fh;
            $b{extra_initrds} = [ { path => "firmware/$o{layer}", sha256 => sha($t), size => length $t } ];
            push @sums, sha($t) . "  ../firmware/$o{layer}\n" if $o{sums} // 1;
        }
        spit("$res/nixos/$pin/$p/boot.json", JSON::PP->new->canonical->encode(\%b));
    }
    spit("$res/nixos/$pin/SHA256SUMS", join '', @sums);
}

layer($L1, 'firmware-one', 7200);
layer($L2, 'firmware-two', 7200);
make_pin('pin-a', '2026-11-01T00:00:00Z', layer => $L1);
make_pin('pin-b', '2026-11-02T00:00:00Z', layer => $L1);
make_pin('pin-c', '2026-11-03T00:00:00Z', layer => $L2);
make_pin('pin-old', '2026-10-01T00:00:00Z');                 # before the layer
spit("$res/nixos/latest", "pin-c\n");

my @log;
sub mk { HPS::Pins->new(registry => $reg, resources => $res, now => sub { $NOW }, logger => sub { push @log, "@_" }, @_) }
sub fails { my ($r) = @_; return [ map { "$_->{file}: $_->{reason}" } @{ $r->{failures} } ] }

# --- the firmware directory is not a pin
{
    my $p = mk();
    is_deeply([ $p->pin_names ], [qw(pin-c pin-b pin-a pin-old)], 'firmware/ is not listed as a pin');
    is_deeply([ $p->layer_files ], [ $L1, $L2 ], 'layer files');
    is_deeply([ map { $_->{path} } @{ $p->layer_refs('pin-a') } ], ["firmware/$L1"], 'layer_refs of a pin');
    is_deeply($p->layer_refs('pin-old'), [], 'a pin before the layer names none');
}

# --- verify
{
    my $p = mk();
    for my $pin (qw(pin-a pin-b pin-c pin-old)) {
        my $r = $p->verify_pin($pin);
        ok($r->{ok}, "$pin verifies") or diag explain $r;
        is_deeply($r->{unverified}, [], "  nothing unverified in $pin");
    }
    # damage: size, then same-size bytes
    spit("$res/nixos/firmware/$L1", 'short');
    is_deeply(fails($p->verify_pin('pin-a')), ["firmware/$L1: size 5, boot.json says 12"], 'truncated layer: FAIL names it');
    spit("$res/nixos/firmware/$L1", 'X' x 12);
    like(fails($p->verify_pin('pin-b'))->[0], qr{^firmware/\Q$L1\E: sha256 [0-9a-f]{64}, expected}, 'same-size damage: sha256');
    unlink "$res/nixos/firmware/$L1";
    is_deeply(fails($p->verify_pin('pin-a')), ["firmware/$L1: missing"], 'missing layer');
    layer($L1, 'firmware-one', 7200);
    ok(mk()->verify_pin('pin-a')->{ok}, 'restored layer verifies');

    # SHA256SUMS alone (boot.json without a sha256) still verifies and catches damage
    make_pin('pin-sums', '2026-11-04T00:00:00Z', layer => $L2);
    my $f = "$res/nixos/pin-sums/audit/boot.json";
    my $b = decode_json(do { open(my $fh, '<', $f) or die; local $/; <$fh> });
    delete $b->{extra_initrds}[0]{sha256};
    spit($f, encode_json($b));
    ok(mk()->verify_pin('pin-sums')->{ok}, 'SHA256SUMS ../firmware line alone verifies');
    spit("$res/nixos/firmware/$L2", 'firmware-twX');
    ok(!mk()->verify_pin('pin-sums')->{ok}, 'and catches damage');
    layer($L2, 'firmware-two', 7200);
    # neither hash: unverified, not failed
    make_pin('pin-nohash', '2026-11-04T00:00:00Z', layer => $L2, sums => 0);
    $f = "$res/nixos/pin-nohash/audit/boot.json";
    $b = decode_json(do { open(my $fh, '<', $f) or die; local $/; <$fh> });
    delete $b->{extra_initrds}[0]{sha256};
    spit($f, encode_json($b));
    my $r = mk()->verify_pin('pin-nohash');
    ok($r->{ok}, 'a layer with no recorded hash does not fail');
    is_deeply($r->{unverified}, ["firmware/$L2"], '  it is reported unverified');

    # malformed entries
    for my $case ([ [ { path => '../pin-a/audit/initrd' } ], qr/is not firmware\/<file>/ ],
                  [ [ { path => 'firmware/a/b.cpio' } ],    qr/is not firmware\/<file>/ ],
                  [ [ {} ],                                 qr/\(none\) is not firmware/ ],
                  [ 'firmware/x.cpio',                      qr/extra_initrds is not a list/ ],
                  [ [ 'firmware/x.cpio' ],                  qr/extra_initrds is not a list/ ]) {
        $b->{extra_initrds} = $case->[0];
        spit($f, encode_json($b));
        my $v = mk()->verify_pin('pin-nohash');
        ok(!$v->{ok}, 'malformed extra_initrds fails');
        like(fails($v)->[0], qr{^audit/boot\.json: .*$case->[1]}, '  named on boot.json');
    }
    File::Path::remove_tree("$res/nixos/pin-sums", "$res/nixos/pin-nohash");
}

# --- the layer is hashed once per object, not once per pin
{
    my $p = mk();
    my $calls = 0;
    no warnings 'redefine';
    my $orig = \&HPS::Pins::_sha256_file;
    local *HPS::Pins::_sha256_file = sub { $calls++ if $_[0] =~ /\.cpio\z/; $orig->(@_) };
    $p->verify_all;
    is($calls, 2, 'verify_all hashes each of the two layers once');
}

# --- prune: layers follow the pins that are kept
{
    my $p = mk();
    @log = ();
    my $r = $p->prune(keep_previous => 0, dry_run => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-b pin-a pin-old)], 'dry run: pins');
    is_deeply([ map { $_->{file} } @{ $r->{layers_removed} } ], ["firmware/$L1"], 'dry run: the layer only removed pins name');
    is_deeply([ map { "$_->{file} ($_->{why})" } @{ $r->{layers_kept} } ], ["firmware/$L2 (named by pin-c)"], '  the latest pin keeps its layer');
    ok(-f "$res/nixos/firmware/$L1", 'dry run removes nothing');
    is_deeply(\@log, [], 'dry run logs nothing');

    # keep 1 previous: pin-b (layer 1) stays, so does layer 1
    $r = $p->prune(keep_previous => 1, dry_run => 1);
    is_deeply($r->{layers_removed}, [], 'a kept previous pin keeps layer 1');
    # a host pinned to the oldest pin with layer 1 keeps it too
    $reg->host_set('52:54:00:00:00:01', 'system_pin', 'pin-a');
    $r = $p->prune(keep_previous => 0, dry_run => 1);
    is_deeply([ map { $_->{pin} } @{ $r->{removed} } ], [qw(pin-b pin-old)], 'host keeps pin-a');
    is_deeply([ map { "$_->{file} ($_->{why})" } @{ $r->{layers_kept} } ],
        ["firmware/$L1 (named by pin-a)", "firmware/$L2 (named by pin-c)"], 'and layer 1 with it');
    $reg->host_unset('52:54:00:00:00:01', 'system_pin');

    # a new, unnamed layer within the grace period is kept
    my $L3 = ('3' x 32) . '-hps-firmware-layer-c.cpio';
    layer($L3, 'firmware-three', 60);
    spit("$res/nixos/firmware/.$L3.tmp", 'partial');
    $r = $p->prune(keep_previous => 0);
    is_deeply([ map { $_->{file} } @{ $r->{layers_removed} } ], ["firmware/$L1"], 'prune removes layer 1');
    ok(!-e "$res/nixos/firmware/$L1", '  gone');
    ok(-f "$res/nixos/firmware/$L2", 'layer 2 stays');
    ok(-f "$res/nixos/firmware/$L3", 'a just-written layer stays');
    ok(-f "$res/nixos/firmware/.$L3.tmp", 'a temporary file is never touched');
    like(join("\n", @log), qr{info deleted firmware layer firmware/\Q$L1\E \(no pin names it\)}, 'layer delete logged');
    like(join(',', map { $_->{why} } @{ $r->{layers_kept} }), qr/written within the last 3600 s/, 'grace reason given');
    is_deeply([ mk()->pin_names ], ['pin-c'], 'only the latest pin is left');
    ok(mk()->verify_pin('pin-c')->{ok}, 'it still verifies');
    unlink "$res/nixos/firmware/$L3", "$res/nixos/firmware/.$L3.tmp";
}

# --- delete: removes the layers no remaining pin names
{
    make_pin('pin-d', '2026-11-05T00:00:00Z', layer => $L2);
    layer($L1, 'firmware-one', 7200);
    make_pin('pin-e', '2026-11-06T00:00:00Z', layer => $L1);
    spit("$res/nixos/latest", "pin-d\n");
    my $p = mk();
    my $r = $p->delete('pin-c');
    is_deeply($r->{layers_removed}, [], 'pin-d still names layer 2: nothing removed with pin-c');
    $r = $p->delete('pin-e');
    is_deeply([ map { $_->{file} } @{ $r->{layers_removed} } ], ["firmware/$L1"], 'deleting the last pin naming layer 1 removes it');
    ok(-f "$res/nixos/firmware/$L2", 'layer 2 stays');
}

# --- CnhPublish lists the layer with its pins, once
{
    layer($L1, 'firmware-one', 7200);
    make_pin('pin-f', '2026-11-07T00:00:00Z', layer => $L2);
    make_pin('pin-g', '2026-11-08T00:00:00Z', layer => $L1);
    my $c = HPS::CnhPublish->new(resources => $res, registry => $reg, now => sub { $NOW });
    my @e = $c->pin_entries('pin-d');
    my ($fw) = grep { $_->{url} =~ m{^nixos/firmware/} } @e;
    ok($fw, 'pin entries include the layer the pin names');
    is($fw->{url}, "nixos/firmware/$L2", '  url under nixos/');
    is($fw->{path}, "srv/hps-resources/nixos/firmware/$L2", '  path under the CNH resources');
    is($fw->{sha256}, sha('firmware-two'), '  sha256');
    is(scalar(grep { $_->{url} =~ m{^nixos/pin-d/} } @e), 7, '  and every file of the pin (2 profiles x 3, SHA256SUMS)');

    # a shared layer is listed once in the manifest
    my $sys = tempdir(DIR => $base);
    make_path("$sys/scripts");
    spit("$sys/scripts/run-hps.sh", "#!/bin/bash\n");
    make_path("$res/packages/ctrl-exec");
    spit("$res/packages/ctrl-exec/ctrl-exec-latest.tar.gz", 'tarball');
    spit("$res/packages/ctrl-exec/ctrl-exec-api-plugins-latest.deb", 'plugins');
    $c = HPS::CnhPublish->new(resources => $res, system => $sys, registry => $reg, now => sub { $NOW });
    my $m = $c->publish(pins => [qw(pin-d pin-f pin-g)]);
    my $doc = decode_json(do { open(my $fh, '<', $m->{manifest}) or die; local $/; <$fh> });
    my @fw = sort map { $_->{url} } grep { $_->{url} =~ m{^nixos/firmware/} } @{ $doc->{files} };
    is_deeply(\@fw, [ "nixos/firmware/$L1", "nixos/firmware/$L2" ], 'manifest lists each layer once');

    # a damaged layer refuses the pin
    spit("$res/nixos/firmware/$L2", 'firmware-twX');
    my $err = eval { $c->pin_entries('pin-d'); 1 } ? undef : $@;
    is(ref $err && $err->kind, 'refused', 'a pin whose layer fails verification is refused');
}

done_testing;
