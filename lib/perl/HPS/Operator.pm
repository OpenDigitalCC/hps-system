package HPS::Operator;
# Operator credentials for the IPS's own ctrl-exec API (docs/OPERATOR.md).
#
# An operator credential is an opaque random token. The IPS keeps only its
# SHA-256, in the keysafe (stored secret "operator-<name>": JSON
# {"sha256": <hex>, "issued": <epoch>}), and shows the token once, at issue.
# The HPS auth hook (scripts/ctrl-exec-auth-hook.sh) runs as the API's user
# (ctrl-exec), which cannot read the root-only keysafe, so every issue and
# revoke rewrites the hook's view: <dispatcher conf dir>/hps-operators, one
# "<name> <sha256>" line per live credential, root:ctrl-exec 0640. A digest of
# a 256-bit random token gives nothing away. The keysafe is the record;
# export() rebuilds the file from it (IPS start runs it).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_NOFOLLOW);
use JSON::PP;
use HPS::Keysafe;

package HPS::Operator::Error {
    # kind: usage, refused, notfound, failed
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

my $NAME_RE  = qr/\A[a-z][a-z0-9-]{0,31}\z/;
my $TOKEN_RE = qr/\Ahpsop_[0-9a-f]{64}\z/;
my $PREFIX   = 'operator-';

sub _fail ($kind, $msg) { die HPS::Operator::Error->new($kind, $msg) }

# new(keysafe => $ks, export_path => $path [, group => 'ctrl-exec', now => sub])
sub new ($class, %opt) {
    my $conf = $ENV{CTRL_EXEC_DISPATCHER_CONF_DIR} // '/etc/ctrl-exec-dispatcher';
    return bless {
        keysafe     => $opt{keysafe} // HPS::Keysafe->new,
        export_path => $opt{export_path} // "$conf/hps-operators",
        group       => $opt{group} // 'ctrl-exec',
        now         => $opt{now} // sub { time },
    }, $class;
}

sub keysafe ($self)     { return $self->{keysafe} }
sub export_path ($self) { return $self->{export_path} }

sub valid_name ($name) { return defined $name && $name =~ $NAME_RE ? 1 : 0 }

sub _check_name ($name) {
    _fail('usage', 'An operator name is 1-32 of a-z 0-9 -, starting with a letter: ' . ($name // ''))
        unless valid_name($name);
    return $name;
}

sub _token () {
    open(my $fh, '<:raw', '/dev/urandom') or _fail('failed', "Cannot open /dev/urandom: $!");
    my $buf = '';
    while (length $buf < 32) {
        my $got = sysread($fh, $buf, 32 - length $buf, length $buf);
        _fail('failed', 'Cannot read /dev/urandom') unless $got;
    }
    close $fh;
    return 'hpsop_' . unpack('H*', $buf);
}

sub _record ($self, $name) {
    my $raw = $self->{keysafe}->get_secret($PREFIX . $name) // return undef;
    my $r = eval { decode_json($raw) };
    return undef unless ref $r eq 'HASH' && ($r->{sha256} // '') =~ /\A[0-9a-f]{64}\z/;
    return $r;
}

# issue($name): a new credential. Refused when <name> already has one (revoke
# it first). Returns { name, token, issued }; the token is in no other place.
sub issue ($self, $name) {
    _check_name($name);
    _fail('refused', "Operator $name already has a credential; revoke it first")
        if $self->{keysafe}->has_secret($PREFIX . $name);
    my $token  = _token();
    my $issued = $self->{now}->();
    $self->{keysafe}->put_secret($PREFIX . $name,
        JSON::PP->new->canonical->encode({ sha256 => sha256_hex($token), issued => 0 + $issued }));
    $self->export;
    return { name => $name, token => $token, issued => $issued };
}

# list(): [ { name, issued } ], sorted by name. Never a digest or a token.
sub list ($self) {
    my @out;
    for my $s ($self->{keysafe}->list_secrets($PREFIX)) {
        my $name = substr($s, length $PREFIX);
        next unless valid_name($name);
        my $r = $self->_record($name) // next;
        push @out, { name => $name, issued => $r->{issued} };
    }
    return \@out;
}

# revoke($name): the credential is gone from the keysafe and from the hook's
# file; a call with it is refused from then on. notfound when there is none.
sub revoke ($self, $name) {
    _check_name($name);
    _fail('notfound', "Operator $name has no credential")
        unless $self->{keysafe}->delete_secret($PREFIX . $name);
    $self->export;
    return 1;
}

# verify($token): the operator name the token belongs to, or undef (the rule
# the hook applies, here for tests and tools).
sub verify ($self, $token) {
    return undef unless defined $token && $token =~ $TOKEN_RE;
    my $h = sha256_hex($token);
    for my $o (@{ $self->list }) {
        my $r = $self->_record($o->{name}) // next;
        return $o->{name} if $r->{sha256} eq $h;
    }
    return undef;
}

# export(): rewrite the hook's file from the keysafe, atomically. Returns the
# number of credentials written.
sub export ($self) {
    my $path = $self->{export_path};
    (my $dir = $path) =~ s{/[^/]+\z}{};
    _fail('failed', "No directory for $path (is the dispatcher set up?)") unless -d $dir;
    my $text = "# HPS operator credentials (hps-operator): <name> <sha256 of the token>.\n"
        . "# Generated from the keysafe; do not edit.\n";
    my $n = 0;
    for my $o (@{ $self->list }) {
        my $r = $self->_record($o->{name}) // next;
        $text .= "$o->{name} $r->{sha256}\n";
        $n++;
    }
    my $tmp = sprintf('%s/.hps-operators.%d.%d', $dir, $$, int(rand(1e9)));
    my $old = umask(027);
    my $ok  = sysopen(my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0640);
    my $err = "$!";
    umask($old);
    _fail('failed', "Cannot create $tmp: $err") unless $ok;
    my $wrote = syswrite($fh, $text);
    my $closed = close $fh;
    unless (defined $wrote && $wrote == length $text && $closed) {
        unlink $tmp;
        _fail('failed', "Cannot write $tmp");
    }
    chmod 0640, $tmp;
    if ($> == 0) {
        my $gid = getgrnam($self->{group});
        chown(0, $gid, $tmp) if defined $gid;
    }
    unless (rename $tmp, $path) {
        my $e = "$!";
        unlink $tmp;
        _fail('failed', "Cannot place $path: $e");
    }
    return $n;
}

1;
