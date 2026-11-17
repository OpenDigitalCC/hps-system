package HPS::Starter::Alpine;
# The Alpine side of hps-starter (docs/STARTER.md "Alpine"; plan step 4).
#
#   <resources>/packages/alpine/<ver>/{main,community}/x86_64/{APKINDEX.tar.gz,*.apk}
#       the closure of the package list, from ONE repository snapshot, exactly as
#       Alpine publishes it (its signed index, its signed packages), so apk on the
#       node verifies everything with the stock keys;
#   <resources>/packages/alpine/<ver>/local/x86_64/{APKINDEX.tar.gz,*.apk}
#       the local packages (hps-starter add-local), with an unsigned index: the ones the
#       package list marks local and every other local package they need, in the place of
#       the snapshot's package of the same name (the AppArmor build of libvirt is a set);
#   <resources>/starter/alpine/<ver>/{vmlinuz-lts,initramfs-lts,manifest.json}
#       the kernel and initramfs, the kernel-matched set.
#
# Why a matched set: the stock netboot kernel of a point release lags the
# repository (3.24.4 shipped 6.18.60, the repository's zfs-lts was built for
# 6.18.63), and a ZFS module loads only into the kernel it was built for. When
# the netboot kernel is the repository's, the stock files are used byte for byte.
# When it is not, the kernel is the repository's own linux-lts (boot/vmlinuz-lts,
# the file the netboot tree is made of) and the stock initramfs is kept as it is
# except for its module directory, which is the repository kernel's, same module
# names, so that the initramfs can load its drivers. The modules of the running
# system are never in a file the IPS made: the node installs linux-lts from the
# repository with apk (signed) into RAM, so there is no modloop (modloop=none).
# Nothing is compiled; no image is signed or re-signed by HPS.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use File::Path ();
use File::Basename ();
use File::Copy ();
use File::Temp ();
use IO::Uncompress::Gunzip ();
use IO::Compress::Gzip ();
use HPS::Apk;

sub _fail { HPS::Starter::_fail(@_) }

my $ARCH = 'x86_64';
# the arguments the starter is booted with beyond the stock ones (the IPS adds ip=, the repositories)
my $CMDLINE = 'ip=dhcp modloop=none';

# package_list($file): [[name, local?]...] from lib/starter/alpine.packages: NAME or NAME local.
sub package_list ($S, $file) {
    my @p;
    for my $line (split /\n/, HPS::Starter::_slurp($file)) {
        $line =~ s/#.*//;
        $line =~ s/\A\s+|\s+\z//g;
        next unless length $line;
        my ($name, $kind, @rest) = split ' ', $line;
        _fail('usage', "$file: '$line' is not NAME or NAME local")
            if @rest || $name !~ /\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/ || (defined $kind && $kind ne 'local');
        push @p, [ $name, $kind ? 1 : 0 ];
    }
    _fail('usage', "$file names no package") unless @p;
    return \@p;
}

sub _split_dep ($tok) {
    my ($name) = $tok =~ /\A!?([^=<>~]+)/;
    return $name;
}

# resolve(\%index_by_repo, \@roots, \%extra_wants): the names of the closure.
# Index entries carry D (depends), p (provides), i (install_if), k (provider priority).
# A virtual name (so:, cmd:, pc:, or a plain provide) is satisfied by a package that is
# already in the set, else by the one with the highest provider priority, then the
# first by name. install_if packages (the -openrc and -pyc subpackages) join when every
# package they name is in the set. Dies naming what cannot be resolved.
sub resolve ($pkg, $roots, $extra = {}) {
    my %prov;
    for my $n (keys %$pkg) {
        push @{ $prov{$n} }, $n;
        for my $p (split ' ', $pkg->{$n}{p} // '') { push @{ $prov{ _split_dep($p) } }, $n }
    }
    my (%sel, @queue);
    my $want;
    $want = sub ($tok) {
        return if $tok =~ /\A!/;
        my $t = _split_dep($tok);
        return if $sel{$t};
        my $name;
        if ($pkg->{$t}) { $name = $t }
        else {
            my @c = @{ $prov{$t} // [] };
            _fail('failed', "package dependency '$t' has no provider in the repository snapshot") unless @c;
            ($name) = grep { $sel{$_} } @c;
            $name //= (sort { ($pkg->{$b}{k} // 0) <=> ($pkg->{$a}{k} // 0) or $a cmp $b } @c)[0];
        }
        return if $sel{$name};
        $sel{$name} = 1;
        push @queue, $name;
    };
    $want->($_) for @$roots;
    $want->($_) for map { @{ $extra->{$_} } } sort keys %$extra;
    my $changed = 1;
    while ($changed) {
        while (defined(my $n = shift @queue)) { $want->($_) for split ' ', $pkg->{$n}{D} // '' }
        $changed = 0;
        for my $n (sort keys %$pkg) {
            next if $sel{$n};
            my @c = split ' ', $pkg->{$n}{i} // '';
            next unless @c;
            my $ok = 1;
            for my $c (@c) {
                my $b = _split_dep($c);
                $ok = 0 unless $sel{$b} || grep { $sel{$_} } @{ $prov{$b} // [] };
            }
            if ($ok) { $want->($n); $changed = 1 }
        }
    }
    return \%sel;
}

# kernel_release($version): linux-lts 6.18.63-r0 -> 6.18.63-0-lts (what uname -r says)
sub kernel_release ($ver) {
    my ($v, $r) = $ver =~ /\A(.+)-r([0-9]+)\z/ or _fail('failed', "linux-lts version '$ver' is not <version>-r<n>");
    return "$v-$r-lts";
}

sub sync ($S, $ver, %o) {
    my $only = $o{only};
    _fail('usage', 'for alpine the starter is made from the repository snapshot: run sync without --only starter')
        if defined $only && $only eq 'starter';
    my $rdir = $S->repo_dir('alpine', $ver);
    my $sdir = $S->starter_dir('alpine', $ver);
    my $list = $S->{packages} // _fail('usage', 'the package list file is not set');
    my $pk   = package_list($S, $list);
    my ($pk_sha) = HPS::Starter::_sha_file($list);
    my $old  = $S->read_manifest($rdir);
    File::Path::make_path($rdir);
    my $work = "$rdir/.work-$$";
    File::Path::make_path($work);
    my $r = eval { _sync($S, $ver, $rdir, $sdir, $work, $pk, $pk_sha, $old, $only) };
    my $err = $@;
    File::Path::remove_tree($work) if -d $work;
    die $err unless $r;
    return $r;
}

sub _sync ($S, $ver, $rdir, $sdir, $work, $pk, $pk_sha, $old, $only) {
    my $base = "$S->{alpine}/v$ver";
    # 1. the snapshot: the two indexes, fetched together and kept as they are
    my (%index, %idxfile, %idxsum);
    for my $repo (qw(main community)) {
        my $dest = "$work/$repo.APKINDEX.tar.gz";
        $S->_log("repository: fetching the $repo index of Alpine v$ver");
        $S->_fetch([ [ "$base/$repo/$ARCH/APKINDEX.tar.gz", $dest ] ]);
        $idxfile{$repo} = $dest;
        ($idxsum{$repo}) = HPS::Starter::_sha_file($dest);
        my $text = eval { HPS::Apk::index_text($dest) } // '';
        _fail('failed', "$base/$repo/$ARCH/APKINDEX.tar.gz holds no APKINDEX") unless length $text;
        $index{$repo} = HPS::Apk::parse_index($text);
    }
    my (%pkg, %repo_of);
    for my $repo (qw(main community)) {
        for my $n (keys %{ $index{$repo} }) {
            next if $pkg{$n};    # main first: the same name is the main one
            $pkg{$n} = $index{$repo}{$n};
            $repo_of{$n} = $repo;
        }
    }
    # 2. local packages (hps-starter add-local). Every .apk in the local directory is a
    # candidate and takes the place of the snapshot's package of the same name in the
    # resolution (the stock one is then not fetched or held). The names the list marks
    # local are roots; the others, the rest of a set (libvirt-daemon and the like, which
    # the AppArmor build of libvirt is made of), join only when something in the set
    # depends on them. A name marked local with no file is reported missing.
    my $ldir = "$S->{resources}/local/alpine/$ver";
    my (%lfile, %lpkg, %lsel, @missing_local, @roots);
    for my $f (sort glob("$ldir/*.apk")) {
        my $c  = HPS::Apk::control($f);
        my $pi = $c->{pkginfo};
        my ($n, $v) = map { $pi->{$_}[0] // '' } qw(pkgname pkgver);
        next unless length $n && length $v;    # add-local refuses such a file
        $lfile{$n} = $f;
        my %e = (P => $n, V => $v, S => $c->{size}, C => $c->{sum}, _local => 1);
        $e{D} = join ' ', @{ $pi->{depend} }           if $pi->{depend};
        $e{p} = join ' ', @{ $pi->{provides} }         if $pi->{provides};
        $e{i} = join ' ', @{ $pi->{install_if} }       if $pi->{install_if};
        $e{k} = $pi->{provider_priority}[0]            if $pi->{provider_priority};
        $lpkg{$n} = \%e;
    }
    for my $n (keys %lpkg) {
        $pkg{$n}     = $lpkg{$n};
        $repo_of{$n} = 'local';
    }
    for my $p (@$pk) {
        my ($name, $local) = @$p;
        if (!$local) {
            push @roots, $name;
        }
        elsif ($lpkg{$name}) {
            push @roots, $name;
        }
        else { push @missing_local, $name }
    }
    my $sel = resolve(\%pkg, \@roots);
    _one_snapshot(\%pkg, $sel);
    my @names = sort keys %$sel;
    for my $n (@names) {
        next unless $pkg{$n}{_local};
        $lsel{$n} = $lfile{$n};
        $S->_log("repository: local package $n $pkg{$n}{V} from $lfile{$n}");
    }
    $S->_log('repository: closure of ' . scalar(@names) . ' packages, ' . scalar(keys %lsel) . ' of them local');
    # 3. the packages: reuse what the last manifest vouches for, fetch and prove the rest
    my (%files, $fetched, $reused, $bytes, @need);
    $fetched = $reused = $bytes = 0;
    for my $n (@names) {
        my $r = $pkg{$n};
        if ($r->{_local}) { $bytes += $r->{S}; next }
        my $rel = "$repo_of{$n}/$ARCH/$n-$r->{V}.apk";
        $bytes += $r->{S};
        my $e = $old ? $old->{files}{$rel} : undef;
        if ($e && $e->{size} == $r->{S} && HPS::Starter::_file_is("$rdir/$rel", $e->{size}, $e->{sha256})) {
            $files{$rel} = { size => $e->{size}, sha256 => $e->{sha256} };
            $reused++;
        }
        else { push @need, [ $n, $rel ] }
    }
    my $total = @need;
    my $done = 0;
    while (my @batch = splice(@need, 0, 24)) {
        $done += @batch;
        $S->_log("repository: fetching packages $done of $total");
        $S->_fetch([ map { [ "$base/$_->[1]", "$work/pkg/$_->[1]" ] } @batch ], chunk => 24);
        for my $b (@batch) {
            my ($n, $rel) = @$b;
            my $t = "$work/pkg/$rel";
            my $r = $pkg{$n};
            _fail('failed', "$rel from $base: size " . (-s $t) . " differs from the index ($r->{S})") unless (-s $t) == $r->{S};
            my $c = eval { HPS::Apk::control($t) } // _fail('failed', "$rel from $base: not an apk: $@");
            _fail('failed', "$rel from $base: its control checksum $c->{sum} differs from the index ($r->{C})") unless $c->{sum} eq $r->{C};
            my ($hex) = HPS::Starter::_sha_file($t);
            File::Path::make_path(File::Basename::dirname("$rdir/$rel"));
            rename $t, "$rdir/$rel" or _fail('failed', "cannot rename into $rdir/$rel: $!");
            $files{$rel} = { size => $r->{S} + 0, sha256 => $hex };
            $fetched++;
        }
    }
    # 4. the indexes, as Alpine published them
    for my $repo (qw(main community)) {
        my $rel = "$repo/$ARCH/APKINDEX.tar.gz";
        File::Path::make_path(File::Basename::dirname("$rdir/$rel"));
        File::Copy::copy($idxfile{$repo}, "$rdir/$rel.new") or _fail('failed', "cannot write $rdir/$rel: $!");
        rename "$rdir/$rel.new", "$rdir/$rel" or _fail('failed', "cannot rename into $rdir/$rel: $!");
        $files{$rel} = { size => -s "$rdir/$rel", sha256 => $idxsum{$repo} };
    }
    # 5. the local repository: the packages and an unsigned index
    my @localnames = sort keys %lsel;
    if (@localnames) {
        File::Path::make_path("$rdir/local/$ARCH");
        my @apks;
        for my $n (@localnames) {
            my $rel = "local/$ARCH/" . File::Basename::basename($lsel{$n});
            File::Copy::copy($lsel{$n}, "$rdir/$rel.new") or _fail('failed', "cannot copy $lsel{$n}: $!");
            rename "$rdir/$rel.new", "$rdir/$rel" or _fail('failed', "cannot rename into $rdir/$rel: $!");
            my ($hex) = HPS::Starter::_sha_file("$rdir/$rel");
            $files{$rel} = { size => -s "$rdir/$rel", sha256 => $hex };
            push @apks, "$rdir/$rel";
        }
        HPS::Apk::write_index("$rdir/local/$ARCH/APKINDEX.tar.gz", @apks);
        my ($hex) = HPS::Starter::_sha_file("$rdir/local/$ARCH/APKINDEX.tar.gz");
        $files{"local/$ARCH/APKINDEX.tar.gz"} = { size => -s "$rdir/local/$ARCH/APKINDEX.tar.gz", sha256 => $hex };
    }
    _prune($rdir, \%files);
    # 6. the kernel-matched starter, from the same snapshot
    my $lts = $pkg{'linux-lts'} // _fail('failed', 'the snapshot has no linux-lts: the starter cannot be matched');
    _fail('failed', 'linux-lts is not in the package list: the roles need it, and so does the starter') unless $sel->{'linux-lts'};
    my $krel = kernel_release($lts->{V});
    my $st = _sync_starter($S, $ver, $sdir, $work, "$rdir/$repo_of{'linux-lts'}/$ARCH/linux-lts-$lts->{V}.apk", $krel, "linux-lts-$lts->{V}");
    # 7. the manifest closes the sync
    my %roots = map { $_->[0] => ($_->[1] ? "local/$_->[0]" : ($pkg{ $_->[0] } ? $_->[0] . '-' . $pkg{ $_->[0] }{V} : $_->[0])) } grep { $_->[1] ? $lsel{ $_->[0] } : 1 } @$pk;
    my %m = (
        schema => 'hps-repo/1', os => 'alpine', version => $ver, kind => 'apk-repository', arch => $ARCH,
        release => $st->{release}, kernel => $krel, upstream => $S->{alpine},
        snapshot => { main => $idxsum{main}, community => $idxsum{community} },
        packages_sha256 => $pk_sha, packages => [ map { $_->[0] } @$pk ],
        roots => \%roots, local => { map { $_ => JSON::PP::true() } @localnames }, missing_local => \@missing_local,
        closure => scalar(@names), bytes => $bytes, files => \%files, synced_at => $S->_now_text,
    );
    HPS::Starter::_spit("$rdir/manifest.json", HPS::Starter::_json(\%m));
    return { dir => $rdir, release => $st->{release}, starter => $st,
        repo => { dir => $rdir, paths => scalar(@names), files => scalar(keys %files), fetched => $fetched, reused => $reused,
                  bytes => $bytes, roots => \%roots, missing_local => \@missing_local } };
}

# every package in the set that pins another one exactly (zfs-lts needs linux-lts=6.18.63-r0)
# must find that version in the set: one snapshot, or the kernel module does not match
sub _one_snapshot ($pkg, $sel) {
    for my $n (sort keys %$sel) {
        for my $d (split ' ', $pkg->{$n}{D} // '') {
            next unless $d =~ /\A([^=<>~!][^=<>~]*)=(.+)\z/;
            my ($dn, $dv) = ($1, $2);
            next unless $sel->{$dn} && $pkg->{$dn};
            _fail('failed', "$n needs $dn=$dv but the snapshot holds $dn $pkg->{$dn}{V}: the repository is not one snapshot")
                unless $pkg->{$dn}{V} eq $dv;
        }
    }
    return 1;
}

sub _prune ($rdir, $files) {
    for my $repo (qw(main community local)) {
        my $d = "$rdir/$repo/$ARCH";
        next unless opendir(my $dh, $d);
        for my $f (grep { !/\A\./ } readdir $dh) {
            unlink "$d/$f" unless $files->{"$repo/$ARCH/$f"};
        }
        closedir $dh;
    }
    return;
}

#--- the starter ---------------------------------------------------------------

sub _sync_starter ($S, $ver, $dir, $work, $lts_apk, $krel, $pkgname) {
    my $nb = "$S->{alpine}/v$ver/releases/$ARCH/netboot";
    $S->_log("starter: fetching the stock netboot kernel and initramfs of Alpine v$ver");
    $S->_fetch([ [ "$nb/vmlinuz-lts", "$work/stock-vmlinuz-lts" ], [ "$nb/initramfs-lts", "$work/stock-initramfs-lts" ] ]);
    my $release = 'unknown';
    my $y = eval { $S->_fetch_text("$S->{alpine}/v$ver/releases/$ARCH/latest-releases.yaml") };
    if (defined $y) {
        for my $ent (split /\n- /, $y) {
            next unless $ent =~ /^\s*flavor:\s*alpine-netboot\s*$/m;
            $release = $1 if $ent =~ /^\s*version:\s*([0-9][0-9.]*)\s*$/m;
            last;
        }
    }
    my $ird = IO::Uncompress::Gunzip->new("$work/stock-initramfs-lts", MultiStream => 1) or _fail('failed', 'the stock initramfs-lts is not gzip');
    my $cpio = do { local $/; <$ird> };
    close $ird;
    my ($stock_k) = $cpio =~ m{usr/lib/modules/([0-9][^/\0]*-lts)\0};
    _fail('failed', 'the stock initramfs-lts holds no module directory (usr/lib/modules/<kernel>-lts)') unless defined $stock_k;
    my %stock;
    for my $f (qw(vmlinuz-lts initramfs-lts)) {
        my ($hex) = HPS::Starter::_sha_file("$work/stock-$f");
        $stock{$f} = { url => "$nb/$f", size => -s "$work/stock-$f", sha256 => $hex };
    }
    File::Path::make_path($dir);
    my %files;
    my $assembled = $stock_k ne $krel;
    # The same inputs give the same starter, so a sync that finds them unchanged writes nothing:
    # a node fetching the files during a sync never sees them replaced. The inputs are the
    # sha256 of the repository's kernel package and of the two stock files, the kernel release
    # and the arguments; the old manifest records them.
    my %inputs = (kernel_apk => (HPS::Starter::_sha_file($lts_apk))[0], stock_vmlinuz => $stock{'vmlinuz-lts'}{sha256},
        stock_initramfs => $stock{'initramfs-lts'}{sha256}, kernel => $krel, cmdline => $CMDLINE, release => $release);
    my $old = $S->read_manifest($dir);
    my $same = sub { my $o = $old->{inputs}; return 0 unless ref $o eq 'HASH'; return !grep { ($o->{$_} // '') ne $inputs{$_} } keys %inputs };
    if ($old && $same->() && !@{ $S->check_files($dir, $old->{files}) }) {
        $S->_log("starter: the inputs are those of the last sync and the files verify: nothing is written");
        return { dir => $dir, release => $release, files => 2, fetched => 0, reused => 2,
            bytes => $old->{files}{'vmlinuz-lts'}{size} + $old->{files}{'initramfs-lts'}{size}, kernel => $krel, assembled => $assembled };
    }
    my $changed = 0;
    if (!$assembled) {
        $S->_log("starter: the netboot kernel $stock_k is the repository's: the stock files are used as they are");
        for my $f (qw(vmlinuz-lts initramfs-lts)) { $changed += _place_if_changed("$work/stock-$f", "$dir/$f") }
    }
    else {
        $S->_log("starter: the netboot kernel is $stock_k, the repository's linux-lts is $krel: assembling the matched set from $pkgname");
        my $kdir = "$work/kernel";
        File::Path::make_path($kdir);
        _extract_kernel($lts_apk, $kdir, $krel, $stock_k, \$cpio);
        $changed += _place_if_changed("$kdir/boot/vmlinuz-lts", "$dir/vmlinuz-lts");
        _rebuild_initramfs(\$cpio, "$work/initramfs-lts.new", $stock_k, $krel, "$kdir/lib/modules/$krel");
        $changed += _place_if_changed("$work/initramfs-lts.new", "$dir/initramfs-lts");
    }
    for my $f (qw(vmlinuz-lts initramfs-lts)) {
        my ($hex) = HPS::Starter::_sha_file("$dir/$f");
        $files{$f} = { size => -s "$dir/$f", sha256 => $hex, ($assembled ? () : (url => $stock{$f}{url})) };
    }
    my %m = (
        schema => 'hps-starter/1', os => 'alpine', version => $ver, arch => $ARCH, release => $release,
        upstream => $S->{alpine}, cmdline => $CMDLINE, kernel => $krel, stock_kernel => $stock_k,
        assembled => ($assembled ? JSON::PP::true() : JSON::PP::false()), from => $pkgname, inputs => \%inputs,
        stock => \%stock, files => \%files, synced_at => $S->_now_text,
    );
    $m{synced_at} = $old->{synced_at} if !$changed && $old && $old->{synced_at};
    HPS::Starter::_spit("$dir/manifest.json", HPS::Starter::_json(\%m));
    return { dir => $dir, release => $release, files => 2, fetched => $changed, reused => 2 - $changed,
        bytes => $files{'vmlinuz-lts'}{size} + $files{'initramfs-lts'}{size}, kernel => $krel, assembled => $assembled };
}

# _place_if_changed($from, $to): 1 when $to was replaced, 0 when it already was this file. The
# replacement is a copy under a temporary name in the same directory and a rename.
sub _place_if_changed ($from, $to) {
    if (-f $to && (-s $to) == (-s $from)) {
        my ($a) = HPS::Starter::_sha_file($from);
        my ($b) = HPS::Starter::_sha_file($to);
        return 0 if defined $a && defined $b && $a eq $b;
    }
    _place($from, $to);
    return 1;
}

sub _place ($from, $to) {
    File::Path::make_path(File::Basename::dirname($to));
    File::Copy::copy($from, "$to.new") or _fail('failed', "cannot copy $from to $to: $!");
    rename "$to.new", $to or _fail('failed', "cannot rename into $to: $!");
    return;
}

# the stock initramfs's module names, from its own cpio (the basenames under kernel/)
sub _stock_modules ($cpio_ref, $stock_k) {
    my %want;
    for my $e (@{ cpio_entries($$cpio_ref) }) {
        next unless $e->{name} =~ m{\Ausr/lib/modules/\Q$stock_k\E/kernel/.*/([^/]+?)\.ko(?:\.[a-z]+)?\z};
        $want{$1} = 1;
    }
    return \%want;
}

# _extract_kernel($apk, $dir, $krel, $stock_k, \$cpio): boot/vmlinuz-lts, the module indexes
# and the modules the stock initramfs names (and what they depend on) out of linux-lts.
sub _extract_kernel ($apk, $dir, $krel, $stock_k, $cpio_ref) {
    my $want = _stock_modules($cpio_ref, $stock_k);
    open(my $lh, '-|', 'sh', '-c', 'exec tar -tzf "$1" 2>/dev/null', 'sh', $apk) or _fail('failed', "cannot run tar on $apk: $!");
    my @all = map { chomp; $_ } <$lh>;
    close $lh or _fail('failed', "tar could not list $apk");
    my %path;    # module basename => path under lib/modules/<krel>/
    for my $n (@all) {
        next unless $n =~ m{\Alib/modules/\Q$krel\E/(kernel/.*/([^/]+?)\.ko(?:\.[a-z]+)?)\z};
        $path{$2} = $1;
    }
    my %have;
    $have{$_} = $path{$_} for grep { $path{$_} } keys %$want;
    _fail('failed', "linux-lts $krel holds none of the modules the stock initramfs names") unless %have;
    my @pick = grep { m{\Alib/modules/\Q$krel\E/modules\.[a-z._]+\z} } @all;
    my $list = "$dir/.extract.list";
    File::Path::make_path($dir);
    # first pass: the indexes (dependencies come from modules.dep), then the closure
    open(my $oh, '>', $list) or _fail('failed', "cannot write $list: $!");
    print {$oh} "$_\n" for 'boot/vmlinuz-lts', @pick;
    close $oh;
    _tar_x($apk, $dir, $list) or _fail('failed', "tar could not extract the kernel and module indexes from $apk");
    my %dep;
    open(my $dh, '<', "$dir/lib/modules/$krel/modules.dep") or _fail('failed', "linux-lts $krel has no modules.dep");
    while (<$dh>) {
        chomp;
        my ($m, $d) = split /:\s*/, $_, 2;
        $dep{$m} = [ split ' ', $d // '' ];
    }
    close $dh;
    my %take;
    my @todo = values %have;
    while (defined(my $m = shift @todo)) {
        next if $take{$m}++;
        push @todo, @{ $dep{$m} // [] };
    }
    open($oh, '>', $list) or _fail('failed', "cannot write $list: $!");
    print {$oh} "lib/modules/$krel/$_\n" for sort keys %take;
    close $oh;
    _tar_x($apk, $dir, $list) or _fail('failed', "tar could not extract the modules from $apk");
    unlink $list;
    return scalar keys %take;
}

# tar -x of the names in a list file; apk's pax headers make GNU tar say so on stderr
sub _tar_x ($apk, $dir, $list) {
    return system('sh', '-c', 'exec tar -xzf "$1" -C "$2" -T "$3" 2>/dev/null', 'sh', $apk, $dir, $list) == 0;
}

#--- cpio (newc) ------------------------------------------------------------------

# cpio_entries($bytes): [{name, off, len (header+name+data incl. padding), mode, size, data_off}]
sub cpio_entries ($c) {
    my @e;
    my $o = 0;
    while ($o + 110 <= length $c) {
        _fail('failed', 'the initramfs is not a newc cpio archive') unless substr($c, $o, 6) eq '070701';
        my @f = map { hex substr($c, $o + 6 + 8 * $_, 8) } 0 .. 12;
        my ($mode, $size, $nsize) = @f[1, 6, 11];
        my $name = substr($c, $o + 110, $nsize - 1);
        my $dataoff = ($o + 110 + $nsize + 3) & ~3;
        my $end = ($dataoff + $size + 3) & ~3;
        last if $name eq 'TRAILER!!!';
        push @e, { name => $name, off => $o, end => $end, mode => $mode, size => $size, data_off => $dataoff };
        $o = $end;
    }
    return \@e;
}

sub _cpio_entry ($ino, $name, $mode, $data) {
    my $h = '070701' . join '', map { sprintf '%08X', $_ } ($ino, $mode, 0, 0, 1, 0, length($data), 0, 0, 0, 0, length($name) + 1, 0);
    my $head = $h . $name . "\0";
    $head .= "\0" x ((4 - length($head) % 4) % 4);
    return $head . $data . ("\0" x ((4 - length($data) % 4) % 4));
}

# _rebuild_initramfs(\$cpio, $out, $stock_k, $krel, $moddir): the stock archive with its
# usr/lib/modules/<stock_k> directory replaced by the repository kernel's (the index
# files and the modules extracted into $moddir), gzip, written to $out.
sub _rebuild_initramfs ($cpio_ref, $out, $stock_k, $krel, $moddir) {
    my $c = $$cpio_ref;
    my $prefix = "usr/lib/modules/$stock_k";
    my @keep = grep { $_->{name} ne $prefix && index($_->{name}, "$prefix/") != 0 } @{ cpio_entries($c) };
    my $z = IO::Compress::Gzip->new($out, Time => 0, -Level => 6, Minimal => 1) or _fail('failed', "cannot write $out");
    $z->print(substr($c, $_->{off}, $_->{end} - $_->{off})) for @keep;
    my $ino = 0x7f000000;
    my @files;
    my $walk;
    $walk = sub ($d, $rel) {
        opendir(my $dh, $d) or _fail('failed', "cannot read $d: $!");
        for my $f (sort grep { !/\A\.\.?\z/ } readdir $dh) {
            if (-d "$d/$f") { push @files, [ "$rel/$f", 0040755, '' ]; $walk->("$d/$f", "$rel/$f") }
            else {
                open(my $fh, '<:raw', "$d/$f") or _fail('failed', "cannot read $d/$f: $!");
                local $/;
                push @files, [ "$rel/$f", 0100644, scalar <$fh> ];
                close $fh;
            }
        }
        closedir $dh;
    };
    push @files, [ "usr/lib/modules/$krel", 0040755, '' ];
    $walk->($moddir, "usr/lib/modules/$krel");
    $z->print(_cpio_entry($ino++, $_->[0], $_->[1], $_->[2])) for @files;
    $z->print(_cpio_entry(0, 'TRAILER!!!', 0, ''));
    $z->close;
    return scalar @files;
}

1;
