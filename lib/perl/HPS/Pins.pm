package HPS::Pins;
# Retention and integrity of the published NixOS pins (IPS-05).
#
#   <resources>/nixos/<pin>/<profile>/{bzImage,initrd,boot.json}
#   <resources>/nixos/<pin>/SHA256SUMS        (written by nix/build.sh)
#   <resources>/nixos/latest                  (the newest pin)
#
# list, verify (served files against boot.json and SHA256SUMS), prune and
# delete. A pin is protected, never pruned or deleted, when it is the latest,
# when a host's system_pin or system_pin_previous names it, when it is the
# cluster's nixos_default_pin, or when a host that booted within the last 15
# minutes resolves to it. The registry is read through HPS::Registry only.
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

sub new ($class, %opt) {
    my $self = {
        registry    => $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} }),
        resources   => $opt{resources},
        now         => $opt{now} // sub { time },
        logger      => $opt{logger} // \&_default_logger,
        boot_window => $opt{boot_window} // 900,
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
    my @p = sort grep { !/^\./ && -d "$dir/$_" } readdir $dh;
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
    for my $prof ($self->profiles($pin)) {
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
    my @pins = grep { /$PIN_RE/ && -d "$root/$_" && !-l "$root/$_" } readdir $dh;
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
    my $file = $self->nixos_dir . "/$pin/$rel";
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
    return { pin => $pin, ok => (@fail ? 0 : 1), failures => \@fail, unverified => \@unverified };
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
    return { pin => $pin };
}

# prune(keep_previous => N, dry_run => 0|1): remove unreferenced pins except
# the newest N of them (default 1). Needs a readable `latest`. Returns
# {kept => [{pin, why}], removed => [{pin, why}], dry_run}.
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
    return { kept => \@kept, removed => \@removed, dry_run => $o{dry_run} ? 1 : 0 };
}

1;
