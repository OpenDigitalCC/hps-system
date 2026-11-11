#!/usr/bin/env perl
# CS-3.11: hps-cnh-publish / HPS::CnhPublish - the hps-system tarball and the
# bootstrap manifest a container host fetches (cnh-ips-bootstrap).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA;
use JSON::PP;
use POSIX ();
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::CnhPublish;

my $NOW = 1_800_000_000;
my $BIN = "$Bin/../bin/hps-cnh-publish";

sub spit { my ($f, $t) = @_; open(my $fh, '>:raw', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub sha { Digest::SHA::sha256_hex($_[0]) }
sub sha_file { my $d = Digest::SHA->new(256); $d->addfile($_[0], 'b'); $d->hexdigest }

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => "$base/cfg", system_registry => "$base/cfg/system.db");

# A resources tree with one verifiable pin and the ctrl-exec package, as
# nix/build.sh and lab/ips/setup.sh leave it.
sub make_world {
    my $root = tempdir(DIR => $base);
    my $res  = "$root/res";
    my $sys  = "$root/sys";
    my $pin  = 'nixos-26.05-20261111-0123456-abcdef0';
    my @sums;
    for my $p (qw(node-base node-cnh)) {
        make_path("$res/nixos/$pin/$p");
        my %c = (bzImage => "kernel-$p", initrd => "initrd-$p");
        spit("$res/nixos/$pin/$p/$_", $c{$_}) for keys %c;
        my %b = (pin => $pin, profile => $p, init => '/x', built_at => '2026-11-11T00:00:00Z',
            sha256 => { map { $_ => sha($c{$_}) } keys %c },
            size   => { map { $_ => length $c{$_} } keys %c });
        spit("$res/nixos/$pin/$p/boot.json", JSON::PP->new->canonical->encode(\%b));
        push @sums, sha($c{bzImage}) . "  $p/bzImage\n", sha($c{initrd}) . "  $p/initrd\n";
    }
    spit("$res/nixos/$pin/SHA256SUMS", join('', @sums));
    spit("$res/nixos/latest", "$pin\n");
    make_path("$res/packages/ctrl-exec");
    spit("$res/packages/ctrl-exec/ctrl-exec-latest.tar.gz", 'ctrl-exec-tarball');
    make_path("$sys/scripts", "$sys/lib", "$sys/.git", "$sys/tmp", "$sys/log");
    spit("$sys/scripts/run-hps.sh", "#!/bin/bash\necho run\n");
    chmod 0755, "$sys/scripts/run-hps.sh";
    spit("$sys/lib/x.sh", "x\n");
    spit("$sys/.git/HEAD", "ref: refs/heads/main\n");
    spit("$sys/tmp/scratch", "scratch\n");
    spit("$sys/log/old.log", "log\n");
    return ($res, $sys, $pin);
}

sub publisher {
    my ($res, $sys) = @_;
    return HPS::CnhPublish->new(resources => $res, system => $sys, registry => $reg, now => sub { $NOW });
}

sub tar_list {
    my ($f) = @_;
    open(my $fh, '-|', 'tar', '-tzf', $f) or die "tar: $!";
    chomp(my @l = <$fh>);
    close $fh;
    return @l;
}

{
    my ($res, $sys, $pin) = make_world();
    my $r = publisher($res, $sys)->publish(pins => [$pin]);
    like($r->{sha256}, qr/^[0-9a-f]{64}\z/, 'publish returns the manifest sha256');
    is($r->{url}, "packages/cnh/manifest-$r->{sha256}.json", 'url names the manifest by its hash');
    ok(-f $r->{manifest}, 'manifest written');
    is(sha_file($r->{manifest}), $r->{sha256}, 'the manifest file hashes to the returned sha256');
    is(slurp("$res/packages/cnh/latest"), "$r->{sha256}\n", 'latest holds the newest manifest sha');

    my $m = JSON::PP->new->decode(slurp($r->{manifest}));
    is($m->{schema}, 'hps-cnh-manifest/1', 'schema');
    is($m->{created_at}, POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($NOW)), 'created_at from the clock');
    is_deeply($m->{source}{pins}, [$pin], 'source lists the pins');
    is($m->{source}{hps_system_commit}, 'unknown', 'a tree git cannot read gives commit unknown');

    my @files = @{ $m->{files} };
    is($r->{files}, scalar @files, 'files count matches');
    is($files[0]{path}, 'hps-system.tar.gz', 'the hps-system tarball comes first');
    like($files[0]{url}, qr{^packages/cnh/hps-system-[0-9a-f]{16}\.tar\.gz\z}, 'tarball url');
    my $tb = "$res/$files[0]{url}";
    ok(-f $tb, 'tarball written where the url points');
    is($files[0]{sha256}, sha_file($tb), 'tarball sha256 recorded');
    is($files[0]{size}, -s $tb, 'tarball size recorded');

    my %byp = map { $_->{path} => $_ } @files;
    for my $rel ("$pin/node-base/bzImage", "$pin/node-cnh/initrd", "$pin/node-cnh/boot.json", "$pin/SHA256SUMS") {
        my $e = $byp{"srv/hps-resources/nixos/$rel"};
        ok($e, "pin file $rel listed");
        is($e->{url}, "nixos/$rel", "pin file $rel url under /nixos/");
        is($e->{sha256}, sha_file("$res/nixos/$rel"), "pin file $rel sha256");
    }
    ok(!$byp{'srv/hps-resources/nixos/latest'}, 'nixos/latest is not listed (pins are named explicitly)');
    my $ce = $byp{'srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz'};
    ok($ce, 'the ctrl-exec package is listed by default');
    is($ce->{url}, 'packages/ctrl-exec/ctrl-exec-latest.tar.gz', 'package url');
    is($ce->{sha256}, sha('ctrl-exec-tarball'), 'package sha256');

    my @members = tar_list($tb);
    ok((grep { $_ eq './scripts/run-hps.sh' } @members), 'tarball holds scripts/run-hps.sh');
    ok((grep { $_ eq './lib/x.sh' } @members), 'tarball holds lib/');
    ok(!(grep { m{^\./(\.git|tmp|log)(/|\z)} } @members), 'tarball leaves out .git, tmp and log');

    # Reproducible: the same tree gives the same tarball and the same manifest.
    my $r2 = publisher($res, $sys)->publish(pins => [$pin]);
    is($r2->{sha256}, $r->{sha256}, 'same inputs and clock: same manifest sha');
    my @cnh = glob("$res/packages/cnh/hps-system-*.tar.gz");
    is(scalar @cnh, 1, 'same tree: one tarball, not two');
    ok(!glob("$res/packages/cnh/.hps-system*"), 'no temporary tarball left');

    # A changed tree gives a new tarball and a new manifest.
    spit("$sys/lib/x.sh", "y\n");
    my $r3 = publisher($res, $sys)->publish(pins => [$pin]);
    isnt($r3->{sha256}, $r->{sha256}, 'a changed tree gives a new manifest');
    is(slurp("$res/packages/cnh/latest"), "$r3->{sha256}\n", 'latest follows the newest');
    ok(-f $r->{manifest}, 'the older manifest stays (a CNH may be part-way through it)');
}

{
    my ($res, $sys, $pin) = make_world();
    spit("$res/nixos/$pin/node-base/bzImage", 'tampered');
    my $err;
    eval { publisher($res, $sys)->publish(pins => [$pin]); 1 } or $err = $@;
    ok(ref $err && $err->kind eq 'refused', 'a pin that does not verify is refused');
    like($err->message, qr/does not verify/, 'refusal says why');
    ok(!-e "$res/packages/cnh/latest", 'nothing is written when a pin is refused');
}

{
    my ($res, $sys, $pin) = make_world();
    symlink('/etc/passwd', "$res/nixos/$pin/node-cnh/extra") or die $!;
    my $err;
    eval { publisher($res, $sys)->publish(pins => [$pin]); 1 } or $err = $@;
    ok(ref $err && $err->kind eq 'refused', 'a symlink inside a pin is refused');
}

{
    my ($res, $sys, $pin) = make_world();
    my $p = publisher($res, $sys);
    my @bad = (
        [ [], [], 'usage', 'no pin' ],
        [ ['Bad_Pin'], [], 'usage', 'malformed pin' ],
        [ ['nixos-none'], [], 'notfound', 'missing pin' ],
        [ [$pin, $pin], [], 'usage', 'a pin twice' ],
        [ [$pin], ['../etc/passwd'], 'usage', 'package outside packages/' ],
        [ [$pin], ['packages/../x'], 'usage', 'package with ..' ],
        [ [$pin], ['packages/cnh/latest'], 'refused', 'package from the own output dir' ],
        [ [$pin], ['packages/none.tar.gz'], 'notfound', 'missing package' ],
    );
    for my $c (@bad) {
        my ($pins, $pk, $kind, $what) = @$c;
        my $err;
        eval { $p->publish(pins => $pins, packages => $pk); 1 } or $err = $@;
        ok(ref $err && $err->kind eq $kind, "$what: $kind") or diag(ref $err ? $err->message : $err);
    }
    unlink "$res/packages/ctrl-exec/ctrl-exec-latest.tar.gz";
    my $err;
    eval { $p->publish(pins => [$pin]); 1 } or $err = $@;
    ok(ref $err && $err->kind eq 'notfound', 'the default ctrl-exec package must exist');
    rename "$sys/scripts/run-hps.sh", "$sys/scripts/gone";
    spit("$res/packages/x.tar.gz", 'x');
    undef $err;
    eval { $p->publish(pins => [$pin], packages => ['packages/x.tar.gz']); 1 } or $err = $@;
    ok(ref $err && $err->kind eq 'notfound', 'a tree without scripts/run-hps.sh is refused');
}

# The CLI: exit codes and the MANIFEST line.
{
    my ($res, $sys, $pin) = make_world();
    local $ENV{HPS_CONFIG_BASE} = "$base/cfg";
    local $ENV{HPS_PINS_NO_SYSLOG} = 1;
    my $out = qx{"$^X" "$BIN" --resources "$res" --system "$sys" --pin "$pin" 2>&1};
    is($? >> 8, 0, 'cli: exit 0');
    like($out, qr/^MANIFEST [0-9a-f]{64} packages\/cnh\/manifest-[0-9a-f]{64}\.json files=\d+$/m, 'cli: MANIFEST line');
    my ($sha) = $out =~ /^MANIFEST ([0-9a-f]{64})/m;
    is(sha_file("$res/packages/cnh/manifest-$sha.json"), $sha, 'cli: the printed sha is the file hash');
    qx{"$^X" "$BIN" --resources "$res" --system "$sys" 2>&1};
    is($? >> 8, 2, 'cli: no --pin is a usage error');
    qx{"$^X" "$BIN" --resources "$res" --system "$sys" --pin nixos-absent 2>&1};
    is($? >> 8, 4, 'cli: a missing pin exits 4');
    qx{"$^X" "$BIN" --resources "$res" --system "$sys" --pin "$pin" extra 2>&1};
    is($? >> 8, 2, 'cli: stray arguments are a usage error');
}

done_testing;
