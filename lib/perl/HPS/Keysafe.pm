package HPS::Keysafe;
# Secret store for the IPS: raw random keys on disk, root-only.
#
#   ${config_base}/clusters/<cluster>/keysafe/            0700, owned by the running uid
#   ${config_base}/clusters/<cluster>/keysafe/<mac12>/    0700, one dir per host
#   .../<mac12>/<name>.key                                0600, 32 random bytes
#   .../<purpose>.hmac                                    0600, 32 random bytes
#
# Key material never enters the registry JSON, an image or a log. It is
# returned only by get_or_create_key and cluster_secret; no other method and
# no error message carries it. A directory or file that is group/world
# accessible, a symlink, or not owned by the running uid is refused (kind
# 'perms') and never chmod'ed silently; repair_permissions is the operator's
# explicit call.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_RDONLY O_CREAT O_EXCL O_NOFOLLOW);
use IO::Handle;
use HPS::Registry;

package HPS::Keysafe::Error {
    # kind: usage, refused, notfound, failed, perms, malformed, tampered, expired
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $KEY_BYTES = 32;
my $NAME_RE   = qr/^[A-Za-z0-9][A-Za-z0-9_.-]*$/;

sub _fail ($kind, $msg) { die HPS::Keysafe::Error->new($kind, $msg) }

# new(registry => $reg | registry_opts => {...}, cluster => $name)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $self = bless { registry => $reg, cluster => $opt{cluster} }, $class;
    return $self;
}

sub registry ($self) { return $self->{registry} }

sub cluster ($self) {
    $self->{cluster} //= eval { $self->{registry}->active_cluster };
    _fail('failed', 'No active cluster for the keysafe') unless defined $self->{cluster};
    return $self->{cluster};
}

sub dir ($self) {
    my $cdir = eval { $self->{registry}->cluster_dir($self->cluster) };
    _fail('failed', 'Cannot locate the cluster directory') unless defined $cdir;
    return "$cdir/keysafe";
}

sub _check_name ($what, $name) {
    _fail('usage', "Invalid $what name: " . ($name // ''))
        unless defined $name && $name =~ $NAME_RE && $name !~ /\.\./;
    return $name;
}

sub _mac ($mac) {
    my $m = eval { HPS::Registry::normalise_mac($mac) };
    _fail('usage', 'Invalid MAC address: ' . ($mac // '')) unless defined $m;
    return $m;
}

#--- permission checks ---------------------------------------------------------

# Why the entry is not acceptable ('' when it is). $want: 'dir' or 'file'.
sub _perm_problem ($path, $want) {
    my @st = lstat($path);
    return 'does not exist' unless @st;
    return 'is a symlink' if -l _;
    return 'is not a directory' if $want eq 'dir' && !-d _;
    return 'is not a regular file' if $want eq 'file' && !-f _;
    return sprintf('is owned by uid %d, not %d', $st[4], $>) if $st[4] != $>;
    my $mode = $st[2] & 07777;
    return sprintf('has mode %04o (group/world accessible)', $mode) if $mode & 077;
    return '';
}

sub _check_dir ($path) {
    my $p = _perm_problem($path, 'dir');
    _fail('perms', "Keysafe directory $path $p; run the operator repair (HPS::Keysafe repair_permissions)")
        if $p;
    return 1;
}

sub _make_dir ($path) {
    return 1 if -e $path || -l $path;
    my $old = umask(077);
    my $ok  = mkdir($path, 0700);
    my $err = "$!";
    umask($old);
    _fail('failed', "Cannot create $path: $err") unless $ok || -d $path;
    return 1;
}

# Create (if absent) and check the keysafe dir; with $mac also the host dir.
sub _ensure ($self, $mac = undef) {
    my $dir = $self->dir;
    _fail('notfound', "Cluster directory for the keysafe does not exist")
        unless -d ($dir =~ s{/keysafe\z}{}r);
    _make_dir($dir);
    _check_dir($dir);
    return $dir unless defined $mac;
    my $sub = "$dir/" . _mac($mac);
    _make_dir($sub);
    _check_dir($sub);
    return $sub;
}

# Read-only variant: the directory must already be there and acceptable.
sub _existing ($self, $mac = undef) {
    my $dir = $self->dir;
    return undef unless -d $dir;
    _check_dir($dir);
    return $dir unless defined $mac;
    my $sub = "$dir/" . _mac($mac);
    return undef unless -d $sub;
    _check_dir($sub);
    return $sub;
}

#--- key files -------------------------------------------------------------------

sub _random ($n) {
    open(my $fh, '<:raw', '/dev/urandom') or _fail('failed', "Cannot open /dev/urandom: $!");
    my $buf = '';
    while (length $buf < $n) {
        my $got = sysread($fh, $buf, $n - length $buf, length $buf);
        _fail('failed', "Cannot read /dev/urandom: " . ($! || 'EOF')) unless $got;
    }
    close $fh;
    return $buf;
}

sub _read_key ($path) {
    my $p = _perm_problem($path, 'file');
    _fail('perms', "Key file $path $p") if $p;
    sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or _fail('failed', "Cannot open $path: $!");
    binmode $fh;
    my $size = -s $fh;
    _fail('perms', "Key file $path is not $KEY_BYTES bytes") unless defined $size && $size == $KEY_BYTES;
    my $buf = '';
    my $got = read($fh, $buf, $KEY_BYTES);
    close $fh;
    _fail('failed', "Cannot read $path") unless defined $got && $got == $KEY_BYTES;
    return $buf;
}

# Write 32 fresh random bytes to a temp file, then link() it into place: the
# name appears complete or not at all, and a racing creator loses cleanly.
# Returns the bytes that are now stored under $path (ours or the winner's).
sub _create_key ($path) {
    my $dir = $path =~ s{/[^/]+\z}{}r;
    my $tmp = sprintf('%s/.tmp.%d.%s', $dir, $$, unpack('H*', _random(6)));
    my $old = umask(077);
    my $key = _random($KEY_BYTES);
    my $ok  = sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    my $err = "$!";
    umask($old);
    _fail('failed', "Cannot create a temporary key file in $dir: $err") unless $ok;
    binmode $fh;
    my $wrote = syswrite($fh, $key);
    $fh->flush;
    $fh->sync;
    my $closed = close $fh;
    if (!defined $wrote || $wrote != $KEY_BYTES || !$closed) {
        unlink $tmp;
        _fail('failed', "Cannot write a temporary key file in $dir");
    }
    if (link($tmp, $path)) {
        unlink $tmp;
        return $key;
    }
    my $lerr = $!;
    unlink $tmp;
    _fail('failed', "Cannot place $path: $lerr") unless -e $path || -l $path;
    return _read_key($path);   # lost the race, or it was already there
}

sub _get_or_create ($self, $dir, $file) {
    my $path = "$dir/$file";
    return _read_key($path) if -e $path || -l $path;
    return _create_key($path);
}

# The key for one host and name; created on first use. Returns raw bytes.
sub get_or_create_key ($self, $mac, $name) {
    _check_name('key', $name);
    my $dir = $self->_ensure($mac);
    return $self->_get_or_create($dir, "$name.key");
}

sub has_key ($self, $mac, $name) {
    _check_name('key', $name);
    my $dir = $self->_existing($mac) // return 0;
    return -f "$dir/$name.key" ? 1 : 0;
}

# Only ever called explicitly by the operator. Returns 1 if a key was removed.
sub delete_key ($self, $mac, $name) {
    _check_name('key', $name);
    my $dir = $self->_existing($mac) // return 0;
    my $path = "$dir/$name.key";
    return 0 unless -e $path || -l $path;
    unlink $path or _fail('failed', "Cannot remove $path: $!");
    return 1;
}

# Names of the keys held for a host, sorted, without the .key suffix.
sub list ($self, $mac) {
    my $dir = $self->_existing($mac) // return ();
    opendir(my $dh, $dir) or _fail('failed', "Cannot read $dir: $!");
    my @names = sort map { /^(.+)\.key\z/ && $_ !~ /^\./ ? $1 : () } readdir $dh;
    closedir $dh;
    return @names;
}

# The per-cluster secret for a purpose (e.g. 'approval'); created on first use.
sub cluster_secret ($self, $purpose) {
    _check_name('purpose', $purpose);
    my $dir = $self->_ensure;
    return $self->_get_or_create($dir, "$purpose.hmac");
}

#--- operator repair ---------------------------------------------------------------

# Explicit operator action: set 0700 on the directories and 0600 on the key
# files, and (as root) chown them to the running uid. Symlinks are never
# followed. Returns the paths changed.
sub repair_permissions ($self) {
    my $dir = $self->dir;
    _fail('notfound', "No keysafe directory at $dir") unless -d $dir && !-l $dir;
    my @changed;
    my $fix = sub ($path, $mode) {
        my @st = lstat($path) or return;
        return if -l _;
        my $touched = 0;
        if ($st[4] != $>) {
            _fail('perms', "$path is owned by uid $st[4] and cannot be taken over by uid $>")
                unless $> == 0 && chown($>, -1, $path);
            $touched = 1;
        }
        if (($st[2] & 07777) != $mode) {
            chmod($mode, $path) or _fail('failed', "Cannot chmod $path: $!");
            $touched = 1;
        }
        push @changed, $path if $touched;
    };
    $fix->($dir, 0700);
    opendir(my $dh, $dir) or _fail('failed', "Cannot read $dir: $!");
    for my $e (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
        my $p = "$dir/$e";
        if (-d $p && !-l $p) {
            $fix->($p, 0700);
            opendir(my $sh, $p) or next;
            for my $f (sort grep { $_ ne '.' && $_ ne '..' } readdir $sh) {
                $fix->("$p/$f", 0600) if -f "$p/$f" && !-l "$p/$f";
            }
            closedir $sh;
        }
        elsif (-f $p && !-l $p) {
            $fix->($p, 0600);
        }
    }
    closedir $dh;
    return @changed;
}

1;
