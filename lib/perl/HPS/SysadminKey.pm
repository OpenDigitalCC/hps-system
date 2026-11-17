package HPS::SysadminKey;
# The installation's sysadmin SSH public keys: <config>/sysadmin_authorized_keys,
# the file the IPS serves to nodes as cmd=node_sysadmin_keys (docs/BUNDLE.md).
# list, add and remove, with strict validation of what is added. Pure Perl:
# the fingerprint is computed here, ssh-keygen is not needed on the IPS.
#
# A key that is refused is never echoed: an error names the rule, not the input
# (an operator can pass a private key by mistake).
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use MIME::Base64 qw(decode_base64 encode_base64);
use Digest::SHA qw(sha256);
use File::Temp qw(tempfile);
use File::Basename qw(dirname);

use constant MIN_RSA_BITS => 3072;
use constant MAX_INPUT    => 16384;

# Error kinds map to the tool's exit codes: refused 3, notfound 4, failed 1.
{
    package HPS::SysadminKey::Error;
    sub new   { my ($c, $kind, $msg) = @_; return bless { kind => $kind, message => $msg }, $c }
    sub kind  { $_[0]{kind} }
    sub message { $_[0]{message} }
}

sub _refuse ($msg) { die HPS::SysadminKey::Error->new(refused => $msg) }

my %CURVE = (
    'ecdsa-sha2-nistp256' => 'nistp256',
    'ecdsa-sha2-nistp384' => 'nistp384',
    'ecdsa-sha2-nistp521' => 'nistp521',
);

# The OpenSSH wire format: a sequence of uint32-length-prefixed strings.
sub _strings ($blob) {
    my @s;
    my $off = 0;
    while ($off < length $blob) {
        return undef if $off + 4 > length $blob;
        my $len = unpack('N', substr($blob, $off, 4));
        $off += 4;
        return undef if $off + $len > length $blob;
        push @s, substr($blob, $off, $len);
        $off += $len;
    }
    return \@s;
}

sub fingerprint ($blob) {
    (my $b = encode_base64(sha256($blob), '')) =~ s/=+\z//;
    return "SHA256:$b";
}

# parse_key($line, %opt): one authorized_keys line (no newline) as
# { type, bits, blob, comment, fingerprint }. Dies refused with the rule broken.
# strict (default 1) applies the policy for a NEW key (type list, RSA size);
# strict => 0 only decodes what a file already holds, for list and remove.
sub parse_key ($line, %opt) {
    my $strict = $opt{strict} // 1;
    _refuse('empty: expected one public key line') unless defined $line && $line =~ /\S/;
    _refuse('this looks like private key material; refused (use the .pub file)')
        if $line =~ /PRIVATE KEY|\A-----|BEGIN [A-Z ]+-----/;
    _refuse('more than one line: expected exactly one public key')
        if $line =~ /[\r\n]/;
    _refuse('control characters in the key line') if $line =~ /[[:cntrl:]]/;
    my ($type, $b64, $comment) = $line =~ /\A(\S+)\s+(\S+)(?:\s+(.*?))?\s*\z/
        or _refuse('not an OpenSSH public key line (type, base64 key, optional comment)');
    $comment //= '';
    if ($type !~ /\A(?:ssh-|ecdsa-|sk-)/) {
        _refuse('an options field is not accepted (and this is not a known key type): the line must start with the key type');
    }
    _refuse('dsa keys are refused') if $type eq 'ssh-dss';
    if ($strict) {
        _refuse("key type '$type' is not accepted (ed25519, ecdsa-sha2-nistp256/384/521 or rsa)")
            unless $type eq 'ssh-ed25519' || $type eq 'ssh-rsa' || exists $CURVE{$type};
    }
    _refuse('the key is not valid base64') unless $b64 =~ m{\A[A-Za-z0-9+/]+={0,2}\z} && length($b64) % 4 == 0;
    my $blob = decode_base64($b64);
    my $s = _strings($blob);
    _refuse('the key blob is malformed') unless $s && @$s >= 2;
    _refuse('the type inside the key does not match the type on the line') unless $s->[0] eq $type;
    my $bits;
    if ($type eq 'ssh-ed25519') {
        _refuse('the ed25519 key has the wrong length') unless @$s == 2 && length($s->[1]) == 32;
    }
    elsif ($type eq 'ssh-rsa') {
        _refuse('the rsa key blob is malformed') unless @$s == 3;
        (my $n = $s->[2]) =~ s/\A\0+//;
        $bits = length($n) * 8;
        $bits -= (8 - length(sprintf('%b', ord substr($n, 0, 1)))) if length $n;
        _refuse("rsa keys need at least " . MIN_RSA_BITS . " bits (this one has $bits)")
            if $strict && $bits < MIN_RSA_BITS;
    }
    elsif (exists $CURVE{$type}) {
        _refuse('the ecdsa key blob is malformed') unless @$s == 3;
        _refuse('the curve inside the key does not match its type') unless $s->[1] eq $CURVE{$type};
    }
    return { type => $type, bits => $bits, blob => $blob, comment => $comment,
             fingerprint => fingerprint($blob), line => $line };
}

sub new ($class, %opt) {
    my $base = $opt{config_base} // $ENV{HPS_CONFIG_BASE} // '/srv/hps-config';
    return bless { file => "$base/sysadmin_authorized_keys" }, $class;
}

sub file ($self) { return $self->{file} }

sub _read_lines ($self) {
    my $f = $self->{file};
    return () unless -e $f;
    open(my $fh, '<', $f) or die HPS::SysadminKey::Error->new(failed => "Cannot read $f: $!");
    my @l = <$fh>;
    close $fh;
    chomp @l;
    return @l;
}

# Every key line of the file as parsed records; other lines (comments, blanks)
# are kept by the writer and are not keys. A key line that cannot be decoded is
# reported as { bad => 1, number => N } without its text.
sub entries ($self) {
    my @out;
    my $n = 0;
    for my $l ($self->_read_lines) {
        $n++;
        next if $l =~ /\A\s*(?:#|\z)/;
        my $k = eval { parse_key($l, strict => 0) };
        push @out, $k // { bad => 1, number => $n };
    }
    return @out;
}

# Atomic write, mode 0644: temp file in the same directory, then rename.
sub _write_lines ($self, @lines) {
    my $f = $self->{file};
    my $dir = dirname($f);
    die HPS::SysadminKey::Error->new(failed => "No such directory: $dir") unless -d $dir;
    my ($fh, $tmp) = tempfile('.sysadmin_authorized_keys.XXXXXX', DIR => $dir);
    my $ok = eval {
        print {$fh} map { "$_\n" } @lines;
        close $fh or die "close: $!\n";
        chmod 0644, $tmp or die "chmod: $!\n";
        rename $tmp, $f or die "rename: $!\n";
        1;
    };
    my $err = $@;
    unlink $tmp unless $ok;
    die HPS::SysadminKey::Error->new(failed => "Cannot write $f: $err") unless $ok;
    return 1;
}

# add($text): validates one key line and appends it. Returns the key record.
sub add ($self, $text) {
    _refuse('input is too large for a public key') if length($text) > MAX_INPUT;
    (my $line = $text) =~ s/\r?\n\z//;
    my $k = parse_key($line);
    for my $e ($self->entries) {
        next if $e->{bad};
        _refuse("that key is already present ($e->{fingerprint})") if $e->{blob} eq $k->{blob};
    }
    # Keep the file as it is, a key per line; add a final newline if it lacked one.
    $self->_write_lines($self->_read_lines, $k->{line});
    return $k;
}

# remove($selector, allow_empty => 0): drops the key whose fingerprint (with or
# without the SHA256: prefix) or comment equals $selector. Dies notfound when
# none matches and refused when the selector is ambiguous or would remove the last key.
sub remove ($self, $selector, %opt) {
    _refuse('a fingerprint or comment is needed') unless defined $selector && length $selector;
    (my $fp = $selector) =~ s/\A(?!SHA256:)(?=[A-Za-z0-9+\/]{43}\z)/SHA256:/;
    my @lines = $self->_read_lines;
    my (@hit, @keep);
    my $keys_left = 0;
    my $n = 0;
    for my $l (@lines) {
        $n++;
        my $k = ($l =~ /\A\s*(?:#|\z)/) ? undef : eval { parse_key($l, strict => 0) };
        if ($k && ($k->{fingerprint} eq $fp || ($k->{comment} ne '' && $k->{comment} eq $selector))) {
            push @hit, $k;
            next;
        }
        $keys_left++ if $k;
        push @keep, $l;
    }
    die HPS::SysadminKey::Error->new(notfound => 'no key with that fingerprint or comment') unless @hit;
    my %seen = map { $_->{fingerprint} => 1 } @hit;
    _refuse('that comment matches ' . scalar(keys %seen) . ' keys; name one by its fingerprint') if keys %seen > 1;
    _refuse('that would remove the last sysadmin key: nodes would lose human access at their next refresh; '
          . 'add another key first, or pass --allow-empty')
        if !$keys_left && !$opt{allow_empty};
    $self->_write_lines(@keep);
    return $hit[0];
}

1;
