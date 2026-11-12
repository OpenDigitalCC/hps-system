package HPS::PinFetch;
# Pull one pin from an image builder into <resources>/nixos/, proved on disk
# (docs/BUILDER.md; IPS-33 #3, #3b). The IPS is in control: it asks the
# builder's read-only HTTP server (hps-builder-http, darkhttpd over the
# builder's out/) for one file at a time and publishes nothing it has not
# read back from its own disk.
#
#   <from>/<pin>/SHA256SUMS            the list: every profile's bzImage and
#                                      initrd, the iPXE binaries, and each
#                                      shared firmware layer as ../firmware/<f>
#   <from>/<pin>/<profile>/boot.json   for every profile SHA256SUMS names
#   <from>/<pin>/ipxe/ipxe.json        when it names ipxe/ files
#   <from>/firmware/<f>                each shared layer
#
# Order: SHA256SUMS and the JSON files are fetched into a staging directory
# (<resources>/nixos/.fetch-<pin>-<pid>) and read back with O_DIRECT, and
# boot.json and ipxe.json must record the same hashes as SHA256SUMS. Then
# every listed file is fetched and its O_DIRECT read must give the listed
# sha256; a file that reads back otherwise is fetched again (tries, default
# 3, with a pause). A layer already published with the right content is kept.
# The staging directory is renamed to <pin>, every file is read back with
# O_DIRECT once more (re-fetched into place on a mismatch), and the pin must
# pass HPS::Pins verify. A pin that never proves is moved aside to
# <resources>/nixos/.failed-<pin>-<time>, never left under its name. latest is
# set only on request, through HPS::Pins (which verifies again).
#
# O_DIRECT reads go through dd iflag=direct (an aligned buffer is not
# something core Perl can promise sysread). Downloads use curl, straight to
# the builder (never a proxy), optionally rate-limited.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Digest::SHA ();
use File::Path ();
use File::Basename ();
use POSIX qw(strftime);
use HPS::Pins;

package HPS::PinFetch::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $PIN_RE     = qr/\A[a-z0-9][a-z0-9.-]+\z/;
my $FROM_RE    = qr{\Ahttp://[A-Za-z0-9][A-Za-z0-9.-]{0,252}(?::[0-9]{1,5})?\z};
my $PROFILE_RE = qr/\A[a-z0-9][a-z0-9-]{0,63}\z/;
my $FILE_RE    = qr/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z/;
my $RATE_RE    = qr/\A[1-9][0-9]{0,5}[kKmMgG]?\z/;

sub new ($class, %opt) {
    my $self = {
        resources => $opt{resources} // $ENV{HPS_RESOURCES}
            // (($ENV{HPS_BASE} // '/srv') . '/hps-resources'),
        from   => $opt{from},
        rate   => $opt{rate},
        tries  => $opt{tries} // 3,
        pause  => $opt{pause} // 20,
        fetch  => $opt{fetch},
        dsha   => $opt{dsha},
        dread  => $opt{dread},
        pins   => $opt{pins},
        logger => $opt{logger} // sub ($msg) { print STDERR "hps-pin-fetch: $msg\n" },
        now    => $opt{now} // sub { time },
    };
    bless $self, $class;
    _fail('usage', "--from '" . ($self->{from} // '') . "' must be http://<host>[:<port>] (no path)")
        unless defined $self->{from} && $self->{from} =~ $FROM_RE;
    _fail('usage', "--rate '$self->{rate}' must be a number with an optional k, m or g")
        if defined $self->{rate} && $self->{rate} !~ $RATE_RE;
    _fail('usage', "--tries must be 1 to 10") unless $self->{tries} =~ /\A[0-9]+\z/ && $self->{tries} >= 1 && $self->{tries} <= 10;
    $self->{fetch} //= sub ($url, $dest) { $self->_curl($url, $dest) };
    $self->{dsha}  //= \&_direct_sha256;
    $self->{dread} //= \&_direct_read;
    return $self;
}

sub _fail ($kind, $msg) { die HPS::PinFetch::Error->new($kind, $msg) }

sub _log ($self, $msg) { $self->{logger}->($msg); return }

sub nixos_dir ($self) { return "$self->{resources}/nixos" }

sub _pins ($self) {
    $self->{pins} //= HPS::Pins->new(resources => $self->{resources});
    return $self->{pins};
}

# _curl($url, $dest): 1 when curl wrote $dest, else 0.
sub _curl ($self, $url, $dest) {
    my @cmd = ('curl', '--fail', '--silent', '--show-error', '--noproxy', '*', '--proto', '=http',
        '--max-redirs', '0', ($self->{rate} ? ('--limit-rate', $self->{rate}) : ()), '--output', $dest, $url);
    $self->_log("+ @cmd");
    return system(@cmd) == 0 ? 1 : 0;
}

# _direct_pipe($file): a read handle on dd iflag=direct of $file.
sub _direct_pipe ($file) {
    my $pid = open(my $fh, '-|') // return undef;
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec('dd', "if=$file", 'iflag=direct', 'bs=4M', 'status=none') or POSIX::_exit(127);
    }
    binmode $fh;
    return $fh;
}

# _direct_sha256($file): the sha256 of what the disk holds, or undef.
sub _direct_sha256 ($file) {
    my $fh = _direct_pipe($file) // return undef;
    my $d = Digest::SHA->new(256);
    $d->addfile($fh);
    close $fh or return undef;
    return $d->hexdigest;
}

# _direct_read($file): the content as the disk holds it, or undef.
sub _direct_read ($file) {
    my $fh = _direct_pipe($file) // return undef;
    local $/;
    my $t = <$fh>;
    close $fh or return undef;
    return $t // '';
}

sub _url ($self, $rel) { return "$self->{from}/$rel" }

# _get_proved($rel, $dest, $sha): fetch <from>/<rel> to $dest until its
# O_DIRECT read gives $sha. Dies failed after the tries.
sub _get_proved ($self, $rel, $dest, $sha) {
    for my $try (1 .. $self->{tries}) {
        unlink $dest;
        if ($self->{fetch}->($self->_url($rel), $dest)) {
            my $got = $self->{dsha}->($dest) // 'unreadable';
            return 1 if $got eq $sha;
            $self->_log("$rel reads back " . substr($got, 0, 12) . ', want ' . substr($sha, 0, 12) . " (try $try of $self->{tries})");
        } else {
            $self->_log("fetch of $rel failed (try $try of $self->{tries})");
        }
        unlink $dest;
        sleep $self->{pause} if $try < $self->{tries} && $self->{pause};
    }
    _fail('failed', "$rel never read back as $sha after $self->{tries} tries");
}

# _get_small($rel, $dest): fetch a small file and return its content as read
# back with O_DIRECT. Dies when it cannot be fetched or read.
sub _get_small ($self, $rel, $dest) {
    for my $try (1 .. $self->{tries}) {
        unlink $dest;
        if ($self->{fetch}->($self->_url($rel), $dest)) {
            my $t = $self->{dread}->($dest);
            return $t if defined $t && length $t;
            $self->_log("$rel reads back empty (try $try of $self->{tries})");
        } else {
            $self->_log("fetch of $rel failed (try $try of $self->{tries})");
        }
        sleep $self->{pause} if $try < $self->{tries} && $self->{pause};
    }
    _fail('notfound', "$rel could not be fetched from $self->{from}");
}

# _parse_sums($text): [[rel, sha], ...] in file order; dies on a line that
# is not "<sha256>  <profile>/<file>", "<sha256>  ipxe/<file>" or
# "<sha256>  ../firmware/<file>".
sub _parse_sums ($text) {
    my @e;
    my %seen;
    for my $line (split /\n/, $text) {
        next unless length $line;
        _fail('refused', "SHA256SUMS line is not '<sha256>  <path>': $line") unless $line =~ /\A([0-9a-f]{64})  (\S+)\z/;
        my ($sha, $rel) = ($1, $2);
        my ($a, $b) = split m{/}, $rel, 2;
        my $ok = defined $b && (
            ($a eq '..' && $b =~ m{\Afirmware/([^/]+)\z} && $1 =~ $FILE_RE)
            || ($a =~ $PROFILE_RE && $b =~ $FILE_RE));
        _fail('refused', "SHA256SUMS names an unusable path: $rel") unless $ok;
        _fail('refused', "SHA256SUMS names $rel twice") if $seen{$rel}++;
        push @e, [ $rel, $sha ];
    }
    _fail('refused', 'SHA256SUMS lists no files') unless @e;
    return \@e;
}

# fetch_pin($pin, latest => 0|1): returns {pin, files, fetched, reused,
# bytes, latest}.
sub fetch_pin ($self, $pin, %o) {
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$")
        unless defined $pin && $pin =~ $PIN_RE;
    my $nixos = $self->nixos_dir;
    _fail('notfound', "$nixos does not exist") unless -d $nixos;
    return $self->_already($pin, %o) if -e "$nixos/$pin";
    my $stage = "$nixos/.fetch-$pin-$$";
    File::Path::remove_tree($stage);
    File::Path::make_path($stage);
    my $r = eval { $self->_stage($pin, $stage) };
    if (my $err = $@) {
        File::Path::remove_tree($stage);
        die $err;
    }
    rename($stage, "$nixos/$pin") or do {
        my $e = $!;
        File::Path::remove_tree($stage);
        _fail('failed', "rename $stage to $nixos/$pin: $e");
    };
    my $ok = eval { $self->_prove_published($pin, $r->{list}); 1 };
    my $err = $@;
    unless ($ok) {
        my $aside = "$nixos/.failed-$pin-" . strftime('%Y%m%dT%H%M%SZ', gmtime($self->{now}->()));
        rename("$nixos/$pin", $aside);
        $self->_log("pin $pin moved aside to $aside");
        die $err;
    }
    my $latest = 0;
    if ($o{latest}) {
        $self->_pins->set_latest($pin);
        $latest = 1;
    }
    return { pin => $pin, files => scalar @{ $r->{list} }, fetched => $r->{fetched}, reused => $r->{reused},
        bytes => $r->{bytes}, latest => $latest };
}

# _already($pin, %o): the pin is published here already (the same content
# built twice gives the same pin name). Accepted only when the builder's
# SHA256SUMS is byte for byte the published one; every file is then proved
# on disk as after a fetch. Otherwise refused.
sub _already ($self, $pin, %o) {
    my $nixos = $self->nixos_dir;
    my $tmp = "$nixos/.fetch-$pin-$$.sums";
    my $remote = eval { $self->_get_small("$pin/SHA256SUMS", $tmp) };
    my $err = $@;
    unlink $tmp;
    die $err unless defined $remote;
    my $local = $self->{dread}->("$nixos/$pin/SHA256SUMS");
    _fail('refused', "Pin $pin is already published under $nixos with other content (hps-pins delete $pin first)")
        unless defined $local && $local eq $remote;
    my $list = _parse_sums($remote);
    $self->_prove_published($pin, $list);
    $self->_log("pin $pin was published already with the same SHA256SUMS; proved on disk");
    my $latest = 0;
    if ($o{latest}) {
        $self->_pins->set_latest($pin);
        $latest = 1;
    }
    return { pin => $pin, files => scalar @$list, fetched => 0, reused => scalar @$list, bytes => 0,
        latest => $latest, already => 1 };
}

# _target($pin, $rel): where a SHA256SUMS path goes on the IPS.
sub _target ($self, $pin, $rel) {
    return $rel =~ m{\A\.\./(firmware/.+)\z} ? $self->nixos_dir . "/$1" : $self->nixos_dir . "/$pin/$rel";
}

sub _stage ($self, $pin, $stage) {
    my $json = JSON::PP->new;
    my $sums_text = $self->_get_small("$pin/SHA256SUMS", "$stage/SHA256SUMS");
    my $list = _parse_sums($sums_text);
    my %sum = map { $_->[0] => $_->[1] } @$list;
    my (%profiles, $ipxe);
    for my $e (@$list) {
        my ($dir) = split m{/}, $e->[0];
        next if $dir eq '..';
        if ($dir eq 'ipxe') { $ipxe = 1 } else { $profiles{$dir} = 1 }
    }
    _fail('refused', "SHA256SUMS of $pin names no profile") unless %profiles;
    # boot.json of every profile agrees with SHA256SUMS.
    my %layer_named;
    for my $p (sort keys %profiles) {
        File::Path::make_path("$stage/$p");
        my $t = $self->_get_small("$pin/$p/boot.json", "$stage/$p/boot.json");
        my $b = eval { $json->decode($t) };
        _fail('refused', "$pin/$p/boot.json is not valid JSON") unless ref $b eq 'HASH';
        for my $art (qw(bzImage initrd)) {
            my $s = ref $b->{sha256} eq 'HASH' ? $b->{sha256}{$art} : undef;
            _fail('refused', "$pin/$p/boot.json records no sha256 for $art") unless defined $s;
            _fail('refused', "$pin/$p/$art: boot.json says $s, SHA256SUMS " . ($sum{"$p/$art"} // 'nothing'))
                unless defined $sum{"$p/$art"} && $sum{"$p/$art"} eq $s;
        }
        for my $x (@{ ref $b->{extra_initrds} eq 'ARRAY' ? $b->{extra_initrds} : [] }) {
            my $path = ref $x eq 'HASH' ? $x->{path} // '' : '';
            _fail('refused', "$pin/$p/boot.json names an extra initrd that is not firmware/<file>: $path")
                unless $path =~ m{\Afirmware/([^/]+)\z} && $1 =~ $FILE_RE;
            _fail('refused', "$pin/$p/boot.json: $path says " . ($x->{sha256} // 'nothing') . ', SHA256SUMS ' . ($sum{"../$path"} // 'nothing'))
                unless defined $sum{"../$path"} && defined $x->{sha256} && $sum{"../$path"} eq $x->{sha256};
            $layer_named{"../$path"} = 1;
        }
    }
    for my $rel (grep { m{\A\.\./} } keys %sum) {
        _fail('refused', "SHA256SUMS lists $rel, which no boot.json names") unless $layer_named{$rel};
    }
    if ($ipxe) {
        File::Path::make_path("$stage/ipxe");
        my $t = $self->_get_small("$pin/ipxe/ipxe.json", "$stage/ipxe/ipxe.json");
        my $j = eval { $json->decode($t) };
        _fail('refused', "$pin/ipxe/ipxe.json is not valid JSON") unless ref $j eq 'HASH' && ref $j->{sha256} eq 'HASH';
        for my $rel (grep { m{\Aipxe/} } keys %sum) {
            my $f = substr($rel, 5);
            _fail('refused', "$pin/$rel: ipxe.json says " . ($j->{sha256}{$f} // 'nothing') . ", SHA256SUMS $sum{$rel}")
                unless defined $j->{sha256}{$f} && $j->{sha256}{$f} eq $sum{$rel};
        }
    }
    # Every listed file, proved on disk.
    my ($fetched, $reused, $bytes) = (0, 0, 0);
    for my $e (@$list) {
        my ($rel, $sha) = @$e;
        if ($rel =~ m{\A\.\./(firmware/(.+))\z}) {
            my ($srv, $name) = ($1, $2);
            my $dest = $self->nixos_dir . "/$srv";
            if (-f $dest && !-l $dest && ($self->{dsha}->($dest) // '') eq $sha) {
                utime(undef, undef, $dest);
                $self->_log("layer $srv already published with this content");
                $reused++;
                next;
            }
            File::Path::make_path($self->nixos_dir . '/firmware');
            my $tmp = $self->nixos_dir . "/firmware/.$name.fetch-$$";
            my $ok = eval { $self->_get_proved($srv, $tmp, $sha); 1 };
            unless ($ok) { my $err = $@; unlink $tmp; die $err }
            rename($tmp, $dest) or do { my $e2 = $!; unlink $tmp; _fail('failed', "rename $tmp: $e2") };
            $bytes += -s $dest;
            $fetched++;
            next;
        }
        my $dest = "$stage/$rel";
        File::Path::make_path(File::Basename::dirname($dest));
        $self->_get_proved("$pin/$rel", $dest, $sha);
        $bytes += -s $dest;
        $fetched++;
    }
    return { list => $list, fetched => $fetched, reused => $reused, bytes => $bytes };
}

# _prove_published($pin, $list): every file in place reads back with O_DIRECT
# as listed (re-fetched into place, via a temporary name, on a mismatch), then
# HPS::Pins verify passes.
sub _prove_published ($self, $pin, $list) {
    for my $e (@$list) {
        my ($rel, $sha) = @$e;
        my $dest = $self->_target($pin, $rel);
        next if ($self->{dsha}->($dest) // '') eq $sha;
        $self->_log("$rel reads back differently after publishing; fetching it again");
        my $src = $rel =~ m{\A\.\./(.+)\z} ? $1 : "$pin/$rel";
        my $tmp = File::Basename::dirname($dest) . '/.' . File::Basename::basename($dest) . ".refetch-$$";
        my $ok = eval { $self->_get_proved($src, $tmp, $sha); 1 };
        unless ($ok) { my $err = $@; unlink $tmp; die $err }
        rename($tmp, $dest) or do { my $e2 = $!; unlink $tmp; _fail('failed', "rename $tmp: $e2") };
        _fail('failed', "$rel still reads back differently after fetching it again")
            unless ($self->{dsha}->($dest) // '') eq $sha;
    }
    my $v = $self->_pins->verify_pin($pin);
    unless ($v->{ok}) {
        my $why = join('; ', map { "$_->{file}: $_->{reason}" } @{ $v->{failures} });
        _fail('failed', "Pin $pin does not verify after the fetch ($why)");
    }
    return 1;
}

1;
