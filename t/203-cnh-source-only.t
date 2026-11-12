#!/usr/bin/env perl
# hps-cnh-publish --source-only: the hps-system tarball alone, for an image
# builder (builder-build <sha256>, docs/BUILDER.md). No manifest, latest left
# as it is.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA;
use FindBin qw($Bin);

my $BIN = "$Bin/../bin/hps-cnh-publish";

sub spit { my ($f, $t) = @_; open(my $fh, '>:raw', $f) or die "$f: $!"; print {$fh} $t; close $fh }
sub slurp { open(my $fh, '<:raw', $_[0]) or die "$_[0]: $!"; local $/; my $t = <$fh>; close $fh; $t }
sub sha_file { my $d = Digest::SHA->new(256); $d->addfile($_[0], 'b'); $d->hexdigest }

my $base = tempdir(CLEANUP => 1);
my ($res, $sys) = ("$base/res", "$base/sys");
make_path("$sys/scripts", "$sys/nix", "$res/packages/cnh");
spit("$sys/scripts/run-hps.sh", "#!/bin/bash\n");
spit("$sys/flake.nix", "{ }\n");
spit("$sys/nix/build.sh", "#!/bin/bash\n");
spit("$res/packages/cnh/latest", "previous\n");

my $out = qx{perl "$BIN" --source-only --resources "$res" --system "$sys" 2>&1};
is($? >> 8, 0, '--source-only exits 0') or diag $out;
my ($sha, $url) = $out =~ /^SOURCE ([0-9a-f]{64}) (\S+)$/m;
ok($sha, 'prints SOURCE <sha256> <url path>');
is($url, 'packages/cnh/hps-system-' . substr($sha // '', 0, 16) . '.tar.gz', 'the url is packages/cnh/hps-system-<sha16>.tar.gz');
my $tar = "$res/$url";
ok(-f $tar, 'the tarball is written');
is(sha_file($tar), $sha, 'its sha256 is the one printed');
is(slurp("$res/packages/cnh/latest"), "previous\n", 'latest is left as it was');
is_deeply([ glob("$res/packages/cnh/manifest-*") ], [], 'no manifest is written');
my @names = sort split /\n/, qx{tar -tzf "$tar"};
ok((grep { $_ eq './flake.nix' } @names) && (grep { $_ eq './nix/build.sh' } @names), 'the tarball holds flake.nix and nix/build.sh');

my $again = qx{perl "$BIN" --source-only --resources "$res" --system "$sys" 2>&1};
is(($again =~ /^SOURCE ([0-9a-f]{64})/m)[0], $sha, 'a second run of the same tree gives the same sha256 (reproducible)');

qx{perl "$BIN" --source-only --pin p1 --resources "$res" --system "$sys" 2>&1};
is($? >> 8, 2, '--source-only with --pin is usage (2)');
qx{perl "$BIN" --source-only --resources "$res" --system "$base/none" 2>&1};
is($? >> 8, 4, 'a tree without scripts/run-hps.sh is not found (4)');
like(qx{perl "$BIN" --help 2>&1}, qr/--source-only/, '--help names --source-only');

done_testing;
