#!/usr/bin/env perl
# hps-workload images, and define refusing an image outside the catalogue.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload::List;

my $d = tempdir(CLEANUP => 1);
sub put { my ($n, $t) = @_; open(my $h, '>', "$d/$n") or die; print {$h} $t; close $h }
put('a.qcow2', 'x' x 100);
put('a.sha256', ('1' x 64) . "  a.qcow2\n");
put('b.qcow2', 'y' x 10);          # no checksum
put('c.sha256', ('2' x 64) . "\n"); # no image
put('.hidden.qcow2', 'z');
utime(1_800_000_000, 1_800_000_000, "$d/a.qcow2");
my $r = HPS::Workload::List::images($d);
is_deeply($r, [
    { name => 'a', size => 100, sha256 => '1' x 64, mtime => '2027-01-15T08:00:00Z' },
    { name => 'b', size => 10, sha256 => undef, mtime => $r->[1]{mtime} } ], 'catalogue: images with their sha256; a checksum-less one shows null; no stray files');
my $t = HPS::Workload::List::render_images($r);
like($t, qr/^a\s+100\s+2027-01-15T08:00:00Z\s+1{64}$/m, 'text row');
like($t, qr/^b\s+10\s.*no checksum$/m, 'no checksum said');
is_deeply(HPS::Workload::List::images("$d/nope"), [], 'missing dir: empty');

# define
my $f = StorageFixture::setup_workload(no_def => 1);
my $wl = $f->{wl}->();
my $def = StorageFixture::base_def();
my $ok = eval { $wl->define('t0', encode_json($def), dry_run => 1) };
ok($ok, 'a catalogue image is accepted') or diag $@;
$def->{vms}[1]{image} = 'no-such-image';
eval { $wl->define('t0', encode_json($def)) };
my $e = $@;
like(ref $e ? $e->message : $e, qr/vm t0-db: image 'no-such-image' is not in the catalogue \(hps-workload images lists it: debian-13-generic-amd64\)/, 'define refuses and names the verb');
ok(!-e $wl->definition_path('t0'), 'nothing written');
eval { $wl->define('t0', encode_json($def), dry_run => 1) };
ok($@, 'also on --dry-run');

done_testing;
