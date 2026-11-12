#!/usr/bin/env perl
# hps-pin-fetch / HPS::PinFetch: an IPS pulls a pin from an image builder's
# read-only HTTP server and publishes it only once every file reads back from
# its own disk with the listed sha256 (docs/BUILDER.md, IPS-33 #3, #3b).
# The HTTP fetch and the O_DIRECT reads are injected: the "builder" is a
# directory, a URL maps to a file in it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Copy ();
use Digest::SHA;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Pins;
use HPS::PinFetch;

my $BIN  = "$Bin/../bin/hps-pin-fetch";
my $FROM = 'http://10.99.1.50:8090';
my $PIN  = 'nixos-26.05-20261112-0123456-abcdef0';
my $LAYER = 'firmware/0123456789abcdefghijklmnopqrstuv-hps-firmware-layer.cpio';

sub spit { my ($f, $t) = @_; open(my $fh, '>:raw', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub sha { Digest::SHA::sha256_hex($_[0]) }
sub sha_file { my $d = Digest::SHA->new(256); $d->addfile($_[0], 'b'); $d->hexdigest }

# builder_out($dir): a builder out/ tree as nix/build.sh leaves it: two
# profiles (one with the firmware layer), ipxe, SHA256SUMS.
sub builder_out {
    my ($dir, %o) = @_;
    my $p = "$dir/$PIN";
    my $sums = '';
    make_path("$dir/firmware");
    spit("$dir/$LAYER", 'layer-bytes');
    for my $prof (qw(audit node-builder)) {
        make_path("$p/$prof");
        spit("$p/$prof/bzImage", "kernel-$prof");
        spit("$p/$prof/initrd", "initrd-$prof");
        my $b = { init => "/nix/store/x-$prof/init", sha256 => { bzImage => sha("kernel-$prof"), initrd => sha("initrd-$prof") },
            size => { bzImage => length("kernel-$prof"), initrd => length("initrd-$prof") } };
        $b->{extra_initrds} = [ { path => $LAYER, sha256 => sha('layer-bytes'), size => 11 } ] if $prof eq 'audit';
        spit("$p/$prof/boot.json", JSON::PP->new->canonical->encode($b));
        $sums .= sha("kernel-$prof") . "  $prof/bzImage\n" . sha("initrd-$prof") . "  $prof/initrd\n";
    }
    $sums .= sha('layer-bytes') . "  ../$LAYER\n";
    make_path("$p/ipxe");
    spit("$p/ipxe/snponly.efi", 'snp');
    spit("$p/ipxe/ipxe.json", JSON::PP->new->canonical->encode({ version => '2', files => ['snponly.efi'], sha256 => { 'snponly.efi' => sha('snp') }, size => { 'snponly.efi' => 3 } }));
    $sums .= sha('snp') . "  ipxe/snponly.efi\n";
    spit("$p/SHA256SUMS", $o{sums} // $sums);
    return $dir;
}

# world(%o): {out, res, fetcher, calls}. bad => {url => n}: the first n
# fetches of that URL write zeros of the same length (a bad copy), so the
# O_DIRECT read-back sees the wrong hash. A url in missing => {} fails.
sub world {
    my (%o) = @_;
    my $base = tempdir(CLEANUP => 1);
    my $out  = builder_out("$base/out", %o);
    my $res  = "$base/res";
    make_path("$res/nixos");
    my %calls;
    my $fetch = sub {
        my ($url, $dest) = @_;
        $calls{$url}++;
        return 0 if $o{missing} && $o{missing}{$url};
        (my $rel = $url) =~ s{\A\Q$FROM\E/}{} or die "unexpected url $url";
        my $src = "$out/$rel";
        return 0 unless -f $src;
        if ($o{bad} && $o{bad}{$url} && $o{bad}{$url}-- > 0) {
            spit($dest, "\0" x -s $src);
            return 1;
        }
        File::Copy::copy($src, $dest) or die "copy $src: $!";
        return 1;
    };
    my $reg  = HPS::Registry->new(config_base => "$base/cfg", system_registry => "$base/cfg/system.db");
    my $pins = HPS::Pins->new(resources => $res, registry => $reg, logger => sub { });
    my @log;
    my $f = HPS::PinFetch->new(from => $FROM, resources => $res, pause => 0, fetch => $fetch,
        dsha => sub { -f $_[0] ? sha_file($_[0]) : undef }, dread => sub { -f $_[0] ? slurp($_[0]) : undef },
        pins => $pins, logger => sub { push @log, $_[0] }, now => sub { 1_800_000_000 });
    return { out => $out, res => $res, f => $f, calls => \%calls, log => \@log, pins => $pins, base => $base };
}

sub err_kind { my ($e) = @_; return ref $e && $e->can('kind') ? $e->kind : "not an error object: $e" }

# --- a clean fetch -------------------------------------------------------------

{
    my $w = world();
    my $r = $w->{f}->fetch_pin($PIN, latest => 1);
    is($r->{pin}, $PIN, 'fetch returns the pin');
    is($r->{files}, 6, 'six listed files (2 profiles x 2, the layer, one iPXE binary)');
    is($r->{fetched}, 6, 'all six fetched');
    is($r->{latest}, 1, 'latest requested and set');
    my $n = "$w->{res}/nixos";
    for my $rel (qw(audit/bzImage audit/initrd audit/boot.json node-builder/initrd node-builder/boot.json ipxe/snponly.efi ipxe/ipxe.json SHA256SUMS)) {
        is(sha_file("$n/$PIN/$rel"), sha_file("$w->{out}/$PIN/$rel"), "$rel published as the builder has it");
    }
    is(slurp("$n/$LAYER"), 'layer-bytes', 'the firmware layer goes to nixos/firmware/, shared');
    ok($w->{pins}->verify_pin($PIN)->{ok}, 'the published pin verifies');
    is(slurp("$n/latest"), "$PIN\n", 'latest names the pin');
    my @left = grep { /\.fetch-|\.failed-/ } map { s{.*/}{}r } glob("$n/.*");
    is_deeply(\@left, [], 'no staging or failed directory left behind');
}

# --- a bad copy is fetched again; the pin only appears once proved -------------

{
    my $w = world(bad => { "$FROM/$PIN/audit/initrd" => 2 });
    my $r = $w->{f}->fetch_pin($PIN);
    is($w->{calls}{"$FROM/$PIN/audit/initrd"}, 3, 'a copy that reads back wrong is fetched again (two bad, the third good)');
    is(sha_file("$w->{res}/nixos/$PIN/audit/initrd"), sha('initrd-audit'), 'the published initrd is the good one');
    is($r->{latest}, 0, 'latest is not set unless asked');
    ok(!-e "$w->{res}/nixos/latest", 'no latest written');
    ok(scalar(grep { /audit\/initrd reads back/ } @{ $w->{log} }), 'the bad read-back is logged');
}

{
    my $w = world(bad => { "$FROM/$PIN/node-builder/bzImage" => 5 });
    my $ok = eval { $w->{f}->fetch_pin($PIN, latest => 1); 1 };
    ok(!$ok, 'a file that never reads back right fails the fetch');
    is(err_kind($@), 'failed', '... as failed (exit 1)');
    is($w->{calls}{"$FROM/$PIN/node-builder/bzImage"}, 3, '... after three tries');
    ok(!-e "$w->{res}/nixos/$PIN", 'the pin never appears under its name');
    ok(!-e "$w->{res}/nixos/latest", 'latest is untouched');
    is_deeply([ grep { /\.fetch-/ } map { s{.*/}{}r } glob("$w->{res}/nixos/.*") ], [], 'the staging directory is removed');
}

# --- a copy that goes bad after publishing is caught by the second proof -----

{
    my $w = world();
    my $n = "$w->{res}/nixos";
    my $reads = 0;
    # dsha: the first read of the published audit/bzImage (after the rename)
    # sees other bytes, as the busy lab disk did; later reads are good.
    my $f = HPS::PinFetch->new(from => $FROM, resources => $w->{res}, pause => 0, fetch => $w->{f}{fetch},
        dread => $w->{f}{dread}, pins => $w->{pins}, logger => sub { push @{ $w->{log} }, $_[0] },
        dsha => sub {
            my ($file) = @_;
            return undef unless -f $file;
            return '0' x 64 if $file eq "$n/$PIN/audit/bzImage" && $reads++ == 0;
            return sha_file($file);
        });
    my $r = $f->fetch_pin($PIN);
    is($w->{calls}{"$FROM/$PIN/audit/bzImage"}, 2, 'a published file that reads back wrong in place is fetched again');
    ok($w->{pins}->verify_pin($PIN)->{ok}, 'and the pin verifies');
    ok(scalar(grep { /reads back differently after publishing/ } @{ $w->{log} }), 'logged');
}

{
    my $w = world();
    my $n = "$w->{res}/nixos";
    my $f = HPS::PinFetch->new(from => $FROM, resources => $w->{res}, pause => 0, fetch => $w->{f}{fetch},
        dread => $w->{f}{dread}, pins => $w->{pins}, logger => sub { }, now => sub { 1_800_000_000 },
        dsha => sub {
            my ($file) = @_;
            return undef unless -f $file;
            return '0' x 64 if $file eq "$n/$PIN/node-builder/initrd";
            return sha_file($file);
        });
    my $ok = eval { $f->fetch_pin($PIN, latest => 1); 1 };
    ok(!$ok, 'a published file that never reads back right in place fails');
    ok(!-e "$n/$PIN", 'the pin is not left under its name');
    ok(-d "$n/.failed-$PIN-20270115T080000Z", 'it is moved aside to .failed-<pin>-<time>');
    ok(!-e "$n/latest", 'latest is untouched');
}

# --- the builder's files must agree --------------------------------------------

{
    my $w = world();
    my $bj = "$w->{out}/$PIN/node-builder/boot.json";
    my $b = decode_json(slurp($bj));
    $b->{sha256}{initrd} = sha('something else');
    spit($bj, encode_json($b));
    my $ok = eval { $w->{f}->fetch_pin($PIN); 1 };
    ok(!$ok, 'boot.json and SHA256SUMS disagreeing is refused');
    is(err_kind($@), 'refused', '... as refused (exit 3)');
    like($@->message, qr{node-builder/initrd: boot\.json says}, '... naming the file');
    ok(!exists $w->{calls}{"$FROM/$PIN/node-builder/initrd"}, 'before any image file is fetched');
    ok(!-e "$w->{res}/nixos/$PIN", 'nothing published');
}

{
    my $w = world(sums => sha('x') . "  ../../etc/passwd\n");
    my $ok = eval { $w->{f}->fetch_pin($PIN); 1 };
    ok(!$ok, 'a SHA256SUMS path outside the pin and firmware/ is refused');
    is(err_kind($@), 'refused', '... as refused');
}

{
    my $w = world();
    my $bj = "$w->{out}/$PIN/audit/boot.json";
    my $b = decode_json(slurp($bj));
    $b->{extra_initrds}[0]{sha256} = sha('other layer');
    spit($bj, encode_json($b));
    my $ok = eval { $w->{f}->fetch_pin($PIN); 1 };
    ok(!$ok, 'an extra initrd whose hash disagrees with SHA256SUMS is refused');
    is(err_kind($@), 'refused', '... as refused');
}

{
    my $w = world(missing => { "$FROM/$PIN/SHA256SUMS" => 1 });
    my $ok = eval { $w->{f}->fetch_pin($PIN); 1 };
    ok(!$ok, 'no SHA256SUMS on the builder');
    is(err_kind($@), 'notfound', '... is not found (exit 4)');
}

# --- layers and pins already here ----------------------------------------------

{
    my $w = world();
    make_path("$w->{res}/nixos/firmware");
    spit("$w->{res}/nixos/$LAYER", 'layer-bytes');
    my $r = $w->{f}->fetch_pin($PIN);
    is($r->{reused}, 1, 'a layer already published with the same content is kept');
    ok(!exists $w->{calls}{"$FROM/$LAYER"}, '... and not fetched');
}

{
    my $w = world();
    $w->{f}->fetch_pin($PIN);
    my %before = %{ $w->{calls} };
    my $r = $w->{f}->fetch_pin($PIN, latest => 1);
    is($r->{already}, 1, 'a pin published already with the same SHA256SUMS is accepted');
    is($r->{fetched}, 0, '... without fetching its files again');
    is($w->{calls}{"$FROM/$PIN/audit/initrd"}, $before{"$FROM/$PIN/audit/initrd"}, '... (no image file fetched)');
    is(slurp("$w->{res}/nixos/latest"), "$PIN\n", '... and latest can be set');

    spit("$w->{out}/$PIN/SHA256SUMS", slurp("$w->{out}/$PIN/SHA256SUMS") . sha('z') . "  audit/extra\n");
    my $ok = eval { $w->{f}->fetch_pin($PIN); 1 };
    ok(!$ok, 'a pin published with other content is refused');
    is(err_kind($@), 'refused', '... as refused');
}

# --- arguments -------------------------------------------------------------------

for my $bad ('https://b:8090', 'http://b:8090/out', 'b:8090', 'http://b;rm:1') {
    my $ok = eval { HPS::PinFetch->new(from => $bad, resources => '/nonexistent'); 1 };
    ok(!$ok && err_kind($@) eq 'usage', "--from $bad refused as usage");
}
{
    my $w = world();
    for my $bad ('../x', 'Nixos', '') {
        my $ok = eval { $w->{f}->fetch_pin($bad); 1 };
        ok(!$ok && err_kind($@) eq 'usage', "pin '$bad' refused as usage");
    }
    my $ok = eval { HPS::PinFetch->new(from => $FROM, rate => '40 m'); 1 };
    ok(!$ok && err_kind($@) eq 'usage', 'a malformed --rate is usage');
}

# --- the CLI ---------------------------------------------------------------------

{
    my $out = qx{perl "$BIN" --help 2>&1};
    is($? >> 8, 0, '--help exits 0');
    like($out, qr/FETCHED <PIN> files=/, '--help names the last line');
    qx{perl "$BIN" --pin $PIN 2>&1};
    is($? >> 8, 2, 'without --from: usage (2)');
    my $res = tempdir(CLEANUP => 1);
    make_path("$res/nixos");
    my $o = qx{perl "$BIN" --from http://127.0.0.1:9 --pin $PIN --resources "$res" --tries 1 --pause 0 2>&1};
    is($? >> 8, 4, 'a builder that does not answer: not found (4)');
    like($o, qr/SHA256SUMS could not be fetched/, '... saying what was missing');
}

# --- the default O_DIRECT reader -------------------------------------------------

{
    my $d = tempdir(CLEANUP => 1);
    spit("$d/f", 'direct bytes');
    is(HPS::PinFetch::_direct_sha256("$d/f"), sha('direct bytes'), 'the dd iflag=direct reader hashes the file');
    is(HPS::PinFetch::_direct_read("$d/f"), 'direct bytes', 'the dd iflag=direct reader returns its content');
    is(HPS::PinFetch::_direct_sha256("$d/none"), undef, 'a missing file gives no hash');
}

done_testing;
