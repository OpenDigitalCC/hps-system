#!/usr/bin/env perl
# hps-starter sync alpine / HPS::Starter::Alpine / HPS::Apk (docs/STARTER.md "Alpine"):
# the repository is one snapshot (indexes read once, closure resolved in them, every
# package proved against its index line), and the starter's kernel matches the
# repository's. No network: "upstream" is a directory fixture read through curl's file://
# with real apk files (control stream, data stream) and a real newc cpio initramfs.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Basename ();
use Digest::SHA;
use JSON::PP;
use IO::Compress::Gzip qw(gzip);
use IO::Uncompress::Gunzip qw(gunzip);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Starter;
use HPS::Apk;

my $BIN = "$Bin/../bin/hps-starter";

sub spit { my ($f, $t) = @_; make_path(File::Basename::dirname($f)); open(my $fh, '>:raw', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }
sub msg { my $e = shift; return ref $e ? $e->message : ($e // '') }

# the newc cpio of the stock initramfs: a directory, an init, two boot modules and their index
sub cpio { my @e = @_; my $i = 1; return join('', map { HPS::Starter::Alpine::_cpio_entry($i++, @$_) } @e) . HPS::Starter::Alpine::_cpio_entry(0, 'TRAILER!!!', 0, '') }
sub stock_initramfs {
    my ($k) = @_;
    my $c = cpio(
        [ 'init', 0100755, "#!/bin/sh\necho stock init\n" ],
        [ 'usr/lib', 040755, '' ],
        [ 'usr/lib/modules', 040755, '' ],
        [ "usr/lib/modules/$k", 040755, '' ],
        [ "usr/lib/modules/$k/kernel", 040755, '' ],
        [ "usr/lib/modules/$k/kernel/drivers", 040755, '' ],
        [ "usr/lib/modules/$k/kernel/drivers/virtio_net.ko.gz", 0100644, "old virtio_net $k" ],
        [ "usr/lib/modules/$k/kernel/drivers/virtio.ko.gz", 0100644, "old virtio $k" ],
        [ "usr/lib/modules/$k/modules.dep", 0100644, "old dep $k\n" ],
        [ 'usr/lib/firmware', 040755, '' ],
        [ 'usr/lib/firmware/a.bin.zst', 0100644, 'firmware' ],
    );
    my $z;
    gzip(\$c => \$z) or die;
    return $z;
}

# an upstream mirror of Alpine v3.24 (netboot kernel 6.18.60 unless told otherwise)
sub index_gz {
    my ($file_to_extra) = @_;
    my $text = '';
    for my $f (sort keys %$file_to_extra) {
        my $r = HPS::Apk::index_record($f);
        $r =~ s/\n\n\z/\n/;
        $r .= $file_to_extra->{$f} if length $file_to_extra->{$f};
        $text .= "$r\n";
    }
    return $text;
}
sub apk {
    my ($up, $repo, %a) = @_;
    my $f = "$up/v3.24/$repo/x86_64/$a{name}-$a{version}.apk";
    make_path(File::Basename::dirname($f));
    spit($f, HPS::Apk::pack_apk(arch => 'x86_64', %a));
    return $f;
}
sub write_index {
    my ($up, $repo, $extra) = @_;
    my @f = sort glob("$up/v3.24/$repo/x86_64/*.apk");
    my $text = index_gz({ map { $_ => ($extra->{ File::Basename::basename($_) } // '') } @f });
    my $tar = HPS::Apk::tar_bytes([ { name => 'APKINDEX', data => $text } ], 1);
    my $z;
    gzip(\$tar => \$z);
    spit("$up/v3.24/$repo/x86_64/APKINDEX.tar.gz", $z);
}

sub mirror {
    my (%o) = @_;
    my $up = tempdir(CLEANUP => 1);
    my $kv = $o{kernel} // '6.18.63';
    my $krel = "$kv-0-lts";
    my $stock = $o{stock} // '6.18.60-0-lts';
    spit("$up/v3.24/releases/x86_64/netboot/vmlinuz-lts", "stock kernel $stock");
    spit("$up/v3.24/releases/x86_64/netboot/initramfs-lts", stock_initramfs($stock));
    spit("$up/v3.24/releases/x86_64/latest-releases.yaml",
        "---\n- branch: v3.24\n  arch: x86_64\n  version: 3.24.4\n  flavor: alpine-standard\n- branch: v3.24\n  arch: x86_64\n  version: 3.24.4\n  flavor: alpine-netboot\n  file: alpine-netboot-3.24.4-x86_64.tar.gz\n");
    apk($up, 'main', name => 'linux-lts', version => "$kv-r0", depends => ['linux-firmware-any', 'initramfs-generator'],
        files => [
            { name => 'boot/vmlinuz-lts', data => "repository kernel $krel", mode => 0644 },
            { name => "lib/modules/$krel/kernel/drivers/virtio_net.ko.gz", data => "new virtio_net $krel" },
            { name => "lib/modules/$krel/kernel/drivers/virtio.ko.gz", data => "new virtio $krel" },
            { name => "lib/modules/$krel/kernel/drivers/other.ko.gz", data => "not in the stock initramfs" },
            { name => "lib/modules/$krel/kernel/drivers/net_helper.ko.gz", data => 'a dependency of virtio_net' },
            { name => "lib/modules/$krel/modules.dep", data => "kernel/drivers/virtio_net.ko.gz: kernel/drivers/virtio.ko.gz kernel/drivers/net_helper.ko.gz\nkernel/drivers/virtio.ko.gz:\nkernel/drivers/net_helper.ko.gz:\nkernel/drivers/other.ko.gz:\n" },
            { name => "lib/modules/$krel/modules.alias", data => "alias x y\n" },
        ]);
    apk($up, 'main', name => 'linux-firmware-none', version => '1-r0', provides => ['linux-firmware-any']);
    apk($up, 'main', name => 'mkinitfs', version => '3-r0', provides => ['initramfs-generator'], files => [ { name => 'sbin/mkinitfs', data => "x", mode => 0755 } ]);
    apk($up, 'main', name => 'zfs-lts', version => $o{zfs_for} // "$kv-r0", depends => ["linux-lts=" . ($o{zfs_pin} // "$kv-r0")],
        files => [ { name => "lib/modules/$krel/extra/zfs.ko.gz", data => 'zfs' } ]);
    apk($up, 'main', name => 'alpine-base', version => '3.24.4-r0', depends => ['musl', 'openrc']);
    apk($up, 'main', name => 'musl', version => '1.2-r0', provides => ['so:libc.musl-x86_64.so.1=1']);
    apk($up, 'main', name => 'openrc', version => '0.6-r0', depends => ['so:libc.musl-x86_64.so.1']);
    apk($up, 'community', name => 'openrc-extra', version => '0.6-r0');
    apk($up, 'community', name => 'jq', version => '1.8-r0', depends => ['so:libc.musl-x86_64.so.1']);
    apk($up, 'community', name => 'unrelated', version => '9-r0', files => [ { name => 'usr/bin/unrelated', data => 'x' } ]);
    write_index($up, 'main', {});
    write_index($up, 'community', { 'openrc-extra-0.6-r0.apk' => "i:openrc\n" });
    return $up;
}

sub world {
    my (%o) = @_;
    my $up = $o{up} // mirror(%o);
    my $res = tempdir(CLEANUP => 1);
    my $list = "$res/alpine.packages";
    spit($list, $o{list} // "alpine-base\nlinux-lts\nlinux-firmware-none\nmkinitfs\nzfs-lts\njq\n");
    my $s = HPS::Starter->new(resources => "$res/res", alpine => "file://$up", packages => $list, logger => sub { }, now => sub { 1_800_000_000 });
    return ($s, $res, $up, $list);
}

# --- resolution ---------------------------------------------------------------------------------
{
    my $idx = HPS::Apk::parse_index("P:a\nV:1\nD:b so:x.1 !conflict\n\nP:b\nV:1\np:so:x.1=1\n\nP:b-openrc\nV:1\ni:b\n\nP:c\nV:1\ni:b zz\n\nP:zz\nV:1\n\n");
    my $sel = HPS::Starter::Alpine::resolve($idx, ['a']);
    is_deeply([ sort keys %$sel ], [qw(a b b-openrc)], 'resolve: depends, a provide (so:x.1), and an install_if package whose condition is met; the one that is not met stays out');
    like(msg(err_of(sub { HPS::Starter::Alpine::resolve(HPS::Apk::parse_index("P:a\nV:1\nD:nothing\n\n"), ['a']) })), qr/'nothing' has no provider/, 'an unresolvable dependency is named');
    is(HPS::Starter::Alpine::kernel_release('6.18.63-r0'), '6.18.63-0-lts', 'the kernel release is what uname says');
    is(HPS::Starter::Alpine::kernel_release('6.18.63-r2'), '6.18.63-2-lts', 'pkgrel counts');
}

# --- the real thing in a fixture ----------------------------------------------------------------
{
    my ($s, $res, $up) = world();
    my $r = $s->sync('alpine');
    is($r->{release}, '3.24.4', 'the release identity is the netboot flavour of latest-releases.yaml');
    ok($r->{starter}{assembled}, 'the netboot kernel (6.18.60) is not the repository kernel (6.18.63): the set is assembled');
    my $sd = "$res/res/starter/alpine/3.24";
    my $rd = "$res/res/packages/alpine/3.24";
    is(slurp("$sd/vmlinuz-lts"), 'repository kernel 6.18.63-0-lts', 'the starter kernel is the repository linux-lts, boot/vmlinuz-lts');
    my $z = slurp("$sd/initramfs-lts");
    my $cpio;
    gunzip(\$z => \$cpio) or die;
    my %e = map { $_->{name} => $_ } @{ HPS::Starter::Alpine::cpio_entries($cpio) };
    ok($e{init} && substr($cpio, $e{init}{data_off}, $e{init}{size}) eq "#!/bin/sh\necho stock init\n", 'the stock init is carried over unchanged');
    ok($e{'usr/lib/firmware/a.bin.zst'}, 'the stock firmware is carried over');
    ok(!(grep { m{modules/6\.18\.60} } keys %e), 'the stock kernel module directory is gone');
    is(substr($cpio, $e{'usr/lib/modules/6.18.63-0-lts/kernel/drivers/virtio_net.ko.gz'}{data_off}, 28), "new virtio_net 6.18.63-0-lts", 'the module the stock initramfs names is the repository kernel\'s');
    ok($e{'usr/lib/modules/6.18.63-0-lts/kernel/drivers/net_helper.ko.gz'}, 'and so is its dependency from modules.dep');
    ok(!$e{'usr/lib/modules/6.18.63-0-lts/kernel/drivers/other.ko.gz'}, 'a module the stock initramfs does not name stays out');
    ok($e{'usr/lib/modules/6.18.63-0-lts/modules.alias'}, 'the module index files of the repository kernel are in');
    my $m = decode_json(slurp("$sd/manifest.json"));
    is($m->{cmdline}, 'ip=dhcp modloop=none', 'the manifest records the arguments the starter is booted with beyond the IPS ones: no modloop');
    is($m->{kernel}, '6.18.63-0-lts', 'the manifest names the running kernel');
    is($m->{stock_kernel}, '6.18.60-0-lts', 'and the stock one');
    my $rm = decode_json(slurp("$rd/manifest.json"));
    is($rm->{kernel}, '6.18.63-0-lts', 'the repository manifest names the same kernel');
    ok(-f "$rd/main/x86_64/linux-lts-6.18.63-r0.apk" && -f "$rd/main/x86_64/zfs-lts-6.18.63-r0.apk", 'the kernel and zfs-lts of one snapshot are held');
    ok(-f "$rd/community/x86_64/openrc-extra-0.6-r0.apk", 'an install_if package (the -openrc kind) is in the closure');
    ok(!-e "$rd/community/x86_64/unrelated-9-r0.apk", 'a package nothing needs is not');
    ok(-f "$rd/main/x86_64/APKINDEX.tar.gz" && -f "$rd/community/x86_64/APKINDEX.tar.gz", "the indexes are kept as upstream published them");
    is(slurp("$rd/main/x86_64/APKINDEX.tar.gz"), slurp("$up/v3.24/main/x86_64/APKINDEX.tar.gz"), '... byte for byte');
    is($rm->{roots}{jq}, 'jq-1.8-r0', 'the roots map a name to what the repository holds');
    ok(!-e "$rd/local", 'no local packages, no local repository');

    # list, verify
    my @l = $s->list;
    is(scalar(@l), 2, 'list: the starter and the repository');
    my $v = $s->verify('alpine');
    is(scalar(@$v), 2, 'verify: both sets');
    is_deeply([ map { scalar @{ $_->{bad} } } @$v ], [ 0, 0 ], 'verify: every file reads back against the manifest');
    open(my $fh, '>>', "$rd/community/x86_64/jq-1.8-r0.apk");
    ok(!!$fh, 'tamper with one package'); print {$fh} 'x' if $fh; close $fh if $fh;
    $v = $s->verify('alpine');
    like(join(';', map { @{ $_->{bad} } } @$v), qr/jq-1\.8-r0\.apk: size/, 'verify names the file that differs');

    # a second sync: a damaged file is fetched again, the others are kept, and nothing else is
    my $r2 = $s->sync('alpine');
    is($r2->{repo}{fetched}, 1, 'the second sync fetches the one damaged package and reuses the rest');
    is($s->verify('alpine')->[1]{bad}[0], undef, 'and verifies again');
}

# --- the stock files when the netboot kernel is the repository's ----------------------------------
{
    my ($s, $res) = world(stock => '6.18.63-0-lts');
    my $r = $s->sync('alpine');
    ok(!$r->{starter}{assembled}, 'the netboot kernel is the repository kernel: nothing is assembled');
    my $sd = "$res/res/starter/alpine/3.24";
    is(slurp("$sd/vmlinuz-lts"), 'stock kernel 6.18.63-0-lts', 'the stock kernel is used byte for byte');
    is(Digest::SHA::sha256_hex(slurp("$sd/initramfs-lts")), decode_json(slurp("$sd/manifest.json"))->{stock}{'initramfs-lts'}{sha256}, 'and the stock initramfs');
}

# --- one snapshot ---------------------------------------------------------------------------------
{
    my ($s) = world(zfs_pin => '6.18.60-r0');
    like(msg(err_of(sub { $s->sync('alpine') })), qr/zfs-lts needs linux-lts=6\.18\.60-r0 but the snapshot holds linux-lts 6\.18\.63-r0: the repository is not one snapshot/,
        'a module package built for another kernel version is refused, with both versions');
}
{
    my ($s) = world(list => "alpine-base\njq\n");
    like(msg(err_of(sub { $s->sync('alpine') })), qr/linux-lts is not in the package list/, 'the kernel must be in the set: the starter is matched to it');
}
{
    my ($s, $res, $up) = world();
    unlink "$up/v3.24/community/x86_64/jq-1.8-r0.apk";
    like(msg(err_of(sub { $s->sync('alpine') })), qr/upstream refused or unreachable.*jq-1\.8-r0\.apk/, 'a package the index lists and upstream lacks is named, with the host');
}
{
    my ($s, $res, $up) = world();
    my $f = "$up/v3.24/community/x86_64/jq-1.8-r0.apk";
    my $b = slurp($f);
    substr($b, 30, 1) = chr(ord(substr($b, 30, 1)) ^ 1);
    spit($f, $b);
    like(msg(err_of(sub { $s->sync('alpine') })), qr/jq-1\.8-r0\.apk from .*: (its control checksum|not an apk|size)/, 'a package that does not match its index line is refused');
}
like(msg(err_of(sub { (world())[0]->sync('alpine', '3.24', only => 'starter') })), qr/run sync without --only starter/, '--only starter is refused for alpine: the starter is made from the repository');

# --- local packages -------------------------------------------------------------------------------
{
    my ($s, $res, $up) = world(list => "alpine-base\nlinux-lts\nlinux-firmware-none\nmkinitfs\nzfs-lts\nctrl-exec-agent local\n");
    my $r = $s->sync('alpine');
    is_deeply($r->{repo}{missing_local}, ['ctrl-exec-agent'], 'a local package not added yet is reported as missing, not skipped silently');
    my $rm = decode_json(slurp("$res/res/packages/alpine/3.24/manifest.json"));
    ok(!exists $rm->{roots}{'ctrl-exec-agent'}, 'and it is not a root: a role that names it is refused');
    my $dir = tempdir(CLEANUP => 1);
    spit("$dir/agent.apk", HPS::Apk::pack_apk(name => 'ctrl-exec-agent', version => '0.14.7-r0', depends => ['jq'], files => [ { name => 'usr/bin/ctrl-exec-agent', data => "#!/bin/sh\n", mode => 0755 } ]));
    my $a = $s->add_local('alpine', '3.24', $dir, ['agent.apk']);
    is($a->{added}, 1, 'add-local alpine copies the package under its own name and version');
    ok(-f "$res/res/local/alpine/3.24/ctrl-exec-agent-0.14.7-r0.apk", 'in local/alpine/<release>/');
    is($s->add_local('alpine', '3.24', $dir, ['agent.apk'])->{held}, 1, 'the same file again is held, not copied');
    like(msg(err_of(sub { spit("$dir/bad.apk", 'not an apk'); $s->add_local('alpine', '3.24', $dir, ['bad.apk']) })), qr/not an apk|no \.PKGINFO/, 'a file that is not an apk is refused');
    $r = $s->sync('alpine');
    is_deeply($r->{repo}{missing_local}, [], 'with the package added, nothing is missing');
    my $rd = "$res/res/packages/alpine/3.24";
    $rm = decode_json(slurp("$rd/manifest.json"));
    is($rm->{roots}{'ctrl-exec-agent'}, 'local/ctrl-exec-agent', 'a local root is marked local/ so the node installs it from the local repository, unsigned');
    ok($rm->{local}{'ctrl-exec-agent'}, 'the manifest lists it as local');
    ok(-f "$rd/local/x86_64/ctrl-exec-agent-0.14.7-r0.apk" && -f "$rd/local/x86_64/APKINDEX.tar.gz", 'the local repository has the package and its own index');
    like(HPS::Apk::index_text("$rd/local/x86_64/APKINDEX.tar.gz"), qr/^P:ctrl-exec-agent\nV:0\.14\.7-r0\n.*^D:jq$/ms, 'the local index names the package and its dependency');
    ok(-f "$rd/community/x86_64/jq-1.8-r0.apk", "a local package's own dependencies are in the closure");
    is_deeply([ map { scalar @{ $_->{bad} } } @{ $s->verify('alpine') } ], [ 0, 0 ], 'verify covers the local files too');
}

# --- the tool ---------------------------------------------------------------------------------------
{
    my ($s, $res, $up, $list) = world();
    my $out = qx{perl $BIN sync alpine --resources $res/cli --alpine file://$up --packages $list 2>&1};
    is($? >> 8, 0, 'hps-starter sync alpine exits 0');
    like($out, qr/^SYNCED alpine 3\.24 release=3\.24\.4 starter\(files=2 .*\) repository\(paths=\d+ files=\d+ /m, 'and the last line says what was synced');
    $out = qx{perl $BIN verify alpine --resources $res/cli 2>&1};
    like($out, qr/VERIFY ok sets=2 bad=0/, 'verify alpine');
    $out = qx{perl $BIN list --resources $res/cli 2>&1};
    like($out, qr/starter\s+alpine\s+3\.24\s+3\.24\.4.*\nrepository\s+alpine\s+3\.24/, 'list covers alpine');
}

done_testing;
