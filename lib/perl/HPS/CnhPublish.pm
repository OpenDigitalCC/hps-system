package HPS::CnhPublish;
# Publish what a container host (CNH) needs to run a cluster IPS: a tarball of
# the hps-system tree and a manifest of the files to copy (the hps-system
# tarball, the NixOS pins the inner IPS will serve, packages such as the
# ctrl-exec tarball). The CNH fetches them with cnh-ips-bootstrap over the
# outer IPS's existing HTTP (docs/CONTAINER-HOST.md).
#
# Everything is written under <resources>/packages/cnh/, which lighttpd serves
# as /packages/cnh/:
#
#   hps-system-<sha16>.tar.gz     the tree, reproducible (sorted, mtime 0,
#                                 owner 0, gzip -n), .git, tmp/ and log/ left out
#   manifest-<sha256>.json        the manifest; <sha256> is the hash of the file
#   latest                        the sha256 of the newest manifest
#
# Manifest (schema hps-cnh-manifest/1, canonical JSON):
#   {"schema": "hps-cnh-manifest/1", "created_at": "<UTC>",
#    "source": {"hps_system_commit": "<rev or unknown>", "pins": [...]},
#    "files": [{"path", "url", "sha256", "size"}, ...]}
#   path: where the file goes under /var/lib/hps-ips on the CNH
#         (hps-system.tar.gz, srv/hps-resources/nixos/..., srv/hps-resources/packages/...)
#   url:  its path under the IPS base URL (packages/..., nixos/...)
#
# Every pin is verified with HPS::Pins before it is listed (a pin that fails
# verification is refused); symlinks inside a pin are refused.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Digest::SHA ();
use File::Find ();
use File::Path ();
use POSIX qw(strftime);
use HPS::Pins;

package HPS::CnhPublish::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

our $SCHEMA = 'hps-cnh-manifest/1';
my $PIN_RE  = qr/^[a-z0-9][a-z0-9.-]+\z/;
my $DEFAULT_PACKAGE = 'packages/ctrl-exec/ctrl-exec-latest.tar.gz';

sub new ($class, %opt) {
    my $self = {
        resources => $opt{resources} // $ENV{HPS_RESOURCES}
            // (($ENV{HPS_BASE} // '/srv') . '/hps-resources'),
        system    => $opt{system} // $ENV{HPS_SYSTEM_BASE} // '/srv/hps-system',
        now       => $opt{now} // sub { time },
        pins      => $opt{pins},
        registry  => $opt{registry},
        tar       => $opt{tar} // 'tar',
    };
    return bless $self, $class;
}

sub _fail ($kind, $msg) { die HPS::CnhPublish::Error->new($kind, $msg) }

sub out_dir ($self) { return "$self->{resources}/packages/cnh" }

sub _pins ($self) {
    $self->{pins} //= HPS::Pins->new(resources => $self->{resources},
        ($self->{registry} ? (registry => $self->{registry}) : ()));
    return $self->{pins};
}

sub _sha256_file ($file) {
    my $d = Digest::SHA->new(256);
    $d->addfile($file, 'b');
    return $d->hexdigest;
}

sub _entry ($path, $url, $file) {
    return { path => $path, url => $url, sha256 => _sha256_file($file), size => -s $file };
}

# _check_rel($rel): a plain relative path, no '.', '..' or empty component.
sub _check_rel ($rel) {
    return 0 unless defined $rel && $rel =~ m{^[A-Za-z0-9_][A-Za-z0-9_.+/-]*\z};
    return 0 if $rel =~ m{//} || $rel =~ m{/\z};
    for my $seg (split m{/}, $rel) {
        return 0 if $seg eq '.' || $seg eq '..';
    }
    return 1;
}

# pin_entries($pin): manifest entries for every regular file of nixos/<pin>/,
# sorted by path. The pin must verify.
sub pin_entries ($self, $pin) {
    _fail('usage', "pin '" . ($pin // '') . "' must match ^[a-z0-9][a-z0-9.-]+\$")
        unless defined $pin && $pin =~ $PIN_RE;
    my $dir = "$self->{resources}/nixos/$pin";
    _fail('notfound', "Pin $pin does not exist under $self->{resources}/nixos") unless -d $dir;
    my $v = $self->_pins->verify_pin($pin);
    unless ($v->{ok}) {
        my $why = join('; ', map { "$_->{file}: $_->{reason}" } @{ $v->{failures} });
        _fail('refused', "Pin $pin does not verify ($why)");
    }
    my @files;
    File::Find::find({ no_chdir => 1, wanted => sub {
        my $f = $File::Find::name;
        return if $f eq $dir;
        _fail('refused', "Pin $pin holds a symlink: $f") if -l $f;
        push @files, $f if -f $f;
    } }, $dir);
    my @e;
    for my $f (sort @files) {
        my $rel = substr($f, length($dir) + 1);
        _fail('refused', "Pin $pin holds a file with an unusable name: $rel") unless _check_rel($rel);
        push @e, _entry("srv/hps-resources/nixos/$pin/$rel", "nixos/$pin/$rel", $f);
    }
    _fail('refused', "Pin $pin holds no files") unless @e;
    return @e;
}

# package_entry($rel): one file under <resources>/packages/.
sub package_entry ($self, $rel) {
    _fail('usage', "package '" . ($rel // '') . "' must be a plain path under packages/")
        unless _check_rel($rel) && $rel =~ m{^packages/[^/]};
    _fail('refused', "package $rel is under packages/cnh/ (this tool's own output)") if $rel =~ m{^packages/cnh/};
    my $f = "$self->{resources}/$rel";
    _fail('refused', "package $rel is a symlink") if -l $f;
    _fail('notfound', "package $rel not found under $self->{resources}") unless -f $f;
    return _entry("srv/hps-resources/$rel", $rel, $f);
}

sub _commit ($self) {
    my $sys = $self->{system};
    return 'unknown' unless -e "$sys/.git";
    my $pid = open(my $fh, '-|') // return 'unknown';
    if ($pid == 0) {
        open(STDERR, '>', '/dev/null');
        exec('git', '-C', $sys, 'rev-parse', 'HEAD') or POSIX::_exit(127);
    }
    my $rev = <$fh>;
    close $fh;
    return 'unknown' unless defined $rev && $rev =~ /^([0-9a-f]{40})\s*$/;
    return $1;
}

# system_tarball(): write hps-system-<sha16>.tar.gz; returns its entry.
sub system_tarball ($self) {
    my $sys = $self->{system};
    _fail('notfound', "hps-system tree $sys has no scripts/run-hps.sh") unless -f "$sys/scripts/run-hps.sh";
    my $out = $self->out_dir;
    File::Path::make_path($out);
    my $tmp = "$out/.hps-system.tar.gz.tmp-$$";
    unlink $tmp;
    my @cmd = ($self->{tar}, '--sort=name', '--mtime=@0', '--owner=0', '--group=0', '--numeric-owner',
        '--anchored', '--exclude=./.git', '--exclude=./tmp', '--exclude=./log',
        '--exclude=*.sw?', '-I', 'gzip -n', '-C', $sys, '-cf', $tmp, '.');
    if (system(@cmd) != 0) {
        unlink $tmp;
        _fail('failed', "tar of $sys failed (exit " . ($? >> 8) . ')');
    }
    my $sha = _sha256_file($tmp);
    my $name = 'hps-system-' . substr($sha, 0, 16) . '.tar.gz';
    if (-f "$out/$name" && _sha256_file("$out/$name") eq $sha) {
        unlink $tmp;
    } else {
        rename($tmp, "$out/$name") or _fail('failed', "rename $tmp: $!");
    }
    return { path => 'hps-system.tar.gz', url => "packages/cnh/$name", sha256 => $sha, size => -s "$out/$name" };
}

# publish(pins => [...], packages => [...]): writes the tarball and the
# manifest; returns {sha256, manifest, url, files}. packages defaults to the
# ctrl-exec tarball the IPS installs its dispatcher from.
sub publish ($self, %o) {
    my @pins = @{ $o{pins} // [] };
    _fail('usage', 'at least one pin is required') unless @pins;
    my %seen;
    for my $p (@pins) {
        _fail('usage', "pin $p given twice") if $seen{$p}++;
    }
    my @packages = @{ $o{packages} // [] };
    @packages = ($DEFAULT_PACKAGE) unless @packages;
    # Every input is checked before anything is written.
    my @files;
    push @files, $self->pin_entries($_) for @pins;
    my %pk;
    for my $rel (@packages) {
        _fail('usage', "package $rel given twice") if $pk{$rel}++;
        push @files, $self->package_entry($rel);
    }
    unshift @files, $self->system_tarball;
    my $doc = {
        schema     => $SCHEMA,
        created_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($self->{now}->())),
        source     => { hps_system_commit => $self->_commit, pins => [@pins] },
        files      => \@files,
    };
    my $json = JSON::PP->new->canonical->pretty->encode($doc);
    my $sha = Digest::SHA::sha256_hex($json);
    my $out = $self->out_dir;
    my $name = "manifest-$sha.json";
    _write_atomic("$out/$name", $json);
    _write_atomic("$out/latest", "$sha\n");
    return { sha256 => $sha, manifest => "$out/$name", url => "packages/cnh/$name", files => scalar @files };
}

sub _write_atomic ($file, $text) {
    my $tmp = "$file.tmp-$$";
    open(my $fh, '>:raw', $tmp) or _fail('failed', "$tmp: $!");
    print {$fh} $text or _fail('failed', "$tmp: $!");
    close $fh or _fail('failed', "$tmp: $!");
    rename($tmp, $file) or _fail('failed', "rename $tmp: $!");
    return;
}

1;
