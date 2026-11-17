#!/usr/bin/env perl
# hps-cluster-config sysadmin-key list|add|remove: the installation's sysadmin SSH
# public keys, <config>/sysadmin_authorized_keys. Strict validation, atomic 0644
# write, the last key is not removed without --allow-empty.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use MIME::Base64 qw(encode_base64);
use lib "$Bin/../lib/perl";
use HPS::SysadminKey;

my $tool = "$Bin/../bin/hps-cluster-config";
my $base = tempdir(CLEANUP => 1);
my $file = "$base/sysadmin_authorized_keys";

sub s4 { return pack('N', length $_[0]) . $_[0] }
sub b64 { return encode_base64($_[0], '') }
sub ed25519 { my ($seed, $c) = @_; my $b = b64(s4('ssh-ed25519') . s4(chr($seed) x 32)); return "ssh-ed25519 $b" . (defined $c ? " $c" : '') }
sub rsa {
    my ($bits, $c) = @_;
    my $n = "\x80" . ("\x01" x (($bits / 8) - 1));
    my $b = b64(s4('ssh-rsa') . s4("\x01\x00\x01") . s4("\0" . $n));   # mpint with a leading zero byte
    return "ssh-rsa $b" . (defined $c ? " $c" : '');
}
sub ecdsa { my ($c) = @_; my $b = b64(s4('ecdsa-sha2-nistp256') . s4('nistp256') . s4("\x04" . ("\x07" x 64))); return "ecdsa-sha2-nistp256 $b $c" }

# run the tool: returns (exit code, stdout, stderr)
sub run {
    my ($stdin, @args) = @_;
    my $in  = "$base/.stdin";
    my $out = "$base/.out";
    my $err = "$base/.err";
    open(my $fh, '>', $in) or die; print {$fh} $stdin // ''; close $fh;
    my $rc = system("$^X -I$Bin/../lib/perl $tool --config-base $base @args < $in > $out 2> $err");
    local $/;
    open(my $o, '<', $out); my $so = <$o>; close $o;
    open(my $e, '<', $err); my $se = <$e>; close $e;
    return ($rc >> 8, $so, $se);
}
sub slurp { open(my $f, '<', $_[0]) or return undef; local $/; my $t = <$f>; return $t }

# --- empty
my ($rc, $o, $e) = run('', 'sysadmin-key list');
is($rc, 0, 'list on a missing file exits 0');
like($e, qr/no sysadmin key/, 'and says there is none');

# --- add: accepted types
my $k1 = ed25519(1, 'alice@work');
($rc, $o, $e) = run("$k1\n", 'sysadmin-key add -');
is($rc, 0, 'add an ed25519 key on stdin') or diag $e;
like($o, qr/added ssh-ed25519 SHA256:\S+ alice\@work/, 'prints type, fingerprint and comment');
like($o, qr/next bundle-refresh or boot/, 'says when nodes take it');
is(sprintf('%04o', (stat $file)[2] & 07777), '0644', 'mode 0644');
is(slurp($file), "$k1\n", 'the line is in the file');
is((glob("$base/.sysadmin_authorized_keys.*"))[0], undef, 'no temp file is left');

my $kf = "$base/new.pub";
open(my $fh, '>', $kf) or die; print {$fh} ecdsa('bob@ecdsa'), "\n"; close $fh;
($rc, $o, $e) = run('', 'sysadmin-key add', $kf);
is($rc, 0, 'add an ecdsa key from a file') or diag $e;
($rc, $o, $e) = run('', 'sysadmin-key add -');
is($rc, 3, 'empty input refused');

open($fh, '>', $kf); print {$fh} rsa(3072, 'carol@rsa'), "\n"; close $fh;
($rc, $o, $e) = run('', 'sysadmin-key add', $kf);
is($rc, 0, 'rsa of 3072 bits accepted') or diag $e;

# --- refusals
my %bad = (
    'rsa 2048 bits'       => [ rsa(2048, 'x'),                                       qr/at least 3072 bits \(this one has 2048\)/ ],
    'dsa'                 => [ 'ssh-dss ' . b64(s4('ssh-dss') . s4('x')) . ' d',   qr/dsa keys are refused/ ],
    'options field'       => [ 'command="/bin/sh" ' . ed25519(9, 'o'),              qr/options field/ ],
    'from= option'        => [ 'from="10.0.0.1" ' . ed25519(9, 'o'),                qr/options field/ ],
    'bad base64'          => [ 'ssh-ed25519 not*base64!! c',                         qr/not valid base64/ ],
    'type mismatch'       => [ 'ssh-ed25519 ' . b64(s4('ssh-rsa') . s4('x') . s4('y')) . ' m', qr/type inside the key does not match/ ],
    'two lines'           => [ ed25519(3, 'a') . "\n" . ed25519(4, 'b'),            qr/more than one line/ ],
    'private key'         => [ "-----BEGIN OPENSSH PRIVATE KEY-----\nSECRETSECRETSECRET\n-----END OPENSSH PRIVATE KEY-----", qr/private key material/ ],
    'sk key'              => [ 'sk-ssh-ed25519@openssh.com ' . b64(s4('sk-ssh-ed25519@openssh.com') . s4('x')) . ' s', qr/not accepted/ ],
    'short ed25519'       => [ 'ssh-ed25519 ' . b64(s4('ssh-ed25519') . s4('short')) . ' s', qr/wrong length/ ],
);
for my $name (sort keys %bad) {
    my $before = slurp($file);
    ($rc, $o, $e) = run($bad{$name}[0] . "\n", 'sysadmin-key add -');
    is($rc, 3, "refused: $name");
    like($e, $bad{$name}[1], "  reason named: $name");
    is(slurp($file), $before, "  file unchanged: $name");
    unlike($e . $o, qr/SECRETSECRET/, "  the input is not echoed: $name");
}

# --- duplicates compare key blobs, not comments
($rc, $o, $e) = run(ed25519(1, 'a different comment') . "\n", 'sysadmin-key add -');
is($rc, 3, 'the same key under another comment is a duplicate');
like($e, qr/already present \(SHA256:/, 'names the existing fingerprint');

# --- list
($rc, $o, $e) = run('', 'sysadmin-key list');
is($rc, 0, 'list');
my @l = split /\n/, $o;
is(scalar @l, 3, 'three keys');
like($l[0], qr/\Assh-ed25519 SHA256:[A-Za-z0-9+\/]{43} alice\@work\z/, 'type, fingerprint, comment');
like($l[1], qr/\Aecdsa-sha2-nistp256 SHA256:\S+ bob\@ecdsa\z/, 'ecdsa line');
($rc, $o, $e) = run('', 'sysadmin-key list --json');
like($o, qr/"fingerprint"/, 'list --json');

# the fingerprint agrees with ssh-keygen when it is installed
SKIP: {
    my $sk = `command -v ssh-keygen 2>/dev/null`; chomp $sk;
    skip 'ssh-keygen is not installed', 2 unless $sk;
    # ssh-keygen needs a real key; make one, add it and compare
    my $kd = "$base/kg"; mkdir $kd;
    system($sk, '-q', '-t', 'ed25519', '-N', '', '-C', 'real@test', '-f', "$kd/k") == 0 or skip 'ssh-keygen failed', 2;
    my ($r2, $o2, $e2) = run('', 'sysadmin-key add', "$kd/k.pub");
    is($r2, 0, 'a real ssh-keygen key is accepted') or diag $e2;
    my $want = `$sk -lf $kd/k.pub`;
    my ($fp) = $want =~ /(SHA256:\S+)/;
    like($o2, qr/\Q$fp\E/, 'fingerprint equals ssh-keygen -l');
    run('', 'sysadmin-key remove real@test');
}

# --- remove
($rc, $o, $e) = run('', 'sysadmin-key list');
my ($fp_bob) = $o =~ /ecdsa-sha2-nistp256 (SHA256:\S+)/;
($rc, $o, $e) = run('', 'sysadmin-key remove', $fp_bob);
is($rc, 0, 'remove by fingerprint') or diag $e;
unlike(slurp($file), qr/ecdsa/, 'it is gone');
($rc, $o, $e) = run('', 'sysadmin-key remove carol@rsa');
is($rc, 0, 'remove by comment');
($rc, $o, $e) = run('', 'sysadmin-key remove nobody@nowhere');
is($rc, 4, 'no match: exit 4');
is(sprintf('%04o', (stat $file)[2] & 07777), '0644', 'mode still 0644 after a rewrite');

($rc, $o, $e) = run('', 'sysadmin-key remove alice@work');
is($rc, 3, 'the last key is refused');
like($e, qr/last sysadmin key.*--allow-empty/, 'and says how to override');
like(slurp($file), qr/alice\@work/, 'the file is unchanged');
($rc, $o, $e) = run('', 'sysadmin-key remove alice@work --allow-empty');
is($rc, 0, '--allow-empty removes the last key');
($rc, $o, $e) = run('', 'sysadmin-key list');
like($e, qr/no sysadmin key/, 'then there is none');

# comments in the file survive and are not keys
open($fh, '>', $file); print {$fh} "# installer key\n", ed25519(5, 'keep@me'), "\n", ed25519(6, 'drop@me'), "\n"; close $fh;
($rc, $o, $e) = run('', 'sysadmin-key remove drop@me');
is($rc, 0, 'remove with a comment line in the file');
is(slurp($file), "# installer key\n" . ed25519(5, 'keep@me') . "\n", 'the comment line and the other key are kept');

# the node side still serves what the tool wrote (same well-formedness rule)
my $kd = HPS::SysadminKey::parse_key(ed25519(7, 'z'));
is($kd->{type}, 'ssh-ed25519', 'parse_key on its own');

($rc, $o, $e) = run('', 'sysadmin-key frobnicate');
is($rc, 2, 'unknown verb: usage');
done_testing;
