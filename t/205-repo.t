#!/usr/bin/env perl
# HPS::Repo and bin/hps-repo (docs/REPOSITORY.md): the repository host from
# repo_host (refused when unset), the node scripts each verb calls and their
# arguments, repo_upstream, the seed list from the IPS cache, the public key
# stored once and a mismatch reported, wait_job polling, and the CLI through a
# stand-in for scripts/hps-run.sh.
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Digest::SHA ();
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Repo;

my $MAC  = '5254000d224e';
my $SHA  = 'a' x 64;
my $CE   = 'c' x 64;
my $PUB  = 'hps-repo-bld-001-1:' . ('B' x 43) . '=';
my $PUB2 = 'hps-repo-bld-001-1:' . ('C' x 43) . '=';
my $P1   = '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-om3-3.0.0-rc60';
my $P2   = '/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-glibc-2.42';

package FakeRun {
    sub new ($c, %o) { return bless { calls => [], out => $o{out} // {}, rc => $o{rc} // {} }, $c }
    sub call ($self, %c) {
        push @{ $self->{calls} }, { %c };
        my $o = $self->{out}{ $c{script} } // '';
        $o = shift @$o if ref $o eq 'ARRAY';
        my $rc = $self->{rc}{ $c{script} } // 0;
        return { rc => $rc, stdout => $o, stderr => $rc ? "+ cmd\n[x] refused: no\n" : '' };
    }
}

package FakePub {
    sub new ($c) { return bless { n => 0 }, $c }
    sub system_tarball ($self) { $self->{n}++; return { sha256 => $SHA } }
}

sub fixture (%o) {
    my $base = tempdir(CLEANUP => 1);
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/res/nix-cache");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set($MAC, 'HOSTNAME', 'bld-001');
    $reg->host_set($MAC, 'TYPE', 'BLD');
    $reg->cluster_set('lab', 'repo_host', $o{host}) if defined $o{host};
    my $run = FakeRun->new(out => $o{out}, rc => $o{rc});
    my $pub = FakePub->new;
    my @log;
    my $now = 1_800_000_000;
    my $repo = HPS::Repo->new(registry => $reg, runner => $run, publisher => $pub, resources => "$base/res",
        logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $now }, sleep => sub { $now += $_[0] }, poll => 30);
    return { base => $base, reg => $reg, run => $run, pub => $pub, repo => $repo, log => \@log };
}

sub err_of ($code) {
    my $ok = eval { $code->(); 1 };
    return $ok ? undef : $@;
}

sub status_out ($line, $pub = $PUB) {
    return ($pub ? "REPO-PUBKEY $pub\n" : "key: none yet\n") . "REPO $line\n";
}

# --- the host ----------------------------------------------------------------------------
{
    my $f = fixture();
    my $e = err_of(sub { $f->{repo}->status });
    is(ref $e && $e->kind, 'refused', 'no repo_host: refused');
    like($e->message, qr/repo_host is not set/, '... and says which key');
    is(scalar @{ $f->{run}{calls} }, 0, '... and no node is called');
    $f = fixture(host => 'nope-009');
    $e = err_of(sub { $f->{repo}->status });
    is($e->kind, 'notfound', 'a repo_host that names no host: not found');
    for my $h ('bld-001', 'bld-001.lab.hps', '52:54:00:0d:22:4e') {
        $f = fixture(host => $h, out => { 'repo-status' => status_out('state=idle key=no last=none', undef) });
        is($f->{repo}->host->{mac}, $MAC, "repo_host $h resolves to the host");
    }
}

# --- status and the public key -------------------------------------------------------------
{
    my $f = fixture(host => 'bld-001', out => { 'repo-status' => status_out('state=idle key=yes paths=3 last=seed:20261112T080000Z:ok newer=1') });
    my $s = $f->{repo}->status(log => 5);
    is_deeply($f->{run}{calls}[0]{args}, [ '--log', 5 ], 'status: repo-status --log N');
    is($f->{run}{calls}[0]{mac}, $MAC, '... on the repository host');
    is($s->{fields}{paths}, 3, 'the REPO line is parsed');
    is($s->{fields}{last}, 'seed:20261112T080000Z:ok', '... the last job');
    is($s->{key_state}, 'stored', 'an empty repo_nix_pubkey takes the node key');
    is($f->{reg}->cluster_get('lab', 'repo_nix_pubkey'), $PUB, '... stored as the cluster key');
    $s = $f->{repo}->status;
    is($s->{key_state}, 'same', 'the same key again: same');
    $f->{run}{out}{'repo-status'} = status_out('state=idle key=yes', $PUB2);
    $s = $f->{repo}->status;
    is($s->{key_state}, 'mismatch', 'another key on the node: mismatch');
    is($f->{reg}->cluster_get('lab', 'repo_nix_pubkey'), $PUB, '... the stored key is not changed');
    ok(scalar(grep {/^err .*is not repo_nix_pubkey/} @{ $f->{log} }), '... and it is logged');
    $f->{run}{out}{'repo-status'} = status_out('state=idle', 'bad:key');
    is(err_of(sub { $f->{repo}->status })->kind, 'failed', 'a key of another shape is a failure');
    $f->{run}{out}{'repo-status'} = "nothing\n";
    is(err_of(sub { $f->{repo}->status })->kind, 'failed', 'no REPO line is a failure');
    is(err_of(sub { $f->{repo}->status(log => 2001) })->kind, 'usage', '--log over 2000 is usage');
}

# --- build and update ------------------------------------------------------------------------
{
    my $f = fixture(host => 'bld-001', out => { 'builder-build' => "+ x\nBUILDER-BUILD started id=20261112T090000Z source=aaaa upstream=no unit=u log=l\n",
        'repo-update' => "REPO-UPDATE started id=20261112T091000Z source=aaaa unit=u log=l\n" });
    my $j = $f->{repo}->start('build', profiles => 'node-base,node-builder', inputs => ["ctrl-exec=$CE"]);
    is($j->{id}, '20261112T090000Z', 'build: the job id from the started line');
    my $c = $f->{run}{calls}[-1];
    is($c->{script}, 'builder-build', '... through builder-build');
    is_deeply($c->{args}, [ $SHA, '--profiles', 'node-base node-builder', '--input', "ctrl-exec=$CE" ],
        '... the source this IPS published, profiles space-joined, the input; no --upstream by default');
    is($f->{pub}{n}, 1, '... the source is published (source-only)');
    $f->{reg}->cluster_set('lab', 'repo_upstream', 'true');
    $f->{repo}->start('build', source => 'b' x 64);
    is_deeply($f->{run}{calls}[-1]{args}, [ 'b' x 64, '--upstream' ], 'repo_upstream true: --upstream; --source is used as given');
    is($f->{pub}{n}, 1, '... and nothing is published');
    $j = $f->{repo}->start('update');
    is($f->{run}{calls}[-1]{script}, 'repo-update', 'update: through repo-update');
    is_deeply($f->{run}{calls}[-1]{args}, [$SHA], '... never --upstream');
    is($j->{id}, '20261112T091000Z', '... its job id');
    is(err_of(sub { $f->{repo}->start('build', profiles => 'node-base ../x') })->kind, 'usage', 'a bad profile is usage');
    is(err_of(sub { $f->{repo}->start('build', inputs => ['nixpkgs=' . $SHA]) })->kind, 'usage', 'a bad input is usage');
    is(err_of(sub { $f->{repo}->start('build', source => 'xyz') })->kind, 'usage', 'a bad source is usage');
    is(err_of(sub { $f->{repo}->start('wipe') })->kind, 'usage', 'an unknown verb is usage');
    $f->{run}{out}{'builder-build'} = "nothing started\n";
    is(err_of(sub { $f->{repo}->start('build') })->kind, 'failed', 'no started line: failed');
    $f->{run}{rc}{'builder-build'} = 3;
    my $e = err_of(sub { $f->{repo}->start('build') });
    is($e->kind, 'refused', 'a node refusal is refused');
    like($e->message, qr/exited 3: \[x\] refused: no$/, '... with the node\'s last line');
}

# --- seed ---------------------------------------------------------------------------------------
{
    my $f = fixture(host => 'bld-001', out => { 'repo-seed' => "REPO-SEED started id=20261112T080000Z from=http://x/nix-cache paths=2 unit=u log=l\n" });
    my $dir = "$f->{base}/res/nix-cache";
    for my $p ($P1, $P2) {
        (my $h = $p) =~ s{^/nix/store/([^-]+)-.*}{$1};
        open my $fh, '>', "$dir/$h.narinfo" or die;
        print {$fh} "StorePath: $p\nURL: nar/x\n";
        close $fh;
    }
    open my $fh, '>', "$dir/nix-cache-info" or die;
    print {$fh} "StoreDir: /nix/store\n";
    close $fh;
    my $j = $f->{repo}->start('seed');
    my $text = "$P1\n$P2\n";
    my $sha = Digest::SHA::sha256_hex($text);
    is_deeply($f->{run}{calls}[-1]{args}, [ 'ips', $sha ], 'seed: repo-seed ips <sha256 of the list>');
    my $list = "$f->{base}/res/packages/repo/seed-" . substr($sha, 0, 16) . '.txt';
    open $fh, '<', $list or die "no $list";
    is(do { local $/; <$fh> }, $text, '... the list holds every StorePath of the IPS cache, sorted');
    close $fh;
    is($j->{id}, '20261112T080000Z', '... its job id');
    is(err_of(sub { $f->{repo}->start('seed', from => 'http://10.0.0.9:8091/nix-cache') })->kind, 'usage',
        'another cache without --paths is usage');
    open $fh, '>', "$f->{base}/paths.txt" or die;
    print {$fh} "$P2\n";
    close $fh;
    $f->{repo}->start('seed', from => 'http://10.0.0.9:8091/nix-cache', paths => "$f->{base}/paths.txt");
    is($f->{run}{calls}[-1]{args}[0], 'http://10.0.0.9:8091/nix-cache', '... with --paths it is passed on');
    open $fh, '>', "$f->{base}/bad.txt" or die;
    print {$fh} "/etc/passwd\n";
    close $fh;
    is(err_of(sub { $f->{repo}->start('seed', from => 'http://x/c', paths => "$f->{base}/bad.txt") })->kind, 'usage',
        'a list line that is no store path is usage');
    is(err_of(sub { $f->{repo}->start('seed', from => 'https://x/c') })->kind, 'usage', 'an https source is usage');
    is(err_of(sub { $f->{repo}->start('seed', from => 'http://x/../c') })->kind, 'usage', 'a source with .. is usage');
}

# --- wait_job ------------------------------------------------------------------------------------
{
    my $f = fixture(host => 'bld-001', out => { 'repo-status' => [
        status_out('state=running last=build:20261112T090000Z:running'),
        status_out('state=idle last=seed:20261112T080000Z:ok'),
        status_out('state=idle last=build:20261112T090000Z:failed') ] });
    my $w = $f->{repo}->wait_job('build', '20261112T090000Z', timeout => 3600);
    is($w->{result}, 'failed', 'wait_job: polls until the job has ended and returns its result');
    is(scalar @{ $f->{run}{calls} }, 3, '... one status call per poll');
    $f->{run}{out}{'repo-status'} = status_out('state=running last=build:20261112T090000Z:running');
    is(err_of(sub { $f->{repo}->wait_job('build', '20261112T090000Z', timeout => 60) })->kind, 'failed',
        'a job still running after the wait: failed');
}

# --- the CLI through a stand-in hps-run.sh ----------------------------------------------------------
{
    my $f = fixture(host => 'bld-001');
    my $shim = "$f->{base}/hps-run";
    open my $sh, '>', $shim or die;
    print {$sh} <<'SHIM';
#!/usr/bin/env bash
echo "$*" >> "$SHIM_DIR/args"
while [[ "${1:-}" == --* ]]; do shift; done
out=$(cat "$SHIM_DIR/out.$2" 2> /dev/null || echo "no output")
jq -n --argjson e "${FAKE_NODE_EXIT:-0}" --arg o "$out
" '{ok:1,results:[{host:"h",exit:$e,stdout:$o,stderr:""}]}'
SHIM
    close $sh;
    chmod 0755, $shim;
    my $write = sub ($name, $text) { open my $o, '>', "$f->{base}/out.$name" or die; print {$o} $text; close $o };
    local $ENV{SHIM_DIR} = $f->{base};
    local $ENV{HPS_RUN_CMD} = $shim;
    local $ENV{HPS_CONFIG_BASE} = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES} = "$f->{base}/res";
    local $ENV{HPS_REPO_NO_SYSLOG} = 1;
    my $cli = "$Bin/../bin/hps-repo";
    $write->('repo-status', status_out('state=idle key=yes paths=0 last=none newer=0'));
    my $out = `$cli status --log 0 2>&1`;
    is($? >> 8, 0, 'hps-repo status: exit 0');
    like($out, qr/^REPO state=idle/m, '... prints the node status');
    like($out, qr/^repo_nix_pubkey: \Q$PUB\E \(stored\)$/m, '... and the key it stored');
    $write->('repo-status', status_out('state=idle key=yes', $PUB2));
    $out = `$cli status 2>&1`;
    is($? >> 8, 3, 'a key mismatch: exit 3');
    like($out, qr/clear repo_nix_pubkey/, '... saying what to do');
    $write->('builder-build', "BUILDER-BUILD started id=20261112T090000Z source=aaaa upstream=no unit=u log=l");
    $out = `$cli build --source $SHA --profiles node-base 2>&1`;
    is($? >> 8, 0, 'hps-repo build: exit 0');
    like($out, qr/^REPO-STARTED mode=build id=20261112T090000Z host=bld-001$/m, '... the started line');
    $write->('repo-status', status_out('state=idle key=yes last=build:20261112T090000Z:ok', $PUB));
    $out = `$cli build --source $SHA --wait 60 2>&1`;
    like($out, qr/^REPO-DONE mode=build id=20261112T090000Z result=ok$/m, '--wait: polls to the end');
    `$cli build --from ips 2>&1`;
    is($? >> 8, 2, 'build --from: usage');
    `$cli frobnicate 2>&1`;
    is($? >> 8, 2, 'an unknown verb: usage');
    $f->{reg}->cluster_unset('lab', 'repo_host');
    $out = `$cli status 2>&1`;
    is($? >> 8, 3, 'no repo_host: exit 3');
}

done_testing;
