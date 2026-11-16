package HPS::Starter;
# The IPS's stock starter and package repository, per OS, as plain files
# (docs/STARTER.md; plan step 1).
#
#   <resources>/starter/<os>/<version>/{bzImage,initrd,netboot.ipxe,manifest.json}
#       the distribution's own netboot kernel and initramfs, unmodified;
#       served at /starter/<os>/<version>/
#   <resources>/packages/<os>/<version>/{nix-cache-info,<hash>.narinfo,nar/*,manifest.json}
#       a plain HTTP Nix binary cache (NixOS); served at /packages/<os>/<version>/
#
# sync fills both from upstream while upstream is reachable, through the
# site's egress proxy when one is set. Every file is fetched to a temporary
# name, checked, then renamed; a file already present with the recorded size
# and sha256 is kept. Each directory ends with a manifest.json (written last)
# that records the upstream release, and for every file its size and sha256
# and where it came from.
#
# NixOS starter:   Hydra's stock netboot build of the release job
#                  (nixos/release-<version>/nixos.netboot.x86_64-linux).
# NixOS repository: the closure of the packages named in the package list,
#                  from cache.nixos.org, narinfo and nar files exactly as
#                  published (the upstream signatures stay). The IPS has no
#                  nix: names are resolved to store paths through the
#                  release's own store-paths.xz, the system is told apart by
#                  the glibc of the starter's own system closure, and the
#                  closure is walked through the References of the narinfos.
#
# Downloads use curl. xz (xz-utils) is needed on the syncing host to read
# store-paths.xz, unless --store-paths gives the list already decompressed.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Digest::SHA ();
use File::Path ();
use File::Basename ();
use File::Copy ();
use POSIX qw(strftime);

package HPS::Starter::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $OS_RE   = qr/\A[a-z][a-z0-9]{0,15}\z/;
my $VER_RE  = qr/\A[0-9][0-9A-Za-z.-]{0,31}\z/;
my $HASH_RE = qr/[0-9a-df-np-sv-z]{32}/;
my $NIX32   = '0123456789abcdfghijklmnpqrsvwxyz';
my $PROXY_RE = qr{\Ahttp://[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[0-9]{1,5}\z};

# Per OS: the release synced when none is named, and whether it exists yet.
my %OS = (
    nixos  => { release => '26.05', implemented => 1 },
    alpine => { release => '3.22',  implemented => 0, step => 4 },
);

my %UPSTREAM = (
    hydra    => 'https://hydra.nixos.org',
    releases => 'https://releases.nixos.org',
    cache    => 'https://cache.nixos.org',
);

sub new ($class, %opt) {
    my $self = {
        resources  => $opt{resources} // $ENV{HPS_RESOURCES}
            // (($ENV{HPS_BASE} // '/srv') . '/hps-resources'),
        proxy      => $opt{proxy},
        hydra      => $opt{hydra}    // $UPSTREAM{hydra},
        releases   => $opt{releases} // $UPSTREAM{releases},
        cache      => $opt{cache}    // $UPSTREAM{cache},
        packages   => $opt{packages},      # package list file
        store_paths => $opt{store_paths},  # store path list (plain or .xz), instead of the release's
        curl       => $opt{curl} // 'curl',
        logger     => $opt{logger} // sub ($msg) { print STDERR "hps-starter: $msg\n" },
        now        => $opt{now} // sub { time },
        ni         => {},                  # hash => parsed narinfo
        name       => {},                  # hash => store path name
    };
    s{/+\z}{} for grep { defined } @{$self}{qw(hydra releases cache)};
    bless $self, $class;
    _fail('usage', "--proxy '$self->{proxy}' must be http://<host>:<port>")
        if defined $self->{proxy} && length $self->{proxy} && $self->{proxy} !~ $PROXY_RE;
    $self->{proxy} = undef unless defined $self->{proxy} && length $self->{proxy};
    return $self;
}

sub _fail ($kind, $msg) { die HPS::Starter::Error->new($kind, $msg) }
sub _log ($self, $msg) { $self->{logger}->($msg); return }

sub default_release ($class, $os) { return $OS{$os} ? $OS{$os}{release} : undef }

sub starter_dir ($self, $os, $ver) { return "$self->{resources}/starter/$os/$ver" }
sub repo_dir ($self, $os, $ver)    { return "$self->{resources}/packages/$os/$ver" }

sub _check_os_version ($self, $os, $ver) {
    _fail('usage', "OS '" . ($os // '') . "' must be a lower-case word") unless defined $os && $os =~ $OS_RE;
    _fail('usage', "OS '$os' is not known (known: " . join(', ', sort keys %OS) . ')') unless $OS{$os};
    $ver //= $OS{$os}{release};
    _fail('usage', "release '$ver' must look like 26.05") unless $ver =~ $VER_RE;
    return $ver;
}

#--- small helpers --------------------------------------------------------

sub _slurp ($file) {
    open(my $fh, '<:raw', $file) or _fail('failed', "cannot read $file: $!");
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

sub _spit ($file, $text) {
    File::Path::make_path(File::Basename::dirname($file));
    my $tmp = File::Basename::dirname($file) . '/.' . File::Basename::basename($file) . ".tmp-$$";
    open(my $fh, '>:raw', $tmp) or _fail('failed', "cannot write $tmp: $!");
    print {$fh} $text;
    close $fh or _fail('failed', "cannot write $tmp: $!");
    rename $tmp, $file or _fail('failed', "cannot rename $tmp to $file: $!");
    return;
}

# _sha_file($file): (hex, raw) of its sha256, or () when unreadable.
sub _sha_file ($file) {
    open(my $fh, '<:raw', $file) or return;
    my $d = Digest::SHA->new(256);
    $d->addfile($fh);
    close $fh;
    my $raw = $d->digest;
    return (unpack('H*', $raw), $raw);
}

# nix32($raw): Nix's base-32 text of a digest (narinfo FileHash is sha256:<this>).
sub nix32 ($raw) {
    my @c = split //, $NIX32;
    my $len = int((length($raw) * 8 - 1) / 5) + 1;
    my $out = '';
    for (my $n = $len - 1; $n >= 0; $n--) {
        my $b = $n * 5;
        my $i = int($b / 8);
        my $j = $b % 8;
        my $v = ord(substr($raw, $i, 1)) >> $j;
        $v |= ord(substr($raw, $i + 1, 1)) << (8 - $j) if $i + 1 < length($raw);
        $out .= $c[$v & 0x1f];
    }
    return $out;
}

# _file_is($file, $size, $sha): true when present with that size and sha256.
sub _file_is ($file, $size, $sha) {
    return 0 unless -f $file;
    return 0 if defined $size && (-s $file) != $size;
    return 1 unless defined $sha;
    my ($hex) = _sha_file($file);
    return defined $hex && $hex eq $sha ? 1 : 0;
}

sub _now_text ($self) { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($self->{now}->())) }

sub _json ($data) { return JSON::PP->new->canonical->pretty->encode($data) }

sub _host ($url) { return $url =~ m{\A[a-z]+://([^/:]+)}i ? $1 : 'local file' }

#--- fetching ---------------------------------------------------------------

# _fetch($pairs, %o): fetch [url, dest] pairs with curl, a few at a time over
# one connection. Dies (failed) naming the host of every URL that did not
# arrive. headers => [..] are sent with every request.
sub _fetch ($self, $pairs, %o) {
    my @todo = @$pairs;
    my @bad;
    File::Path::make_path($self->{resources});
    my $errfile = "$self->{resources}/.hps-starter-curl-err-$$";
    while (my @chunk = splice(@todo, 0, $o{chunk} // 40)) {
        File::Path::make_path(File::Basename::dirname($_->[1])) for @chunk;
        unlink $_->[1] for @chunk;
        my @cmd = ($self->{curl}, '--fail', '--silent', '--show-error', '--location', '--max-redirs', '5',
            '--connect-timeout', '20', '--retry', '2',
            ($self->{proxy} ? ('--proxy', $self->{proxy}) : ('--noproxy', '*')),
            (map { ('--header', $_) } @{ $o{headers} // [] }),
            (@chunk > 1 ? ('--parallel', '--parallel-max', '6') : ()),
            (map { ('--output', $_->[1], $_->[0]) } @chunk));
        open(my $olderr, '>&', \*STDERR) or _fail('failed', "cannot save stderr: $!");
        open(STDERR, '>', $errfile) or _fail('failed', "cannot open $errfile: $!");
        my $rc = system(@cmd);
        open(STDERR, '>&', $olderr);
        close $olderr;
        my $err = -f $errfile ? _slurp($errfile) : '';
        unlink $errfile;
        $err =~ s/\s+\z//;
        for my $p (@chunk) {
            next if -s $p->[1];
            unlink $p->[1];
            push @bad, [ $p->[0], $err || ($rc == -1 ? "cannot run $self->{curl}: $!" : "curl exit " . ($rc >> 8)) ];
        }
    }
    return 1 unless @bad;
    my %seen;
    my @msg = map { "host " . _host($_->[0]) . ": $_->[1] ($_->[0])" } grep { !$seen{ $_->[0] }++ } @bad[0 .. ($#bad > 4 ? 4 : $#bad)];
    my $via = $self->{proxy} ? " via proxy $self->{proxy}" : ' (no proxy)';
    _fail('failed', 'upstream refused or unreachable' . $via . ': ' . join('; ', @msg)
        . (@bad > 5 ? '; and ' . (@bad - 5) . ' more' : ''));
}

sub _fetch_text ($self, $url, %o) {
    my $tmp = "$self->{resources}/.hps-starter-text-$$";
    File::Path::make_path($self->{resources});
    $self->_fetch([ [ $url, $tmp ] ], %o);
    my $t = _slurp($tmp);
    unlink $tmp;
    return $t;
}

#--- manifests --------------------------------------------------------------

sub read_manifest ($self, $dir) {
    my $f = "$dir/manifest.json";
    return undef unless -f $f;
    my $m = eval { JSON::PP::decode_json(_slurp($f)) };
    _fail('failed', "$f is not valid JSON: $@") unless ref $m eq 'HASH';
    return $m;
}

# check_files($dir, \%files): [reason...] for every manifest file that is
# missing or differs in size or sha256.
sub check_files ($self, $dir, $files) {
    my @bad;
    for my $rel (sort keys %$files) {
        my $e = $files->{$rel};
        my $f = "$dir/$rel";
        if (!-f $f)                         { push @bad, "$rel: missing"; next }
        if ((-s $f) != $e->{size})          { push @bad, "$rel: size " . (-s $f) . ", recorded $e->{size}"; next }
        my ($hex) = _sha_file($f);
        push @bad, "$rel: sha256 differs from the manifest" unless defined $hex && $hex eq $e->{sha256};
    }
    return \@bad;
}

#--- sync -------------------------------------------------------------------

# sync($os, $ver, only => 'starter'|'repository'): fill the starter and the
# repository (or one of them; the repository needs a synced starter, whose
# release it follows). Returns {os, version, release, starter => {...},
# repo => {...}}, a part not run is undef.
sub sync ($self, $os, $ver = undef, %o) {
    $ver = $self->_check_os_version($os, $ver);
    _fail('refused', "$os: not yet implemented (plan step $OS{$os}{step})") unless $OS{$os}{implemented};
    my $only = $o{only};
    _fail('usage', "--only '$only' must be starter or repository") if defined $only && $only !~ /\A(?:starter|repository)\z/;
    my $st = defined $only && $only eq 'repository' ? $self->_starter_state($ver) : $self->_sync_nixos_starter($ver);
    my $rp = defined $only && $only eq 'starter' ? undef : $self->_sync_nixos_repo($ver, $st);
    return { os => $os, version => $ver, release => $st->{release}, starter => defined $only && $only eq 'repository' ? undef : $st, repo => $rp };
}

# _starter_state($ver): what the repository needs of the synced starter.
sub _starter_state ($self, $ver) {
    my $dir = $self->starter_dir('nixos', $ver);
    my $m = $self->read_manifest($dir) // _fail('notfound', "no starter synced for nixos $ver: run hps-starter sync nixos first");
    return { dir => $dir, release => $m->{release}, build => $m->{build}, init => $m->{init} };
}

# --- NixOS starter ---

sub _sync_nixos_starter ($self, $ver) {
    my $dir = $self->starter_dir('nixos', $ver);
    my $job = "nixos/release-$ver/nixos.netboot.x86_64-linux";
    $self->_log("starter: asking $self->{hydra} for the latest finished $job");
    my $json = $self->_fetch_text("$self->{hydra}/job/$job/latest-finished", headers => ['Accept: application/json']);
    my $b = eval { JSON::PP::decode_json($json) };
    _fail('failed', "$self->{hydra}: the latest-finished answer for $job is not JSON") unless ref $b eq 'HASH';
    _fail('failed', "$job: latest finished build $b->{id} is not a success (buildstatus " . ($b->{buildstatus} // '?') . ')')
        unless ($b->{buildstatus} // 1) == 0 && $b->{id};
    my %prod;
    for my $n (keys %{ $b->{buildproducts} // {} }) {
        my $p = $b->{buildproducts}{$n};
        $prod{ $p->{name} } = { n => $n, size => $p->{filesize}, sha256 => $p->{sha256hash} };
    }
    for my $want (qw(bzImage initrd netboot.ipxe)) {
        _fail('failed', "$job build $b->{id} has no product $want") unless $prod{$want} && $prod{$want}{sha256};
    }
    my $old = $self->read_manifest($dir);
    my (%files, @fetch, $reused, $fetched);
    $reused = $fetched = 0;
    for my $name (qw(bzImage initrd netboot.ipxe)) {
        my $p = $prod{$name};
        $files{$name} = { url => "$self->{hydra}/build/$b->{id}/download/$p->{n}/$name", size => $p->{size} + 0, sha256 => $p->{sha256} };
        if (_file_is("$dir/$name", $p->{size}, $p->{sha256})) { $reused++; next }
        push @fetch, $name;
    }
    File::Path::make_path($dir);
    my $tmpsuffix = ".tmp-$$";
    for my $name (@fetch) {
        $self->_log("starter: fetching $name ($files{$name}{size} bytes) from " . _host($files{$name}{url}));
        my $tmp = "$dir/.$name$tmpsuffix";
        $self->_fetch([ [ $files{$name}{url}, $tmp ] ]);
        my ($hex) = _sha_file($tmp);
        my $size = -s $tmp;
        if (($hex // '') ne $files{$name}{sha256} || $size != $files{$name}{size}) {
            unlink $tmp;
            _fail('failed', "$name from $files{$name}{url}: size $size / sha256 " . substr($hex // 'none', 0, 12)
                . " differ from Hydra's record ($files{$name}{size} / " . substr($files{$name}{sha256}, 0, 12) . ')');
        }
    }
    for my $name (@fetch) {
        rename "$dir/.$name$tmpsuffix", "$dir/$name" or _fail('failed', "cannot rename into $dir/$name: $!");
        $fetched++;
    }
    my ($cmdline, $init) = _parse_netboot("$dir/netboot.ipxe");
    my ($release) = $init =~ m{-([0-9]+\.[0-9]+\.[0-9]+\.[0-9a-f]+)/init\z}
        or _fail('failed', "$dir/netboot.ipxe: cannot read the release from init=$init");
    my %m = (
        schema => 'hps-starter/1', os => 'nixos', version => $ver, arch => 'x86_64',
        release => $release, build => $b->{id} + 0, job => $job, upstream => $self->{hydra},
        init => $init, cmdline => $cmdline, files => \%files, synced_at => $self->_now_text,
    );
    if (!$fetched && $old && ($old->{release} // '') eq $release && ($old->{build} // 0) == $b->{id}) {
        $m{synced_at} = $old->{synced_at} // $m{synced_at};
    }
    _spit("$dir/manifest.json", _json(\%m));
    return { dir => $dir, release => $release, build => $b->{id}, init => $init, files => 3, fetched => $fetched, reused => $reused,
        bytes => $files{bzImage}{size} + $files{initrd}{size} };
}

# _parse_netboot($file): (cmdline, init path) from the kernel line of Hydra's
# netboot.ipxe: the arguments after the kernel name, without ${cmdline}.
sub _parse_netboot ($file) {
    my $text = _slurp($file);
    my ($args) = $text =~ /^kernel\s+\S+\s+(.*?)\s*$/m or _fail('failed', "$file has no kernel line");
    $args =~ s/\s*\$\{cmdline\}//;
    my ($init) = $args =~ /(?:\A|\s)init=(\S+)/ or _fail('failed', "$file: the kernel line has no init=");
    return ($args, $init);
}

# --- NixOS repository ---

# package_list($file): [[name, output|undef, store path|undef]...] from the list
# file. A line is NAME [OUTPUT], or NAME /nix/store/<hash>-<name>: the store path
# is then the root as it stands, with no search of the release's store-paths
# list (for a name the release holds in several versions, such as openssl, or
# for a path the starter already holds, such as the Perl module JSON).
sub package_list ($self, $file) {
    my @p;
    for my $line (split /\n/, _slurp($file)) {
        $line =~ s/#.*//;
        $line =~ s/\A\s+|\s+\z//g;
        next unless length $line;
        my ($name, $out, @rest) = split ' ', $line;
        my $store;
        if (defined $out && $out =~ m{\A/nix/store/$HASH_RE-[A-Za-z0-9._+-]+\z}) { $store = $out; $out = undef }
        _fail('usage', "$file: '$line' is not NAME [OUTPUT] or NAME STORE-PATH") if @rest || $name !~ /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/ || (defined $out && $out !~ /\A[a-z]+\z/);
        push @p, [ $name, $out, $store ];
    }
    _fail('usage', "$file names no package") unless @p;
    return \@p;
}

sub _sync_nixos_repo ($self, $ver, $st) {
    my $dir  = $self->repo_dir('nixos', $ver);
    $self->{localdir} = "$self->{resources}/local/nixos/$ver";
    my $list = $self->{packages} // _fail('usage', 'the package list file is not set');
    my $pk   = $self->package_list($list);
    my ($pk_sha) = _sha_file($list);
    my $old  = $self->read_manifest($dir);
    if ($old && ($old->{release} // '') eq $st->{release} && ($old->{packages_sha256} // '') eq $pk_sha
        && !@{ $self->check_files($dir, $old->{files}) }) {
        $self->_log("repository: release $st->{release} and the package list are unchanged; every file is present and proved");
        return { dir => $dir, paths => $old->{paths}, files => scalar(keys %{ $old->{files} }), fetched => 0,
            reused => scalar(keys %{ $old->{files} }), bytes => $old->{bytes}, roots => $old->{roots} };
    }
    File::Path::make_path($dir);
    my $work = "$dir/.work-$$";
    my $r = eval { $self->_build_repo($ver, $st, $dir, $work, $pk, $pk_sha, $old) };
    my $err = $@;
    File::Path::remove_tree($work) if -d $work;
    die $err unless $r;
    return $r;
}

sub _build_repo ($self, $ver, $st, $dir, $work, $pk, $pk_sha, $old) {
    File::Path::make_path($work);
    # 1. names -> candidate store paths, from the release's own list
    my $sp_url = "$self->{releases}/nixos/$ver/nixos-$st->{release}/store-paths.xz";
    my $sp_file = $self->{store_paths};
    my $sp_sha;
    unless (defined $sp_file) {
        $sp_file = "$work/store-paths.xz";
        $self->_log("repository: fetching $sp_url");
        $self->_fetch([ [ $sp_url, $sp_file ] ]);
    }
    ($sp_sha) = _sha_file($sp_file);
    my $cand = $self->_candidates($sp_file, $pk);
    # 2. which of them is x86_64: the one whose closure holds the starter's glibc
    my ($sys) = $st->{init} =~ m{\A/nix/store/($HASH_RE-[^/]+)/init\z}
        or _fail('failed', "the starter's init path '$st->{init}' is not a store path");
    my $glibc = $self->_anchor_glibc(substr($sys, 0, 32), $dir, $work, $old);
    my %roots;
    for my $p (@$pk) {
        if (defined $p->[2]) {
            $roots{$p->[0]} = $p->[2];
            $self->_log("repository: $p->[0] -> $p->[2] (named in the package list)");
            next;
        }
        my $key = defined $p->[1] ? "$p->[0]:$p->[1]" : $p->[0];
        my @hashes = @{ $cand->{$key} // [] };
        _fail('failed', "package '$key': no store path of that name in the release's store-paths list") unless @hashes;
        my (@x86, @why);
        for my $h (@hashes) {
            my $c = eval { $self->_closure($h, $dir, $work, $old) };
            if ($c) { push @x86, $h if $c->{$glibc} }
            else    { my $e = $@; push @why, ref $e ? $e->message : $e }
        }
        _fail('failed', "package '$key': none of " . scalar(@hashes) . " candidates has the starter's glibc ($glibc) in its closure"
            . (@why ? ' (' . join('; ', @why) . ')' : '') . '; cannot tell which is x86_64')
            unless @x86;
        _fail('failed', "package '$key': several x86_64 candidates: " . join(', ', map { "$_-$self->{name}{$_}" } @x86))
            if @x86 > 1;
        $roots{$key} = "/nix/store/$x86[0]-$self->{name}{$x86[0]}";
        $self->_log("repository: $key -> $roots{$key}");
    }
    my %closure;
    for my $key (keys %roots) {
        my ($h) = $roots{$key} =~ m{/nix/store/($HASH_RE)-};
        $closure{$_} = 1 for keys %{ $self->_closure($h, $dir, $work, $old) };
    }
    my @hashes = sort keys %closure;
    $self->_log('repository: closure of ' . scalar(@hashes) . ' store paths');
    # 3. write narinfos, then fetch and prove nars
    my (%files, %nar_of, $fetched, $reused, $bytes);
    $fetched = $reused = $bytes = 0;
    my @need;
    for my $h (@hashes) {
        my $ni = $self->{ni}{$h};
        my $rel = "$h.narinfo";
        $files{$rel} = { size => length($ni->{raw}), sha256 => Digest::SHA::sha256_hex($ni->{raw}) };
        my $nar = $ni->{url};
        $nar_of{$nar} = $ni;
        # A nar is proved against its narinfo: FileSize and FileHash (sha256, nix base-32).
        my ($hex, $raw) = (-f "$dir/$nar" && (-s "$dir/$nar") == $ni->{filesize}) ? _sha_file("$dir/$nar") : ();
        if (defined $raw && 'sha256:' . nix32($raw) eq $ni->{filehash}) {
            $files{$nar} = { size => $ni->{filesize}, sha256 => $hex };
            $reused++;
        }
        else { push @need, $nar }
        $bytes += $ni->{filesize};
    }
    my $total = @need;
    my $n = 0;
    while (my @batch = splice(@need, 0, 8)) {
        $n += @batch;
        $self->_log("repository: fetching nar files $n of $total");
        my @up = grep { !($self->{localdir} && -f "$self->{localdir}/$_") } @batch;
        $self->_fetch([ map { [ "$self->{cache}/$_", "$dir/.tmp-$$/$_" ] } @up ], chunk => 8) if @up;
        for my $nar (grep { $self->{localdir} && -f "$self->{localdir}/$_" } @batch) {
            File::Path::make_path(File::Basename::dirname("$dir/.tmp-$$/$nar"));
            File::Copy::copy("$self->{localdir}/$nar", "$dir/.tmp-$$/$nar") or _fail('failed', "cannot copy local $nar: $!");
        }
        for my $nar (@batch) {
            my $t = "$dir/.tmp-$$/$nar";
            my ($hex, $raw) = _sha_file($t);
            my $ni = $nar_of{$nar};
            if (!defined $raw || 'sha256:' . nix32($raw) ne $ni->{filehash} || (-s $t) != $ni->{filesize}) {
                unlink $t;
                _fail('failed', "$nar from $self->{cache}/$nar: size or sha256 differ from its narinfo ($ni->{filesize} bytes, $ni->{filehash})");
            }
            File::Path::make_path(File::Basename::dirname("$dir/$nar"));
            rename $t, "$dir/$nar" or _fail('failed', "cannot rename into $dir/$nar: $!");
            $files{$nar} = { size => $ni->{filesize}, sha256 => $hex };
            $fetched++;
        }
    }
    File::Path::remove_tree("$dir/.tmp-$$") if -d "$dir/.tmp-$$";
    for my $h (@hashes) {
        my $rel = "$h.narinfo";
        _spit("$dir/$rel", $self->{ni}{$h}{raw}) unless _file_is("$dir/$rel", $files{$rel}{size}, $files{$rel}{sha256});
    }
    my $info = "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n";
    _spit("$dir/nix-cache-info", $info);
    $files{'nix-cache-info'} = { size => length($info), sha256 => Digest::SHA::sha256_hex($info) };
    # 4. what the new set does not hold is dropped, then the manifest closes the sync
    $self->_prune($dir, \%files);
    my %m = (
        schema => 'hps-repo/1', os => 'nixos', version => $ver, kind => 'nix-binary-cache',
        release => $st->{release}, upstream => $self->{cache},
        store_paths => { url => $sp_url, sha256 => $sp_sha },
        packages_sha256 => $pk_sha, packages => [ map { defined $_->[1] ? "$_->[0]:$_->[1]" : $_->[0] } @$pk ],
        roots => \%roots, paths => scalar(@hashes), bytes => $bytes, files => \%files,
        synced_at => $self->_now_text,
    );
    _spit("$dir/manifest.json", _json(\%m));
    return { dir => $dir, paths => scalar(@hashes), files => scalar(keys %files), fetched => $fetched, reused => $reused,
        bytes => $bytes, roots => \%roots };
}

# _candidates($file, $pk): {name[:output] => [hash...]} from the store path list.
sub _candidates ($self, $file, $pk) {
    my $fh;
    if (_slurp_head($file) =~ /\A\xFD7zXZ\x00/) {
        my $xz = _which('xz') // _fail('failed',
            "xz is not installed on this host, so $file cannot be read: install the xz-utils package, "
            . 'or give --store-paths with the list already decompressed (xz -dc store-paths.xz)');
        open($fh, '-|', $xz, '-dc', $file) or _fail('failed', "cannot run xz on $file: $!");
    }
    else {
        open($fh, '<', $file) or _fail('failed', "cannot read $file: $!");
    }
    my @pat = map { my ($n, $o) = @$_; [ defined $o ? "$n:$o" : $n,
        qr/\A(?:perl[0-9][0-9.]*-)?\Q$n\E-[0-9][0-9A-Za-z.]*@{[ defined $o ? '-' . quotemeta($o) : '' ]}\z/ ] } grep { !defined $_->[2] } @$pk;
    my (%out, %seen);
    local $/ = "\n";
    while (my $l = <$fh>) {
        chomp $l;
        my ($h, $name) = $l =~ m{\A/nix/store/($HASH_RE)-(.+)\z} or next;
        for my $p (@pat) {
            next unless $name =~ $p->[1];
            next if $seen{$h}++;
            push @{ $out{ $p->[0] } }, $h;
            $self->{name}{$h} = $name;
        }
    }
    close $fh or _fail('failed', "reading $file failed: $?") if $fh;
    return \%out;
}

# add_local($os, $ver, $from, \@paths): local packages. Copies the narinfo and nar
# of each store path and of its closure from <from>, a binary cache laid out as
# hps-starter's own (<hash>.narinfo, nar/<file>), into <resources>/local/<os>/<ver>/,
# leaving out what the repository already holds. The next sync takes them into the
# repository beside the upstream ones, and a package list line naming the path
# (NAME /nix/store/<path>) makes it a root. Returns {added => N, held => N}.
sub add_local ($self, $os, $ver, $from, $paths) {
    _fail('usage', "local packages are for nixos only") unless $os eq 'nixos';
    $self->_check_os_version($os, $ver);
    $from =~ s{/+\z}{};
    my $repo = $self->repo_dir($os, $ver);
    my $ldir = "$self->{resources}/local/$os/$ver";
    my (%seen, @todo, $added, $held);
    $added = $held = 0;
    for my $p (@$paths) {
        $p =~ m{\A/nix/store/($HASH_RE)-[A-Za-z0-9._+-]+\z} or _fail('usage', "'$p' is not a store path");
        push @todo, $1;
    }
    while (defined(my $h = shift @todo)) {
        next if $seen{$h}++;
        if (-f "$repo/$h.narinfo" && !-f "$ldir/$h.narinfo") { $held++; next }
        my $src = "$from/$h.narinfo";
        -f $src or _fail('notfound', "no narinfo for $h in $from");
        my $ni = _parse_narinfo(_slurp($src), $src);
        my $nar = "$from/$ni->{url}";
        -f $nar or _fail('notfound', "$src names $ni->{url}, which is not in $from");
        _fail('failed', "$nar: size differs from its narinfo") unless (-s $nar) == $ni->{filesize};
        File::Path::make_path("$ldir/nar");
        File::Copy::copy($nar, "$ldir/$ni->{url}") or _fail('failed', "cannot copy $nar: $!");
        File::Copy::copy($src, "$ldir/$h.narinfo") or _fail('failed', "cannot copy $src: $!");
        $added++;
        push @todo, keys %{ $ni->{refs} };
    }
    return { added => $added, held => $held, dir => $ldir };
}

sub _slurp_head ($file) {

    open(my $fh, '<:raw', $file) or _fail('failed', "cannot read $file: $!");
    read($fh, my $h, 6);
    close $fh;
    return $h // '';
}

sub _which ($cmd) {
    for my $d (split /:/, $ENV{PATH} // '/usr/bin:/bin') { return "$d/$cmd" if -x "$d/$cmd" }
    return undef;
}

# _parse_narinfo($text, $what): {url, filehash, filesize, refs => [hash], raw}
sub _parse_narinfo ($text, $what) {
    my %f;
    for my $l (split /\n/, $text) { $f{$1} = $2 // '' if $l =~ /\A([A-Za-z]+):(?: (.*))?\z/ }  # an empty value has no space after the colon
    for my $k (qw(StorePath URL FileHash FileSize)) {
        _fail('failed', "$what: narinfo has no $k") unless exists $f{$k};
    }
    _fail('failed', "$what: URL '$f{URL}' is not nar/<file>") unless $f{URL} =~ m{\Anar/[A-Za-z0-9._-]+\z};
    _fail('failed', "$what: FileHash '$f{FileHash}' is not sha256") unless $f{FileHash} =~ /\Asha256:[0-9a-df-np-sv-z]+\z/;
    _fail('failed', "$what: FileSize '$f{FileSize}' is not a number") unless $f{FileSize} =~ /\A[0-9]+\z/;
    my ($self_name) = $f{StorePath} =~ m{\A/nix/store/$HASH_RE-(.+)\z} or _fail('failed', "$what: bad StorePath '$f{StorePath}'");
    my %refs;
    for my $r (split ' ', $f{References} // '') {   # a path that refers to nothing has no References line
        my ($h, $n) = $r =~ /\A($HASH_RE)-(.+)\z/ or _fail('failed', "$what: bad reference '$r'");
        $refs{$h} = $n;
    }
    return { url => $f{URL}, filehash => $f{FileHash}, filesize => $f{FileSize} + 0, name => $self_name, refs => \%refs, raw => $text };
}

# _need($hashes, $dir, $work, $old): have the narinfo of each hash in memory:
# from the repository's own copy when the last manifest vouches for it, else
# from upstream (all missing ones in one batch).
sub _need ($self, $hashes, $dir, $work, $old) {
    my @fetch;
    for my $h (@$hashes) {
        next if $self->{ni}{$h};
        my $rel = "$h.narinfo";
        my $e = $old ? $old->{files}{$rel} : undef;
        if ($e && _file_is("$dir/$rel", $e->{size}, $e->{sha256})) {
            $self->{ni}{$h} = _parse_narinfo(_slurp("$dir/$rel"), "$dir/$rel");
            $self->{name}{$h} = $self->{ni}{$h}{name};
            next;
        }
        my $lf = $self->{localdir} ? "$self->{localdir}/$rel" : undef;
        if ($lf && -f $lf) {    # a local package: placed by hps-starter add-local, used as it is
            $self->{ni}{$h} = _parse_narinfo(_slurp($lf), $lf);
            $self->{name}{$h} = $self->{ni}{$h}{name};
            next;
        }
        push @fetch, $h;
    }
    return unless @fetch;
    $self->_fetch([ map { [ "$self->{cache}/$_.narinfo", "$work/ni/$_.narinfo" ] } @fetch ]);
    for my $h (@fetch) {
        $self->{ni}{$h} = _parse_narinfo(_slurp("$work/ni/$h.narinfo"), "$self->{cache}/$h.narinfo");
        $self->{name}{$h} = $self->{ni}{$h}{name};
    }
    return;
}

# _closure($hash, ...): {hash => 1} of the store paths it needs, by References.
sub _closure ($self, $root, $dir, $work, $old) {
    my %seen = ($root => 1);
    my @level = ($root);
    while (@level) {
        $self->_need(\@level, $dir, $work, $old);
        my @next;
        for my $h (@level) {
            for my $r (keys %{ $self->{ni}{$h}{refs} }) {
                next if $seen{$r}++;
                $self->{name}{$r} //= $self->{ni}{$h}{refs}{$r};
                push @next, $r;
            }
        }
        @level = @next;
    }
    return \%seen;
}

# _anchor_glibc($sys_hash, ...): the hash of the glibc the starter's system uses.
sub _anchor_glibc ($self, $sys, $dir, $work, $old) {
    my %seen = ($sys => 1);
    my @level = ($sys);
    while (@level) {
        $self->_need(\@level, $dir, $work, $old);
        my @next;
        for my $h (@level) {
            for my $r (sort keys %{ $self->{ni}{$h}{refs} }) {
                my $n = $self->{ni}{$h}{refs}{$r};
                return $r if $n =~ /\Aglibc-[0-9][0-9.]*-[0-9]+\z/;
                next if $seen{$r}++;
                push @next, $r;
            }
        }
        @level = @next;
    }
    _fail('failed', "no glibc in the closure of the starter's system $sys; cannot tell x86_64 from other systems");
}

sub _prune ($self, $dir, $files) {
    return unless opendir(my $dh, $dir);
    my @top = grep { /\A$HASH_RE\.narinfo\z/ } readdir $dh;
    closedir $dh;
    for my $f (@top) { unlink "$dir/$f" unless $files->{$f} }
    if (opendir(my $nh, "$dir/nar")) {
        for my $f (grep { !/\A\./ } readdir $nh) { unlink "$dir/nar/$f" unless $files->{"nar/$f"} }
        closedir $nh;
    }
    return;
}

#--- list and verify --------------------------------------------------------

# entries(): [{kind, os, version, dir, manifest}] of every synced starter and repository.
sub entries ($self) {
    my @e;
    for my $kind (qw(starter packages)) {
        my $root = "$self->{resources}/$kind";
        next unless opendir(my $od, $root);
        for my $os (sort grep { /$OS_RE/ } readdir $od) {
            next unless opendir(my $vd, "$root/$os");
            for my $v (sort grep { /$VER_RE/ } readdir $vd) {
                my $m = eval { $self->read_manifest("$root/$os/$v") } or next;
                next unless ($m->{schema} // '') =~ /\Ahps-(?:starter|repo)\/1\z/;
                push @e, { kind => $kind eq 'starter' ? 'starter' : 'repository', os => $os, version => $v, dir => "$root/$os/$v", manifest => $m };
            }
            closedir $vd;
        }
        closedir $od;
    }
    return @e;
}

sub list ($self) {
    return map {
        my $m = $_->{manifest};
        my $bytes = 0;
        $bytes += $_->{size} for values %{ $m->{files} };
        { kind => $_->{kind}, os => $_->{os}, version => $_->{version}, release => $m->{release},
          files => scalar(keys %{ $m->{files} }), bytes => $bytes, synced_at => $m->{synced_at}, dir => $_->{dir} }
    } $self->entries;
}

# verify($os, $ver): [{kind, os, version, files, bad => [reason]}] for what is
# synced (all of it, or one OS and release).
sub verify ($self, $os = undef, $ver = undef) {
    my @e = $self->entries;
    @e = grep { $_->{os} eq $os } @e if defined $os;
    @e = grep { $_->{version} eq $ver } @e if defined $ver;
    _fail('notfound', 'nothing synced' . (defined $os ? " for $os" . (defined $ver ? " $ver" : '') : '')) unless @e;
    return [ map { { kind => $_->{kind}, os => $_->{os}, version => $_->{version}, release => $_->{manifest}{release},
        files => scalar(keys %{ $_->{manifest}{files} }), bad => $self->check_files($_->{dir}, $_->{manifest}{files}) } } @e ];
}

1;
