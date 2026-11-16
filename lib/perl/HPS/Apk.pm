package HPS::Apk;
# Alpine package files, read and written in plain Perl (docs/STARTER.md "Alpine").
#
# An .apk is gzip streams written one after the other: an optional signature
# stream, the control stream (tar: .PKGINFO and the install scripts) and the
# data stream (tar: the files). The repository index line "C:" of a package is
# Q1 and the base64 of the SHA-1 of its control stream. This module reads that,
# parses an APKINDEX, and writes an unsigned package and an unsigned index (the
# local packages of an IPS, which a node installs with --allow-untrusted, the
# same way the NixOS side installs a local package without a signature). Nothing
# here is compiled and nothing needs apk-tools.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use MIME::Base64 ();
use Compress::Raw::Zlib qw(WANT_GZIP Z_STREAM_END Z_OK Z_BUF_ERROR);
use IO::Compress::Gzip ();

# tar_entries($bytes): [{name, size, data, type}] of a tar held in memory (ustar
# headers; a long name is the usual prefix + name). Stops at a zero block.
sub tar_entries ($tar) {
    my @e;
    my $off = 0;
    while ($off + 512 <= length $tar) {
        my $h = substr($tar, $off, 512);
        last if $h =~ /\A\0{512}\z/;
        my ($name) = unpack('Z100', $h);
        my ($prefix) = unpack('x345 Z155', $h);
        $name = "$prefix/$name" if length $prefix;
        my ($sz) = unpack('x124 a12', $h);
        $sz =~ s/[\0 ]+//g;
        my $size = length $sz ? oct($sz) : 0;
        my ($type) = unpack('x156 a1', $h);
        $off += 512;
        push @e, { name => $name, size => $size, type => $type, data => substr($tar, $off, $size) };
        $off += int(($size + 511) / 512) * 512;
    }
    return \@e;
}

# streams($file, $want): the gzip streams at the start of an apk, as [raw bytes,
# plain bytes], until one holds .PKGINFO (the control stream) or $want streams
# are read. Reads in growing windows, so a 150 MiB package costs a few KiB.
sub streams ($file, $limit = 8) {
    open(my $fh, '<:raw', $file) or die "cannot read $file: $!\n";
    my $window = 1 << 16;
    while (1) {
        seek($fh, 0, 0);
        read($fh, my $buf, $window);
        my $eof = length($buf) < $window;
        my @out;
        my $short = 0;
        while (length $buf && @out < $limit) {
            my ($i) = Compress::Raw::Zlib::Inflate->new(-WindowBits => WANT_GZIP, -AppendOutput => 1, -ConsumeInput => 1);
            my $before = $buf;
            my $plain = '';
            my $st = $i->inflate($buf, $plain);
            if ($st == Z_STREAM_END) {
                push @out, [ substr($before, 0, length($before) - length($buf)), $plain ];
                last if grep { $_->{name} eq '.PKGINFO' } @{ tar_entries($plain) };
            }
            else { $short = 1; last }
        }
        close $fh if $eof;
        return \@out if !$short || $eof;
        $window *= 8;
        die "$file: the control stream is not within the first 64 MiB\n" if $window > (1 << 26);
    }
}

# control($file): {sum => 'Q1...', pkginfo => {key => [values]}, scripts => [names], size => bytes}
sub control ($file) {
    my $s = streams($file);
    for my $m (@$s) {
        my ($info) = grep { $_->{name} eq '.PKGINFO' } @{ tar_entries($m->[1]) };
        next unless $info;
        my %pi;
        for my $l (split /\n/, $info->{data}) {
            next if $l =~ /\A#/;
            push @{ $pi{$1} }, $2 if $l =~ /\A(\w+) = (.*)\z/;
        }
        return { sum => 'Q1' . MIME::Base64::encode_base64(Digest::SHA::sha1($m->[0]), ''), pkginfo => \%pi, size => -s $file };
    }
    die "$file: no .PKGINFO in the control stream (not an apk?)\n";
}

# parse_index($text): { name => {P V S C D p i k o ...} } from an APKINDEX text.
# One record per name (the later one wins, as a repository holds one per name).
sub parse_index ($text) {
    my %pkg;
    for my $blk (split /\n\n+/, $text) {
        my %f;
        for my $l (split /\n/, $blk) { $f{$1} = $2 if $l =~ /\A(\w):(.*)\z/ }
        next unless defined $f{P};
        $pkg{ $f{P} } = \%f;
    }
    return \%pkg;
}

# index_text($file): the APKINDEX of an APKINDEX.tar.gz (signature stream or not).
sub index_text ($file) {
    my $text;
    open(my $fh, '-|', 'sh', '-c', 'exec tar -xzOf "$1" APKINDEX 2>/dev/null', 'sh', $file) or die "cannot run tar on $file: $!\n";
    local $/;
    $text = <$fh>;
    close $fh or die "tar could not read APKINDEX from $file\n";
    return $text // '';
}

# ---- writing ----

sub _tar_header ($name, $size, $mode, $type = '0', $link = '') {
    my ($prefix, $n) = ('', $name);
    die "name too long: $name\n" if length($name) > 255;
    if (length($name) > 100) {
        my $i = rindex($name, '/', 154);
        die "name too long: $name\n" if $i < 0 || length($name) - $i - 1 > 100;
        ($prefix, $n) = (substr($name, 0, $i), substr($name, $i + 1));
    }
    my $h = pack('a100 a8 a8 a8 a12 a12 a8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
        $n, sprintf('%07o', $mode), sprintf('%07o', 0), sprintf('%07o', 0), sprintf('%011o', $size), sprintf('%011o', 0),
        '        ', $type, $link, 'ustar', '00', 'root', 'root', '', '', $prefix);
    my $sum = 0;
    $sum += ord for split //, $h;
    substr($h, 148, 8) = sprintf('%06o', $sum) . "\0 ";
    return $h;
}

# tar_bytes(\@entries, $end): entries are {name, data, mode, type?, link?}; $end
# false cuts the two end blocks, as abuild does for every stream but the last.
sub tar_bytes ($entries, $end = 1) {
    my $t = '';
    for my $e (@$entries) {
        my $type = $e->{type} // '0';
        my $data = $type eq '0' ? ($e->{data} // '') : '';
        $t .= _tar_header($e->{name}, length($data), $e->{mode} // ($type eq '5' ? 0755 : 0644), $type, $e->{link} // '');
        $t .= $data . ("\0" x ((512 - length($data) % 512) % 512));
    }
    $t .= "\0" x 1024 if $end;
    return $t;
}

sub _gzip ($bytes) {
    my $out;
    IO::Compress::Gzip::gzip(\$bytes => \$out, Time => 0, -Level => 9, Minimal => 1) or die "gzip failed\n";
    return $out;
}

# pack_apk(%a): name, version (with -rN), arch (default noarch), description,
# url, license, depends => [..], provides => [..], files => [{name, data, mode, type?, link?}]
# Returns the apk bytes (control stream, data stream; no signature).
sub pack_apk (%a) {
    my $files = $a{files} // [];
    my %seen;
    my @dirs;
    for my $f (@$files) {
        my @p = split m{/}, $f->{name};
        pop @p if ($f->{type} // '0') ne '5';
        my $d = '';
        for my $c (@p) { $d .= ($d ? '/' : '') . $c; push @dirs, { name => "$d/", type => '5', mode => 0755 } unless $seen{$d}++ }
    }
    my $data = _gzip(tar_bytes([ @dirs, @$files ], 1));
    my $installed = 0;
    $installed += length($_->{data} // '') for @$files;
    my @l = (
        "pkgname = $a{name}", "pkgver = $a{version}", "pkgdesc = " . ($a{description} // $a{name}),
        'url = ' . ($a{url} // 'https://hps.invalid/'), 'builddate = ' . ($a{builddate} // 0), 'packager = hps-starter',
        "size = $installed", "arch = " . ($a{arch} // 'noarch'), 'license = ' . ($a{license} // 'custom'),
        (map { "provides = $_" } @{ $a{provides} // [] }), (map { "depend = $_" } @{ $a{depends} // [] }),
        'datahash = ' . Digest::SHA::sha256_hex($data),
    );
    my $control = _gzip(tar_bytes([ { name => '.PKGINFO', data => join("\n", @l) . "\n" } ], 0));
    return $control . $data;
}

# index_record($file): the APKINDEX text of one package file.
sub index_record ($file) {
    my $c = control($file);
    my $pi = $c->{pkginfo};
    my $one = sub ($k) { $pi->{$k} ? $pi->{$k}[0] : '' };
    my @l = ("C:$c->{sum}", 'P:' . $one->('pkgname'), 'V:' . $one->('pkgver'), 'A:' . ($one->('arch') || 'noarch'),
        "S:$c->{size}", 'I:' . $one->('size'), 'T:' . $one->('pkgdesc'), 'U:' . $one->('url'), 'L:' . $one->('license'));
    push @l, 'D:' . join(' ', @{ $pi->{depend} }) if $pi->{depend};
    push @l, 'p:' . join(' ', @{ $pi->{provides} }) if $pi->{provides};
    return join("\n", @l) . "\n\n";
}

# write_index($dest, @apk files): an unsigned APKINDEX.tar.gz (the local repository).
sub write_index ($dest, @files) {
    my $text = join '', map { index_record($_) } @files;
    my $tar = tar_bytes([ { name => 'DESCRIPTION', data => "hps local packages\n" }, { name => 'APKINDEX', data => $text } ], 1);
    open(my $fh, '>:raw', $dest) or die "cannot write $dest: $!\n";
    print {$fh} _gzip($tar);
    close $fh or die "cannot write $dest: $!\n";
    return scalar @files;
}

1;
