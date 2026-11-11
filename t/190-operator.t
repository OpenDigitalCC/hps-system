#!/usr/bin/env perl
# HPS::Operator and bin/hps-operator: operator credentials for the IPS's own
# ctrl-exec API, against a temp registry and keysafe.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find;
use Digest::SHA qw(sha256_hex);
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Keysafe;
use HPS::Operator;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts", "$base/conf");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
my $ks = HPS::Keysafe->new(registry => $reg);
my $export = "$base/conf/hps-operators";
my $now = 1794321826;
my $op = HPS::Operator->new(keysafe => $ks, export_path => $export, now => sub { $now });

sub mode { return sprintf '%04o', (stat $_[0])[2] & 07777 }
sub err_of { my $c = shift; eval { $c->(); 1 } and return; return $@ }
sub slurp { open(my $fh, '<', $_[0]) or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $r = $op->issue('alice');
like($r->{token}, qr/\Ahpsop_[0-9a-f]{64}\z/, 'the token is hpsop_ and 64 hex digits (256 random bits)');
is($r->{name}, 'alice', 'issued to alice');
is($r->{issued}, $now, 'with the issue time');

my $rec = decode_json($ks->get_secret('operator-alice'));
is($rec->{sha256}, sha256_hex($r->{token}), 'the keysafe keeps the SHA-256 of the token');
is($rec->{issued}, $now, 'and the issue time');

my @hits;
find(sub { push @hits, $File::Find::name if -f $_ && index(slurp($_), $r->{token}) >= 0 }, $base);
is_deeply(\@hits, [], 'the token itself is stored nowhere');

like(slurp($export), qr/^alice [0-9a-f]{64}$/m, 'the hook file lists alice with the digest');
is(mode($export), '0640', 'the hook file is 0640');
unlike(slurp($export), qr/hpsop_/, 'the hook file holds no token');

my $e = err_of(sub { $op->issue('alice') });
is(ref $e && $e->kind, 'refused', 'a second credential for the same name is refused');
for my $bad ('', 'Alice', '1abc', 'a b', 'a/b', 'x' x 33, 'a;b') {
    my $err = err_of(sub { $op->issue($bad) });
    is(ref $err && $err->kind, 'usage', "name '$bad' refused");
}

my $b = $op->issue('bob');
is_deeply($op->list, [ { name => 'alice', issued => $now }, { name => 'bob', issued => $now } ], 'list: names and issue times, sorted');
is($op->verify($r->{token}), 'alice', 'verify: the token is alice\'s');
is($op->verify($b->{token}), 'bob', 'verify: and bob\'s');
ok(!defined $op->verify('hpsop_' . ('0' x 64)), 'verify: an unknown token is nobody');
ok(!defined $op->verify('nonsense'), 'verify: a malformed token is nobody');
isnt($r->{token}, $b->{token}, 'tokens differ');

ok($op->revoke('alice'), 'revoke');
ok(!defined $op->verify($r->{token}), 'a revoked token is nobody');
unlike(slurp($export), qr/^alice /m, 'and is gone from the hook file');
like(slurp($export), qr/^bob /m, 'the others stay');
$e = err_of(sub { $op->revoke('alice') });
is(ref $e && $e->kind, 'notfound', 'revoking a name without a credential is notfound');

unlink $export;
is($op->export, 1, 'export rebuilds the hook file from the keysafe');
like(slurp($export), qr/^bob /m, 'with bob');

$e = err_of(sub { HPS::Operator->new(keysafe => $ks, export_path => "$base/nodir/x")->export });
is(ref $e && $e->kind, 'failed', 'export without the dispatcher directory fails');

# --- bin/hps-operator end to end -----------------------------------------
local $ENV{HPS_CONFIG_BASE}     = $base;
local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
local $ENV{CTRL_EXEC_DISPATCHER_CONF_DIR} = "$base/conf";
$reg->cluster_set('lab', 'network_dns_domain', 'lab.hps');

sub run_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { quotemeta } $^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-operator", @args;
    my $out = qx($cmd 2>$base/stderr.txt);
    return ($? >> 8, $out, slurp("$base/stderr.txt"));
}

my ($rc, $out, $err) = run_cli('issue', 'carol');
is($rc, 0, 'cli issue exits 0');
like($out, qr/^name = carol$/m, 'the credential names carol');
like($out, qr/^agent = ips\.lab\.hps$/m, 'and the IPS agent ips.<domain>');
like($out, qr/^url = $/m, 'no url while operator_api_listen is unset');
like($err, qr/operator_api_listen is unset/, 'and says so');
like($err, qr/no API certificate yet/, 'no certificate yet, and says so');
my ($tok) = $out =~ /^token = (\S+)$/m;
is($op->verify($tok), 'carol', 'the printed token is carol\'s');

$reg->cluster_set('lab', 'operator_api_listen', '10.99.1.1');
open(my $fh, '>', "$base/conf/hps-api-tls.crt") or die $!;
print {$fh} "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n";
close $fh;
($rc, $out, $err) = run_cli('issue', 'dave');
like($out, qr{^url = https://10\.99\.1\.1:7445$}m, 'the url is the operator API');
like($out, qr/-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n\z/, 'the API certificate ends the credential');

($rc, $out) = run_cli('issue', 'dave');
is($rc, 3, 'issuing again for dave exits 3');
($rc, $out) = run_cli('list');
is($rc, 0, 'list exits 0');
like($out, qr/^carol\s+issued \d{4}-/m, 'list shows carol');
unlike($out, qr/hpsop_|[0-9a-f]{64}/, 'list shows no token or digest');
($rc, $out) = run_cli('list', '--json');
is_deeply([ map { $_->{name} } @{ decode_json($out) } ], [qw(bob carol dave)], 'list --json');
($rc, $out) = run_cli('revoke', 'carol');
is($rc, 0, 'revoke exits 0');
ok(!defined $op->verify($tok), 'carol\'s token no longer verifies');
($rc) = run_cli('revoke', 'carol');
is($rc, 4, 'revoking again exits 4');
($rc, $out) = run_cli('ca');
is($rc, 0, 'ca exits 0');
like($out, qr/BEGIN CERTIFICATE/, 'ca prints the certificate');
($rc) = run_cli('issue');
is($rc, 2, 'issue without a name is a usage error');
($rc) = run_cli('bogus');
is($rc, 2, 'an unknown command is a usage error');

done_testing;
