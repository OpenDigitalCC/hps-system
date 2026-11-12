package HPS::Repo;
# IPS-side driver of the site repository (docs/REPOSITORY.md): the operator
# verbs repo update, repo build, repo seed and repo status. The repository is a
# node role; for now it lives on the image builder's disk, so the node scripts
# are the builder image's (repo-update, builder-build, repo-seed,
# repo-status). The host is the cluster key repo_host; with no repo_host every
# verb is refused.
#
# update, build and seed outlast a ctrl-exec call: the node script starts the
# transient unit hps-builder-build and returns; start() returns the job id and
# wait() polls repo-status until the job ends.
#
# status() stores the repository's public key as the cluster key
# repo_nix_pubkey when that is empty, and reports a mismatch (a new key on the
# node) without changing the stored one.
#
# Every collaborator is injectable (registry, runner, publisher, logger, now,
# sleep) so the module is testable without a node.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use File::Path ();
use HPS::Registry;
use HPS::Storage ();
use HPS::CnhPublish ();

package HPS::Repo::Error {
    # kind: usage (2), refused (3), notfound (4), failed (1)
    sub new ($class, $kind, $message) { return bless { kind => $kind, message => $message }, $class }
    sub kind ($self)    { return $self->{kind} }
    sub message ($self) { return $self->{message} }
}

our %SCRIPT = (update => 'repo-update', build => 'builder-build', seed => 'repo-seed');
my %STARTED = (update => 'REPO-UPDATE', build => 'BUILDER-BUILD', seed => 'REPO-SEED');
my $SHA_RE     = qr/^[0-9a-f]{64}\z/;
my $PROFILE_RE = qr/^[a-z][a-z0-9-]{0,31}\z/;
my $INPUT_RE   = qr/^(?:ctrl-exec|ctrl-exec-plugins)=[0-9a-f]{64}\z/;
my $URL_RE     = qr{^http://[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?(?:/[A-Za-z0-9._-]+)*/?\z};
my $PATH_RE    = qr{^/nix/store/[0-9a-df-np-sv-z]{32}-[A-Za-z0-9+._?=-]+\z};
our $PUBKEY_RE = qr{^[A-Za-z0-9][A-Za-z0-9._-]{0,63}:[A-Za-z0-9+/]{43}=\z};

sub _fail ($kind, $msg) { die HPS::Repo::Error->new($kind, $msg) }

# new(registry => $reg, runner => $obj (call(mac, script, args)), publisher =>
#     $obj (system_tarball()), resources => DIR, logger => sub ($level, $msg),
#     now => sub, sleep => sub ($s), poll => SECONDS)
sub new ($class, %opt) {
    my $reg = $opt{registry} // HPS::Registry->new(%{ $opt{registry_opts} // {} });
    my $res = $opt{resources} // $ENV{HPS_RESOURCES} // (($ENV{HPS_BASE} // '/srv') . '/hps-resources');
    return bless {
        registry  => $reg,
        runner    => $opt{runner} // HPS::Storage::Runner::HpsRun->new,
        publisher => $opt{publisher} // HPS::CnhPublish->new(resources => $res),
        resources => $res,
        logger    => $opt{logger} // \&_default_logger,
        now       => $opt{now} // sub { time },
        sleep     => $opt{sleep} // sub ($s) { sleep $s },
        poll      => $opt{poll} // $ENV{HPS_REPO_POLL} // 30,
    }, $class;
}

sub _default_logger ($level, $msg) {
    print STDERR "hps-repo: $msg\n";
    return if $ENV{HPS_REPO_NO_SYSLOG};
    eval {
        local $SIG{__WARN__} = sub { };
        system('logger', '-t', 'hps', '-p', "local0.$level", "hps-repo: $msg");
    };
    return;
}

sub _log ($self, $level, $msg) { $self->{logger}->($level, $msg); return }

sub _cluster ($self) {
    my $c = $self->{registry}->active_cluster;
    _fail('notfound', 'no active cluster') unless defined $c && length $c;
    return $c;
}

sub _cluster_val ($self, $key) {
    my $reg = $self->{registry};
    my $c = $self->_cluster;
    return $reg->cluster_exists($c, $key) ? $reg->cluster_get($c, $key) : undef;
}

# host(): {mac, name} of the repository host (cluster key repo_host, a MAC or
# a registry HOSTNAME, whole or first label). Refused when unset.
sub host ($self) {
    return $self->{host} if $self->{host};
    my $want = $self->_cluster_val('repo_host');
    _fail('refused', 'the cluster key repo_host is not set: no site repository host is known '
        . '(hps-cluster-config set repo_host <host>)') unless defined $want && length $want;
    my $reg = $self->{registry};
    my $mac = eval { $reg->resolve_mac($want) };
    if (defined $mac && $reg->host_exists($mac)) {
        return $self->{host} = { mac => $mac, name => $want };
    }
    for my $m ($reg->host_list_all) {
        my $name = $reg->host_exists($m, 'HOSTNAME') ? $reg->host_get($m, 'HOSTNAME') : undef;
        next unless defined $name;
        return $self->{host} = { mac => $m, name => $want }
            if $name eq $want || HPS::Registry::short_name($name) eq HPS::Registry::short_name($want);
    }
    _fail('notfound', "repo_host '$want' matches no host in the registry");
}

# _call(script, @args) -> {rc, stdout, stderr}; a node refusal (3) is refused,
# any other non-zero exit failed, with the script's last stderr line.
sub _call ($self, $script, @args) {
    my $h = $self->host;
    my $r = $self->{runner}->call(mac => $h->{mac}, script => $script, args => [@args], input => undef);
    return $r if $r->{rc} == 0;
    my @err = grep { length && !/^\+ / } split /\n/, ($r->{stderr} // '');
    my $last = $err[-1] // '';
    _fail($r->{rc} == 3 ? 'refused' : 'failed', "$script on $h->{name} exited $r->{rc}" . (length $last ? ": $last" : ''));
}

# status(log => N): {output, fields => {state, key, paths, ...}, pubkey,
# key_state => stored|same|none|mismatch, stored => the cluster key}.
sub status ($self, %o) {
    my $n = $o{log} // 20;
    _fail('usage', '--log takes 0 to 2000') unless $n =~ /^[0-9]{1,4}\z/ && $n <= 2000;
    my $r = $self->_call('repo-status', '--log', $n);
    my $out = $r->{stdout} // '';
    my ($line) = $out =~ /^REPO (state=.*)$/m;
    _fail('failed', 'repo-status gave no REPO line') unless defined $line;
    my %f = map { split /=/, $_, 2 } grep {/=/} split / /, $line;
    my ($pub) = $out =~ /^REPO-PUBKEY (\S+)$/m;
    my $stored = $self->_cluster_val('repo_nix_pubkey');
    $stored = undef if defined $stored && !length $stored;
    my $ks = 'none';
    if (defined $pub) {
        _fail('failed', "repo-status printed a public key of another shape: $pub") unless $pub =~ $PUBKEY_RE;
        if (!defined $stored) {
            $self->{registry}->cluster_set($self->_cluster, 'repo_nix_pubkey', $pub);
            $self->_log('info', "stored the repository public key as repo_nix_pubkey: $pub");
            $ks = 'stored';
            $stored = $pub;
        } elsif ($stored eq $pub) {
            $ks = 'same';
        } else {
            $self->_log('err', "the repository key on the node ($pub) is not repo_nix_pubkey ($stored): left unchanged");
            $ks = 'mismatch';
        }
    }
    return { output => $out, fields => \%f, pubkey => $pub, key_state => $ks, stored => $stored };
}

# source(source => SHA): the sha256 of the source tarball to use: the one
# given (already in packages/cnh/), else this IPS's own tree, published now
# (hps-cnh-publish --source-only).
sub source ($self, %o) {
    if (defined $o{source}) {
        _fail('usage', '--source must be a sha256 (64 lowercase hex digits)') unless $o{source} =~ $SHA_RE;
        return $o{source};
    }
    my $e = eval { $self->{publisher}->system_tarball };
    unless ($e) {
        my $err = $@;
        _fail('failed', 'publishing the source tarball: ' . (ref $err && $err->can('message') ? $err->message : $err));
    }
    return $e->{sha256};
}

# seed_list(from => 'ips'|URL, paths => FILE): write the list of store paths to
# import as packages/repo/seed-<sha16>.txt (sorted, one per line); returns its
# sha256. From the IPS's own cache the list is every narinfo's StorePath under
# <resources>/nix-cache; from another cache it is FILE.
sub seed_list ($self, %o) {
    local $/ = "\n";
    my $from = $o{from} // 'ips';
    my @paths;
    if (defined $o{paths}) {
        open my $fh, '<', $o{paths} or _fail('notfound', "cannot read $o{paths}: $!");
        while (my $l = <$fh>) {
            chomp $l;
            next unless length $l;
            _fail('usage', "$o{paths}: '$l' is not a store path") unless $l =~ $PATH_RE;
            push @paths, $l;
        }
        close $fh;
    } elsif ($from eq 'ips') {
        my $dir = "$self->{resources}/nix-cache";
        opendir(my $dh, $dir) or _fail('notfound', "no IPS cache at $dir: $!");
        for my $f (sort grep {/\.narinfo\z/} readdir $dh) {
            open my $fh, '<', "$dir/$f" or _fail('failed', "cannot read $dir/$f: $!");
            while (my $l = <$fh>) {
                if ($l =~ m{^StorePath: (\S+)$}) {
                    my $p = $1;
                    _fail('failed', "$dir/$f names '$p', not a store path") unless $p =~ $PATH_RE;
                    push @paths, $p;
                    last;
                }
            }
            close $fh;
        }
        closedir $dh;
    } else {
        _fail('usage', 'seeding from another cache needs --paths FILE (its store paths, one per line)');
    }
    _fail('notfound', 'no store paths to seed') unless @paths;
    my %seen;
    my $text = join('', map {"$_\n"} sort grep { !$seen{$_}++ } @paths);
    my $sha = Digest::SHA::sha256_hex($text);
    my $dir = "$self->{resources}/packages/repo";
    File::Path::make_path($dir);
    my $file = "$dir/seed-" . substr($sha, 0, 16) . '.txt';
    open my $out, '>', "$file.tmp" or _fail('failed', "cannot write $file.tmp: $!");
    print {$out} $text;
    close $out or _fail('failed', "cannot write $file.tmp: $!");
    rename "$file.tmp", $file or _fail('failed', "rename $file.tmp: $!");
    return ($sha, scalar keys %seen);
}

sub _profiles ($p) {
    return () unless defined $p && length $p;
    my @p = grep {length} split /[ ,]+/, $p;
    for (@p) { _fail('usage', "profile '$_' is not a plain profile name") unless $_ =~ $PROFILE_RE }
    return ('--profiles', join(' ', @p));
}

sub _inputs (@in) {
    for (@in) { _fail('usage', "input '$_' is not ctrl-exec=<sha256> or ctrl-exec-plugins=<sha256>") unless $_ =~ $INPUT_RE }
    return map { ('--input', $_) } @in;
}

# upstream(): whether repo build may substitute from upstream (repo_upstream).
sub upstream ($self) {
    my $v = $self->_cluster_val('repo_upstream') // 'false';
    return $v eq 'true' ? 1 : 0;
}

# start(mode, %o): start a job on the repository host. mode update|build:
# source, profiles ("a b" or "a,b"), inputs => [NAME=SHA]; build adds
# --upstream when repo_upstream is true. mode seed: from (ips|URL), paths.
# Returns {mode, id, host, args, output}.
sub start ($self, $mode, %o) {
    my $script = $SCRIPT{$mode} // _fail('usage', "unknown verb $mode");
    my @args;
    my $h = $self->host;
    if ($mode eq 'seed') {
        my $from = $o{from} // 'ips';
        _fail('usage', "--from must be ips or http://<host>[:port]/<path>") unless $from eq 'ips' || ($from =~ $URL_RE && $from !~ /\.\./);
        my ($sha, $n) = $self->seed_list(from => $from, paths => $o{paths});
        $self->_log('info', "seed list: $n store paths, packages/repo/seed-" . substr($sha, 0, 16) . '.txt');
        @args = ($from, $sha);
    } else {
        my @p = _profiles($o{profiles});
        my @i = _inputs(@{ $o{inputs} // [] });
        my $src = $self->source(source => $o{source});
        @args = ($src, @p, @i);
        push @args, '--upstream' if $mode eq 'build' && $self->upstream;
    }
    $self->_log('info', "$mode on $h->{name}: $script @args");
    my $r = $self->_call($script, @args);
    my ($id) = ($r->{stdout} // '') =~ /^\Q$STARTED{$mode}\E started id=([0-9]{8}T[0-9]{6}Z) /m;
    _fail('failed', "$script started no job (no '$STARTED{$mode} started' line)") unless defined $id;
    return { mode => $mode, id => $id, host => $h->{name}, args => \@args, output => $r->{stdout} };
}

# wait_job(mode, id, timeout => SECONDS): poll repo-status every poll seconds until
# the job has ended. Returns {result => ok|failed, status => status()}.
sub wait_job ($self, $mode, $id, %o) {
    my $deadline = $self->{now}->() + ($o{timeout} // 10800);
    while (1) {
        my $s = $self->status(log => $o{log} // 0);
        my $f = $s->{fields};
        if (($f->{state} // '') ne 'running' && ($f->{last} // '') =~ /^\Q$mode:$id:\E(ok|failed)\z/) {
            return { result => $1, status => $s };
        }
        _fail('failed', "$mode $id still running after the wait") if $self->{now}->() >= $deadline;
        $self->{sleep}->($self->{poll});
    }
}

1;

__END__

=head1 NAME

HPS::Repo - drive the site repository (repo update, build, seed, status)

=head1 KEYS

Cluster keys: C<repo_host> (the repository host; required),
C<repo_nix_pubkey> (stored by status when empty; a different key on the node
is reported, never overwritten), C<repo_upstream> (true lets repo build
substitute from upstream; default false).

=cut
