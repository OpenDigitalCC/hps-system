#!/usr/bin/env perl
# hps-starter / HPS::Starter: the IPS holds a stock starter and a package
# repository per OS as plain files, filled from upstream (docs/STARTER.md).
# No network: "upstream" is a directory fixture read through curl's file://
# (Hydra's job answer and downloads, the release's store-paths list, a Nix
# binary cache with two systems), so the real fetch code runs.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Digest::SHA;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Starter;

my $BIN = "$Bin/../bin/hps-starter";

sub spit { my ($f, $t) = @_; make_path(File::Basename::dirname($f)); open(my $fh, '>:raw', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub sha { Digest::SHA::sha256_hex($_[0]) }
sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

# A store hash: 32 characters of Nix's alphabet, made from a seed.
sub h { return substr(HPS::Starter::nix32(Digest::SHA::sha256($_[0])), 0, 32) }

is(HPS::Starter::nix32(pack('H*', Digest::SHA::sha256_hex(''))), '0mdqa9w1p6cmli6976v4wi0sw9r4p5prkj7lzfd1877wk11c9c73',
    'nix base-32 of the sha256 of nothing (checked against real narinfo FileHash values)');

my $REL = '26.05.111.abc1234';
my $INIT = '/nix/store/' . h('sys') . "-nixos-system-nixos-kexec-$REL/init";
my $KERNEL = 'kernel-bytes-' . ('k' x 100);
my $INITRD = 'initrd-bytes-' . ('i' x 500);
my $CMDLINE = "init=$INIT initrd=initrd nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf";

# store(): the fake binary cache. Each package exists for two systems: the x86
# one refers to the x86 glibc, the other to the other glibc.
sub fixture {
    my ($up, %o) = @_;
    my %ni;    # hash => {name, refs => [hash]}
    my $add = sub { my ($seed, $name, @refs) = @_; $ni{ h($seed) } = { name => $name, refs => [ map { h($_) } @refs ] }; h($seed) };
    $add->('glibc-x', 'glibc-2.42-103');
    $add->('glibc-a', 'glibc-2.42-103');
    $add->('sys', "nixos-system-nixos-kexec-$REL", 'glibc-x');
    $add->('libfoo-x', 'libfoo-1.0', 'glibc-x');
    $add->('libfoo-a', 'libfoo-1.0', 'glibc-a');
    $add->('libvirt-x', 'libvirt-12.2.0', 'glibc-x', 'libfoo-x');
    $add->('libvirt-a', 'libvirt-12.2.0', 'glibc-a', 'libfoo-a');
    $add->('perl-x', 'perl-5.42.3', 'glibc-x');
    $add->('perl-a', 'perl-5.42.3', 'glibc-a');
    $add->('perl-x-man', 'perl-5.42.3-man');
    my @sp = map { "/nix/store/$_-$ni{$_}{name}" } sort keys %ni;
    push @sp, '/nix/store/' . h('py') . '-python3.13-libvirt-12.2.0';
    spit("$up/releases/nixos/26.05/nixos-$REL/store-paths.xz", join("\n", @sp) . "\n");
    for my $k (keys %ni) {
        my $nar = "nar-of-$ni{$k}{name}-$k";
        my $fh = HPS::Starter::nix32(Digest::SHA::sha256($nar));
        spit("$up/cache/nar/$fh.nar.xz", $nar);
        my $refs = join ' ', map { "$_-$ni{$_}{name}" } @{ $ni{$k}{refs} };
        spit("$up/cache/$k.narinfo", "StorePath: /nix/store/$k-$ni{$k}{name}\nURL: nar/$fh.nar.xz\nCompression: xz\n"
            . "FileHash: sha256:$fh\nFileSize: " . length($nar) . "\nNarHash: sha256:x\nNarSize: 9\nReferences: $refs\nSig: cache.nixos.org-1:sig-$k\n");
    }
    my $hy = "$up/hydra";
    spit("$hy/build/100/download/1/bzImage", $KERNEL);
    spit("$hy/build/100/download/2/initrd", $INITRD);
    my $ipxe = "#!ipxe\n# comment\nkernel bzImage $CMDLINE \${cmdline}\ninitrd initrd\nboot\n";
    spit("$hy/build/100/download/3/netboot.ipxe", $ipxe);
    my $prod = sub { my ($n, $name, $body) = @_; ($n => { name => $name, filesize => length($body), sha256hash => sha($body) }) };
    spit("$hy/job/nixos/release-26.05/nixos.netboot.x86_64-linux/latest-finished", encode_json({
        id => 100, buildstatus => 0, job => 'nixos.netboot.x86_64-linux',
        buildproducts => { $prod->(1, 'bzImage', $KERNEL), $prod->(2, 'initrd', $INITRD), $prod->(3, 'netboot.ipxe', $ipxe) },
    }));
    return \%ni;
}

sub world {
    my $root = tempdir(CLEANUP => 1);
    my $up = "$root/up";
    my $ni = fixture($up);
    spit("$root/pk", "# the list\nlibvirt\nperl   # the interpreter\n");
    my %o = (resources => "$root/res", hydra => "file://$up/hydra", releases => "file://$up/releases", cache => "file://$up/cache", packages => "$root/pk", logger => sub { });
    return { root => $root, up => $up, ni => $ni, o => \%o, new => sub { HPS::Starter->new(%o, @_) } };
}

# --- the first sync ---------------------------------------------------------
my $w = world();
my $r = $w->{new}->()->sync('nixos');
is($r->{release}, $REL, 'release identity read from the stock init path');
is($r->{starter}{fetched}, 3, 'starter: kernel, initramfs and netboot.ipxe fetched');
my $sd = "$w->{root}/res/starter/nixos/26.05";
is(slurp("$sd/bzImage"), $KERNEL, 'kernel is the upstream file, unmodified');
is(slurp("$sd/initrd"), $INITRD, 'initramfs is the upstream file, unmodified');
my $sm = decode_json(slurp("$sd/manifest.json"));
is($sm->{release}, $REL, 'starter manifest: release');
is($sm->{cmdline}, $CMDLINE, 'starter manifest: the stock kernel arguments, without ${cmdline}');
is($sm->{init}, $INIT, 'starter manifest: init path');
is($sm->{files}{initrd}{sha256}, sha($INITRD), 'starter manifest: sha256 per file');
is($sm->{files}{initrd}{size}, length($INITRD), 'starter manifest: size per file');
like($sm->{files}{initrd}{url}, qr{/build/100/download/2/initrd\z}, 'starter manifest: upstream URL per file');
ok(!glob("$sd/.*.tmp-*"), 'no temporary file is left behind');

my $rd = "$w->{root}/res/packages/nixos/26.05";
my $rm = decode_json(slurp("$rd/manifest.json"));
is($rm->{roots}{libvirt}, '/nix/store/' . h('libvirt-x') . '-libvirt-12.2.0', 'libvirt resolves to the x86_64 store path');
is($rm->{roots}{perl}, '/nix/store/' . h('perl-x') . '-perl-5.42.3', 'perl resolves to the x86_64 store path, not its man output');
is($rm->{paths}, 4, 'closure: libvirt, libfoo, perl, glibc and nothing of the other system');
ok(-f "$rd/" . h('libvirt-x') . '.narinfo', 'narinfo of a root is held');
ok(-f "$rd/" . h('glibc-x') . '.narinfo', 'narinfo of a dependency is held');
ok(!-e "$rd/" . h('libvirt-a') . '.narinfo', 'narinfo of the other system is not held');
like(slurp("$rd/" . h('perl-x') . '.narinfo'), qr/^Sig: cache\.nixos\.org-1:sig-/m, 'narinfo is kept as published, signature included');
like(slurp("$rd/nix-cache-info"), qr/^StoreDir: \/nix\/store$/m, 'nix-cache-info');
is($rm->{files}{ 'nar/' . HPS::Starter::nix32(Digest::SHA::sha256('nar-of-glibc-2.42-103-' . h('glibc-x'))) . '.nar.xz' }{size}, length('nar-of-glibc-2.42-103-' . h('glibc-x')), 'repository manifest: size per nar');
is($rm->{upstream}, "file://$w->{up}/cache", 'repository manifest: upstream');
is($rm->{release}, $REL, 'repository manifest: release');
is($r->{repo}{fetched}, 4, 'four nar files fetched');

# --- repeating is safe: nothing is fetched, upstream is not needed ----------
remove_tree("$w->{up}/cache", "$w->{up}/releases", "$w->{up}/hydra/build");
my $r2 = $w->{new}->()->sync('nixos');
is($r2->{starter}{fetched}, 0, 'second sync: starter files kept');
is($r2->{starter}{reused}, 3, 'second sync: starter files matched');
is($r2->{repo}{fetched}, 0, 'second sync: repository unchanged, nothing fetched');
is(decode_json(slurp("$rd/manifest.json"))->{synced_at}, $rm->{synced_at}, 'second sync: repository manifest untouched');

# --- verify -----------------------------------------------------------------
my $v = $w->{new}->()->verify;
is(scalar(@$v), 2, 'verify: the starter and the repository');
is_deeply([ map { scalar @{ $_->{bad} } } @$v ], [ 0, 0 ], 'verify: all files read back');
my ($nar) = glob("$rd/nar/*");
my $good = slurp($nar);
spit($nar, 'x' . substr($good, 1));
spit("$sd/bzImage", 'short');
$v = $w->{new}->()->verify('nixos', '26.05');
my @bad = map { @{ $_->{bad} } } @$v;
is(scalar(@bad), 2, 'verify: a changed nar and a short kernel are both found');
like(join("\n", @bad), qr/bzImage: size 5, recorded \d+/, 'verify names the kernel and the size');
like(join("\n", @bad), qr{nar/.*: sha256 differs}, 'verify names the nar');
my $e = err_of(sub { $w->{new}->(resources => "$w->{root}/empty")->verify });
is($e && $e->kind, 'notfound', 'verify with nothing synced: not found');

# --- a damaged copy is fetched again when upstream is back ------------------
my $w2 = world();
$w2->{new}->()->sync('nixos');
my $rd2 = "$w2->{root}/res/packages/nixos/26.05";
my ($n2) = glob("$rd2/nar/*");
spit($n2, 'damaged');
unlink "$w2->{root}/res/starter/nixos/26.05/initrd";
my $r3 = $w2->{new}->()->sync('nixos');
is($r3->{starter}{fetched}, 1, 'a missing initramfs is fetched again');
is($r3->{repo}{fetched}, 1, 'a damaged nar is fetched again, the other three kept');
is(scalar(@{ [ grep { @{ $_->{bad} } } @{ $w2->{new}->()->verify } ] }), 0, 'verify passes after the repair');

# --- unlisted files in the repository go when the set changes ---------------
spit("$rd2/" . h('stale') . '.narinfo', 'old');
spit("$rd2/nar/stale.nar.xz", 'old');
spit("$w2->{root}/pk", "libvirt\n");
$w2->{new}->()->sync('nixos');
ok(!-e "$rd2/nar/stale.nar.xz" && !-e "$rd2/" . h('stale') . '.narinfo', 'a changed package list prunes what the repository no longer holds');
ok(!-e "$rd2/" . h('perl-x') . '.narinfo', 'perl is gone with its entry in the list');

# --- a real xz store-paths list ---------------------------------------------
SKIP: {
    skip 'xz is not installed here', 2 unless grep { -x "$_/xz" } split /:/, $ENV{PATH};
    my $w3 = world();
    my $f = "$w3->{up}/releases/nixos/26.05/nixos-$REL/store-paths.xz";
    my $plain = slurp($f);
    spit("$f.txt", $plain);
    unlink $f;
    open(my $out, '>', $f) or die;
    open(my $x, '-|', 'xz', '-z', '-c', "$f.txt") or die;
    binmode $out;
    binmode $x;
    print {$out} do { local $/; scalar <$x> };
    close $x;
    close $out;
    my $r4 = $w3->{new}->()->sync('nixos');
    is($r4->{repo}{paths}, 4, 'store-paths.xz is read through xz');
    local $ENV{PATH} = '/nonexistent';
    my $w4 = world();
    spit("$w4->{up}/releases/nixos/26.05/nixos-$REL/store-paths.xz", slurp($f));
    $e = err_of(sub { $w4->{new}->(curl => '/usr/bin/curl')->sync('nixos') });
    like($e && $e->message, qr/xz is not installed.*--store-paths/s, 'without xz the error names the package and the way round');
}

# --- --store-paths names the list itself ------------------------------------
my $w5 = world();
spit("$w5->{root}/sp.txt", slurp("$w5->{up}/releases/nixos/26.05/nixos-$REL/store-paths.xz"));
remove_tree("$w5->{up}/releases");
my $r5 = $w5->{new}->(store_paths => "$w5->{root}/sp.txt")->sync('nixos');
is($r5->{repo}{paths}, 4, 'a store path list given on the command line replaces the release download');

# --- --only: the starter alone, then the repository that follows it -----------
my $w7 = world();
$e = err_of(sub { $w7->{new}->()->sync('nixos', undef, only => 'repository') });
is($e && $e->kind, 'notfound', 'the repository alone needs a synced starter');
$e = err_of(sub { $w7->{new}->()->sync('nixos', undef, only => 'both') });
is($e && $e->kind, 'usage', '--only takes starter or repository');
my $r7 = $w7->{new}->()->sync('nixos', undef, only => 'starter');
ok($r7->{starter} && !defined $r7->{repo}, 'only starter: the starter is synced, the repository not run');
ok(!-e "$w7->{root}/res/packages", 'only starter: no repository directory');
$r7 = $w7->{new}->()->sync('nixos', undef, only => 'repository');
ok(!defined $r7->{starter} && $r7->{repo}{paths} == 4, 'only repository: follows the starter\'s release');
is($r7->{release}, $REL, 'only repository: release of the starter');
{
    my $out = `$^X $BIN sync nixos --only starter --hydra file://$w7->{up}/hydra --resources $w7->{root}/res2 2>/dev/null`;
    is($? >> 8, 0, 'hps-starter sync --only starter: exit 0');
    like($out, qr/^SYNCED nixos 26\.05 release=\Q$REL\E starter\(files=3 fetched=3 reused=0 bytes=\d+\)$/m, 'the last line names the starter only');
}

# --- refusals ----------------------------------------------------------------
$e = err_of(sub { $w->{new}->()->sync('alpine') });
is($e && $e->kind, 'refused', 'alpine is refused');
like($e && $e->message, qr/alpine: not yet implemented \(plan step 4\)/, 'alpine: the message names the plan step');
$e = err_of(sub { $w->{new}->()->sync('plan9') });
is($e && $e->kind, 'usage', 'an unknown OS is a usage error');
$e = err_of(sub { $w->{new}->(proxy => 'socks5://x:1') });
is($e && $e->kind, 'usage', 'a proxy that is not http://host:port is refused');

# a name the release holds twice for the x86_64 system is not guessed
my $w6 = world();
my $dup = "$w6->{up}/releases/nixos/26.05/nixos-$REL/store-paths.xz";
spit($dup, slurp($dup) . '/nix/store/' . h('libvirt-x2') . "-libvirt-12.2.0\n");
spit("$w6->{up}/cache/" . h('libvirt-x2') . '.narinfo',
    slurp("$w6->{up}/cache/" . h('libvirt-x') . '.narinfo') =~ s/\Q@{[ h('libvirt-x') ]}\E/@{[ h('libvirt-x2') ]}/r);
$e = err_of(sub { $w6->{new}->()->sync('nixos') });
like($e && $e->message, qr/package 'libvirt': several x86_64 candidates/, 'two x86_64 candidates are refused, not guessed');

# --- upstream refuses: the host is named, the proxy flag is passed ----------
{
    my $root = tempdir(CLEANUP => 1);
    spit("$root/curl", "#!/bin/sh\necho \"\$@\" >> $root/args\necho 'curl: (56) CONNECT tunnel failed, response 403' >&2\nexit 56\n");
    chmod 0755, "$root/curl";
    my $s = HPS::Starter->new(resources => "$root/res", curl => "$root/curl", proxy => 'http://10.100.1.2:3128',
        packages => "$w->{root}/pk", logger => sub { });
    $e = err_of(sub { $s->sync('nixos') });
    like($e && $e->message, qr/host hydra\.nixos\.org: curl: \(56\) CONNECT tunnel failed, response 403/, 'a refusing upstream is named by host');
    like($e && $e->message, qr{via proxy http://10\.100\.1\.2:3128}, 'the error says which proxy was used');
    like(slurp("$root/args"), qr{--proxy http://10\.100\.1\.2:3128 }, 'curl is run through the proxy');
    unlink "$root/args";
    $s = HPS::Starter->new(resources => "$root/res", curl => "$root/curl", packages => "$w->{root}/pk", logger => sub { });
    err_of(sub { $s->sync('nixos') });
    like(slurp("$root/args"), qr{--noproxy \* }, 'without a proxy curl goes direct');
}

# --- the verb ----------------------------------------------------------------
{
    my $res = "$w->{root}/res";
    my $out = `$^X $BIN list --resources $res 2>&1`;
    is($? >> 8, 0, 'hps-starter list: exit 0');
    like($out, qr/^starter\s+nixos\s+26\.05\s+\Q$REL\E\s+3\b/m, 'list: the starter row');
    like($out, qr/^repository\s+nixos\s+26\.05\s+\Q$REL\E\s+9\b/m, 'list: the repository row');
    $out = `$^X $BIN verify --resources $res 2>&1`;
    is($? >> 8, 1, 'hps-starter verify: exit 1 on the damaged copy');
    like($out, qr/^FAIL starter nixos 26\.05: bzImage/m, 'verify: failure line');
    like($out, qr/^VERIFY failed sets=2 bad=2$/m, 'verify: last line');
    $out = `$^X $BIN sync alpine --resources $res 2>&1`;
    is($? >> 8, 3, 'hps-starter sync alpine: exit 3');
    like($out, qr/not yet implemented \(plan step 4\)/, 'sync alpine says so');
    $out = `$^X $BIN verify --resources $w->{root}/none 2>&1`;
    is($? >> 8, 4, 'verify with nothing synced: exit 4');
    $out = `$^X $BIN sync nixos --resources $res --packages $w->{root}/pk --proxy nonsense 2>&1`;
    is($? >> 8, 2, 'a bad proxy is a usage error: exit 2');
}

done_testing;
