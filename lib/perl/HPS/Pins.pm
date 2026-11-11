package HPS::Pins;
# Retention and integrity of the published NixOS pins (IPS-05).
#
#   <resources>/nixos/<pin>/<profile>/{bzImage,initrd,boot.json}
#   <resources>/nixos/<pin>/ipxe/{snponly.efi,ipxe.efi,undionly.kpxe,ipxe.json}
#                                             (IPS-09; not a profile)
#   <resources>/nixos/<pin>/SHA256SUMS        (written by nix/build.sh)
#   <resources>/nixos/latest                  (the newest pin)
#   <resources>/nixos/firmware/<hash>-<name>.cpio
#                                             shared firmware layers; a profile's
#                                             boot.json names its own in
#                                             extra_initrds [{path, sha256, size}]
#
# list, verify (served files against boot.json and SHA256SUMS), prune and
# delete. A pin is protected, never pruned or deleted, when it is the latest,
# when a host's system_pin or system_pin_previous names it, when it is the
# cluster's nixos_default_pin, or when a host that booted within the last 15
# minutes resolves to it. The registry is read through HPS::Registry only.
# A firmware layer is kept while any pin left on disk names it (and for an
# hour after it was written, so a build publishing it is never raced); prune
# and delete remove the others.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Digest::SHA ();
use File::Path ();
use POSIX qw(strftime);
use HPS::Registry;

package HPS::Pins::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $PIN_RE = qr/^[a-z0-9][a-z0-9.-]+\z/;
my @ARTEFACTS = qw(bzImage initrd);
# The pin's iPXE directory sits beside the profile directories and is not one.
my $IPXE_DIR = 'ipxe';
# The shared firmware layers sit beside the pins under nixos/ and are not one.
my $LAYER_DIR = 'firmware';
my $LAYER_RE  = qr{\A\Q$LAYER_DIR\E/([A-Za-z0-9][A-Za-z0-9._+-]*)\z};
my $LAYER_FILE_RE = qr{\A[A-Za-z0-9][A-Za-z0-9._+-]*\.cpio\z};

sub new ($class, %opt) {
    my $self = {
        registry    => $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} }),
        resources   => $opt{resources},
        now         => $opt{now} // sub { time },
        logger      => $opt{logger} // \&_default_logger,
        boot_window => $opt{boot_window} // 900,
        layer_grace => $opt{layer_grace} // 3600,
    };
    return bless $self, $class;
}

sub _fail ($kind, $msg) { die HPS::Pins::Error->new($kind, $msg) }

sub _default_logger ($level, $msg) {
    print STDERR "hps-pins: $msg\n";
    return if $ENV{HPS_PINS_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-pins: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

# <resources>/nixos; resources default as lib/hps-system.sh does.
sub nixos_dir ($self) {
    my $res = $self->{resources} // $ENV{HPS_RESOURCES}
        // (($ENV{HPS_BASE} // '/srv') . '/hps-resources');
    return "$res/nixos";
}

sub _slurp ($file) {
    open(my $fh, '<:raw', $file) or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

sub _boot_json ($self, $pin, $profile) {
    my $t = _slurp($self->nixos_dir . "/$pin/$profile/boot.json");
    return undef unless defined $t;
    my $d = eval { JSON::PP::decode_json($t) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub profiles ($self, $pin) {
    my $dir = $self->nixos_dir . "/$pin";
    opendir(my $dh, $dir) or return ();
    my @p = sort grep { !/^\./ && $_ ne $IPXE_DIR && -d "$dir/$_" } readdir $dh;
    closedir $dh;
    return @p;
}

# The pin named by <nixos>/latest, or undef.
sub latest ($self) {
    my $t = _slurp($self->nixos_dir . '/latest');
    return undef unless defined $t;
    $t =~ s/\s+//g;
    return length $t ? $t : undef;
}

# Date of a pin: built_at of its first profile's boot.json, else the directory
# mtime. A sortable UTC string.
sub pin_date ($self, $pin) {
    for my $prof ($self->profiles($pin)) {
        my $b = $self->_boot_json($pin, $prof);
        return $b->{built_at} if $b && defined $b->{built_at} && length $b->{built_at};
    }
    my $mtime = (stat $self->nixos_dir . "/$pin")[9] // 0;
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $mtime);
}

# Bytes of every regular file in the pin.
sub pin_size ($self, $pin) {
    my $dir = $self->nixos_dir . "/$pin";
    my $sum = 0;
    for my $prof ($self->profiles($pin), (-d "$dir/$IPXE_DIR" ? ($IPXE_DIR) : ())) {
        opendir(my $dh, "$dir/$prof") or next;
        for my $f (grep { !/^\./ } readdir $dh) {
            $sum += -s "$dir/$prof/$f" if -f "$dir/$prof/$f";
        }
        closedir $dh;
    }
    return $sum;
}

# Pin names, newest first (pin_date, then name).
sub pin_names ($self) {
    my $root = $self->nixos_dir;
    opendir(my $dh, $root) or _fail('notfound', "Cannot read $root: $!");
    my @pins = grep { /$PIN_RE/ && $_ ne $LAYER_DIR && -d "$root/$_" && !-l "$root/$_" } readdir $dh;
    closedir $dh;
    my %date = map { $_ => $self->pin_date($_) } @pins;
    return sort { $date{$b} cmp $date{$a} || $b cmp $a } @pins;
}

#--- references -------------------------------------------------------------

# {hosts => {mac => {system_pin, system_pin_previous, last_boot_at}},
#  cluster_default => pin|undef}. Dies when the registry cannot be read.
sub _registry_view ($self) {
    my $reg = $self->{registry};
    my $cluster = $reg->active_cluster;
    my %hosts;
    for my $mac ($reg->host_list_all) {
        my %h;
        for my $k (qw(system_pin system_pin_previous last_boot_at)) {
            my $v = $reg->host_get($mac, $k);
            $v =~ s/\s+\z// if defined $v;
            $h{$k} = $v if defined $v && length $v;
        }
        $hosts{$mac} = \%h;
    }
    my $def = $reg->cluster_get($cluster, 'nixos_default_pin');
    $def = undef unless defined $def && length $def;
    return { hosts => \%hosts, cluster_default => $def };
}

# {pin => [reason, ...]} for every pin that must not be removed. Reasons name
# the host (MAC) where one is the cause. Fails (failed) when the registry
# cannot be read, because absence of a reference would then mean nothing.
sub references ($self) {
    my $view = eval { $self->_registry_view };
    _fail('failed', 'Cannot read the host registry, so pin references are unknown: ' . ($@ =~ s/\s+\z//r))
        unless $view;
    my %ref;
    my $add = sub ($pin, $why) { push @{ $ref{$pin} }, $why };
    my $latest = $self->latest;
    $add->($latest, 'latest') if defined $latest;
    $add->($view->{cluster_default}, 'cluster nixos_default_pin') if defined $view->{cluster_default};
    my $now = $self->{now}->();
    for my $mac (sort keys %{ $view->{hosts} }) {
        my $h = $view->{hosts}{$mac};
        $add->($h->{system_pin}, "system_pin of $mac") if defined $h->{system_pin};
        $add->($h->{system_pin_previous}, "system_pin_previous of $mac") if defined $h->{system_pin_previous};
        my $at = $h->{last_boot_at};
        next unless defined $at && $at =~ /^[0-9]+\z/ && $now - $at <= $self->{boot_window} && $now >= $at;
        # What the boot script serves: system_pin, else cluster default, else latest.
        my $serving = $h->{system_pin} // $view->{cluster_default} // $latest;
        $add->($serving, "booting now: $mac") if defined $serving;
    }
    return \%ref;
}

#--- list --------------------------------------------------------------------

# [{pin, date, size, profiles => [], hosts => [mac], latest => 0|1, protected => [reason]}]
sub list ($self) {
    my $ref = eval { $self->references } // {};
    my $latest = $self->latest;
    my @rows;
    for my $pin ($self->pin_names) {
        my %hosts;
        for my $why (@{ $ref->{$pin} // [] }) {
            $hosts{$1} = 1 if $why =~ /^system_pin(?:_previous)? of (\S+)\z/;
        }
        push @rows, {
            pin       => $pin,
            date      => $self->pin_date($pin),
            size      => $self->pin_size($pin),
            profiles  => [ $self->profiles($pin) ],
            hosts     => [ sort keys %hosts ],
            latest    => (defined $latest && $latest eq $pin) ? 1 : 0,
            protected => $ref->{$pin} // [],
        };
    }
    return @rows;
}

#--- verify ------------------------------------------------------------------

sub _sha256_file ($file) {
    open(my $fh, '<:raw', $file) or return undef;
    my $d = Digest::SHA->new(256);
    $d->addfile($fh);
    close $fh;
    return $d->hexdigest;
}

# Lines of <pin>/SHA256SUMS as {relpath => sha}.
sub _sums ($self, $pin) {
    my $t = _slurp($self->nixos_dir . "/$pin/SHA256SUMS");
    return undef unless defined $t;
    my %s;
    for my $line (split /\n/, $t) {
        $s{$2} = $1 if $line =~ /^([0-9a-f]{64})  (\S.*)\z/;
    }
    return \%s;
}

sub _check_file ($self, $pin, $rel, $sha, $size, $fail) {
    return _check_path($self->nixos_dir . "/$pin/$rel", $rel, $sha, $size, $fail);
}

# _check_path($file, $label, $sha, $size, $fail): the file against a sha256
# and, when given, a size; failures are pushed under $label.
sub _check_path ($file, $rel, $sha, $size, $fail) {
    unless (-f $file) { push @$fail, { file => $rel, reason => 'missing' }; return }
    my $have = -s $file;
    if (defined $size && $have != $size) {
        push @$fail, { file => $rel, reason => "size $have, boot.json says $size" };
        return;
    }
    my $got = _sha256_file($file);
    push @$fail, { file => $rel, reason => "sha256 $got, expected $sha" } if !defined $got || $got ne $sha;
    return;
}

# verify_pin($pin): {pin, ok, failures => [{file, reason}], unverified => [file]}.
# Every profile's bzImage and initrd is checked against boot.json (sha256, size)
# and against the pin's SHA256SUMS. A file with no recorded hash anywhere (a pin
# built before IPS-05) is unverified, not failed. Dies notfound for a missing pin.
sub verify_pin ($self, $pin) {
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$") unless defined $pin && $pin =~ $PIN_RE;
    _fail('notfound', "Pin $pin does not exist under " . $self->nixos_dir) unless -d $self->nixos_dir . "/$pin";
    my @profiles = $self->profiles($pin);
    _fail('notfound', "Pin $pin has no profile directories") unless @profiles;
    my $sums = $self->_sums($pin);
    my (@fail, @unverified);
    for my $prof (@profiles) {
        my $b = $self->_boot_json($pin, $prof);
        unless ($b) {
            push @fail, { file => "$prof/boot.json", reason => (-f $self->nixos_dir . "/$pin/$prof/boot.json" ? 'not valid JSON' : 'missing') };
            next;
        }
        for my $art (@ARTEFACTS) {
            my $rel = "$prof/$art";
            my $sha  = ref $b->{sha256} eq 'HASH' ? $b->{sha256}{$art} : undef;
            my $size = ref $b->{size}   eq 'HASH' ? $b->{size}{$art}   : undef;
            my $sum  = $sums ? $sums->{$rel} : undef;
            if (!defined $sha && !defined $sum) {
                push @unverified, $rel;
                push @fail, { file => $rel, reason => 'missing' } unless -f $self->nixos_dir . "/$pin/$rel";
                next;
            }
            my @here;
            $self->_check_file($pin, $rel, $sha, $size, \@here) if defined $sha;
            if (defined $sum && !@here) {
                $self->_check_file($pin, $rel, $sum, undef, \@here);
            }
            push @fail, @here;
        }
    }
    $self->_verify_layers($pin, $sums, \@fail, \@unverified);
    $self->_verify_ipxe($pin, $sums, \@fail, \@unverified);
    return { pin => $pin, ok => (@fail ? 0 : 1), failures => \@fail, unverified => \@unverified };
}

#--- firmware layers -----------------------------------------------------------

# _extra_initrds($boot_json): the list under extra_initrds ([] when absent),
# or undef when it is not a list of objects.
sub _extra_initrds ($b) {
    my $x = $b->{extra_initrds};
    return [] unless defined $x;
    return undef unless ref $x eq 'ARRAY';
    return undef if grep { ref $_ ne 'HASH' } @$x;
    return $x;
}

# layer_refs($pin): [{profile, path, sha256, size}] for every extra initrd the
# pin's boot.json files name, valid or not (verify judges them).
sub layer_refs ($self, $pin) {
    my @r;
    for my $prof ($self->profiles($pin)) {
        my $b = $self->_boot_json($pin, $prof) or next;
        my $x = _extra_initrds($b) or next;
        push @r, map { { profile => $prof, path => $_->{path}, sha256 => $_->{sha256}, size => $_->{size} } } @$x;
    }
    return \@r;
}

# Every profile's extra initrds: a path of the form firmware/<file>, the file
# against the sha256 and size boot.json recorded and the ../<path> line of
# SHA256SUMS. Failures and unverified files are named by that path.
sub _verify_layers ($self, $pin, $sums, $fail, $unverified) {
    for my $prof ($self->profiles($pin)) {
        my $b = $self->_boot_json($pin, $prof) or next;
        my $x = _extra_initrds($b);
        unless ($x) {
            push @$fail, { file => "$prof/boot.json", reason => 'extra_initrds is not a list of {path, sha256, size}' };
            next;
        }
        for my $e (@$x) {
            my $rel = $e->{path};
            unless (defined $rel && !ref $rel && $rel =~ $LAYER_RE) {
                push @$fail, { file => "$prof/boot.json", reason => 'extra initrd path ' . (defined $rel && !ref $rel ? "'$rel'" : '(none)') . " is not $LAYER_DIR/<file>" };
                next;
            }
            my $file = $self->nixos_dir . "/$rel";
            my $sha  = $e->{sha256};
            my $sum  = $sums ? $sums->{"../$rel"} : undef;
            if (!defined $sha && !defined $sum) {
                push @$unverified, $rel;
                push @$fail, { file => $rel, reason => 'missing' } unless -f $file;
                next;
            }
            unless (-f $file) { push @$fail, { file => $rel, reason => 'missing' }; next }
            my $have = -s $file;
            if (defined $e->{size} && $have != $e->{size}) {
                push @$fail, { file => $rel, reason => "size $have, boot.json says $e->{size}" };
                next;
            }
            my $got = $self->_layer_sha($file);
            for my $want (grep { defined } $sha, $sum) {
                next if defined $got && $got eq $want;
                push @$fail, { file => $rel, reason => 'sha256 ' . ($got // 'unreadable') . ", expected $want" };
                last;
            }
        }
    }
    return;
}

# sha256 of a layer file, hashed once per object while its size and mtime stay
# the same: every pin names the same ~800 MB file.
sub _layer_sha ($self, $file) {
    my @st = stat $file;
    my $key = join ':', $file, $st[7] // '', $st[9] // '';
    return $self->{layer_sha}{$key} //= _sha256_file($file);
}

# The layer files on disk: names under nixos/firmware/ (no temporary files,
# no symlinks), sorted.
sub layer_files ($self) {
    my $dir = $self->nixos_dir . "/$LAYER_DIR";
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { /$LAYER_FILE_RE/ && -f "$dir/$_" && !-l "$dir/$_" } readdir $dh;
    closedir $dh;
    return @f;
}

# _prune_layers(\@pins_left, dry_run): remove the layer files none of the
# given pins names, except one written within layer_grace seconds. Returns
# {kept => [{file, why}], removed => [{file, why}]}; file is firmware/<name>.
sub _prune_layers ($self, $left, $dry) {
    my %used;
    for my $pin (@$left) {
        for my $e (@{ $self->layer_refs($pin) }) {
            next unless defined $e->{path} && !ref $e->{path} && $e->{path} =~ $LAYER_RE;
            push @{ $used{$1} }, $pin;
        }
    }
    my $now = $self->{now}->();
    my (@kept, @removed);
    my $dir = $self->nixos_dir . "/$LAYER_DIR";
    for my $name ($self->layer_files) {
        my $rel = "$LAYER_DIR/$name";
        if (my $by = $used{$name}) {
            my %u = map { $_ => 1 } @$by;
            push @kept, { file => $rel, why => 'named by ' . join(', ', sort keys %u) };
            next;
        }
        my $mtime = (stat "$dir/$name")[9] // 0;
        if ($now - $mtime < $self->{layer_grace}) {
            push @kept, { file => $rel, why => 'written within the last ' . $self->{layer_grace} . ' s (a build may be publishing it)' };
            next;
        }
        my $why = 'no pin names it';
        unless ($dry) {
            unlink "$dir/$name" or _fail('failed', "Could not remove $dir/$name: $!");
            $self->_log('info', "deleted firmware layer $rel ($why)");
        }
        push @removed, { file => $rel, why => $why };
    }
    return { kept => \@kept, removed => \@removed };
}

# The pin's ipxe/ files, when the directory exists: each file named in
# ipxe.json (sha256, size) and in SHA256SUMS is checked like an artefact. A
# pin without ipxe/ has nothing to check. Appends to @$fail and @$unverified.
sub _verify_ipxe ($self, $pin, $sums, $fail, $unverified) {
    my $dir = $self->nixos_dir . "/$pin/$IPXE_DIR";
    return unless -d $dir;
    my $j = _slurp("$dir/ipxe.json");
    my $meta = defined $j ? eval { JSON::PP::decode_json($j) } : undef;
    unless (ref $meta eq 'HASH') {
        push @$fail, { file => "$IPXE_DIR/ipxe.json", reason => (defined $j ? 'not valid JSON' : 'missing') };
        return;
    }
    my @files = ref $meta->{files} eq 'ARRAY' ? @{ $meta->{files} } : ();
    unless (@files) {
        push @$fail, { file => "$IPXE_DIR/ipxe.json", reason => 'names no files' };
        return;
    }
    for my $name (@files) {
        my $rel = "$IPXE_DIR/$name";
        if ($name !~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/) {
            push @$fail, { file => $rel, reason => 'not a plain file name' };
            next;
        }
        my $sha  = ref $meta->{sha256} eq 'HASH' ? $meta->{sha256}{$name} : undef;
        my $size = ref $meta->{size}   eq 'HASH' ? $meta->{size}{$name}   : undef;
        my $sum  = $sums ? $sums->{$rel} : undef;
        if (!defined $sha && !defined $sum) {
            push @$unverified, $rel;
            push @$fail, { file => $rel, reason => 'missing' } unless -f "$dir/$name";
            next;
        }
        my @here;
        $self->_check_file($pin, $rel, $sha, $size, \@here) if defined $sha;
        $self->_check_file($pin, $rel, $sum, undef, \@here) if defined $sum && !@here;
        push @$fail, @here;
    }
    return;
}

# One verify_pin result per pin, newest first.
sub verify_all ($self) {
    return map { $self->verify_pin($_) } $self->pin_names;
}

#--- delete and prune ----------------------------------------------------------

# Remove the pin directory; it must be a direct, non-symlink child of nixos/.
sub _remove ($self, $pin, $why) {
    my $dir = $self->nixos_dir . "/$pin";
    _fail('failed', "Refusing to remove $dir: not a plain pin directory") if $pin !~ $PIN_RE || -l $dir || !-d $dir;
    my $err;
    File::Path::remove_tree($dir, { error => \$err });
    _fail('failed', "Could not remove $dir: " . join('; ', map { join ' ', %$_ } @$err)) if $err && @$err;
    $self->_log('info', "deleted pin $pin ($why)");
    return 1;
}

# set_latest($pin): point <nixos>/latest at a pin already on disk, when it
# verifies. An IPS with no builder (a cluster's inner IPS, given its pins by
# cnh-ips-bootstrap) has no other way to get a latest, and with none it has no
# pin to audit or boot from. The operator chooses the pin, at every level.
# Written to a temporary file and renamed, so a reader never sees a partial
# name. Returns {pin, previous}.
sub set_latest ($self, $pin) {
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$") unless defined $pin && $pin =~ $PIN_RE;
    _fail('notfound', "Pin $pin does not exist under " . $self->nixos_dir) unless -d $self->nixos_dir . "/$pin";
    my $v = $self->verify_pin($pin);
    unless ($v->{ok}) {
        my $f = $v->{failures}[0];
        _fail('refused', "Pin $pin does not verify ($f->{file}: $f->{reason}); latest unchanged");
    }
    my $previous = $self->latest;
    my $file = $self->nixos_dir . '/latest';
    my $tmp  = "$file.tmp.$$";
    open(my $fh, '>', $tmp) or _fail('failed', "$tmp: $!");
    print {$fh} "$pin\n";
    close($fh) or _fail('failed', "$tmp: $!");
    rename($tmp, $file) or do { unlink $tmp; _fail('failed', "rename to $file: $!") };
    $self->_log('info', "latest pin set to $pin (was " . ($previous // 'none') . ')');
    return { pin => $pin, previous => $previous };
}

# delete($pin): refused (refused) for any protected pin; notfound if absent.
sub delete ($self, $pin) {
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$") unless defined $pin && $pin =~ $PIN_RE;
    _fail('notfound', "Pin $pin does not exist under " . $self->nixos_dir) unless -d $self->nixos_dir . "/$pin";
    my $ref = $self->references;
    if (my $why = $ref->{$pin}) {
        $self->_log('warning', "delete of pin $pin refused (" . join(', ', @$why) . ')');
        _fail('refused', "Pin $pin is in use and is not deleted: " . join(', ', @$why));
    }
    $self->_remove($pin, 'explicit delete; no host, cluster default or latest references it');
    my $l = $self->_prune_layers([ $self->pin_names ], 0);
    return { pin => $pin, layers_removed => $l->{removed} };
}

# prune(keep_previous => N, dry_run => 0|1): remove unreferenced pins except
# the newest N of them (default 1), then the firmware layers no kept pin names.
# Needs a readable `latest`. Returns {kept => [{pin, why}], removed => [{pin,
# why}], layers_kept => [{file, why}], layers_removed => [{file, why}], dry_run}.
sub prune ($self, %o) {
    my $keep = $o{keep_previous} // 1;
    _fail('usage', 'keep-previous must be a non-negative integer') unless $keep =~ /^[0-9]+\z/;
    my $latest = $self->latest;
    _fail('refused', 'No readable latest pin; refusing to prune') unless defined $latest;
    _fail('refused', "latest names $latest, which is not under " . $self->nixos_dir . '; refusing to prune')
        unless -d $self->nixos_dir . "/$latest";
    my $ref = $self->references;
    my (@kept, @removed);
    my $n = 0;
    for my $pin ($self->pin_names) {
        if (my $why = $ref->{$pin}) {
            push @kept, { pin => $pin, why => join(', ', @$why) };
        }
        elsif ($n < $keep) {
            $n++;
            push @kept, { pin => $pin, why => "previous (newest $keep unreferenced)" };
        }
        else {
            my $why = "unreferenced and older than the newest $keep unreferenced pin" . ($keep == 1 ? '' : 's');
            $self->_remove($pin, $why) unless $o{dry_run};
            push @removed, { pin => $pin, why => $why };
        }
    }
    my $l = $self->_prune_layers([ map { $_->{pin} } @kept ], $o{dry_run});
    return { kept => \@kept, removed => \@removed, layers_kept => $l->{kept},
        layers_removed => $l->{removed}, dry_run => $o{dry_run} ? 1 : 0 };
}

1;
