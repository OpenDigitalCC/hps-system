#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Onboard;

my $base = tempdir(CLEANUP => 1);
my $res  = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');

sub make_pin {
    my ($pin, @profiles) = @_;
    for my $p (@profiles) {
        make_path("$res/nixos/$pin/$p");
        open my $fh, '>', "$res/nixos/$pin/$p/boot.json" or die $!;
        print {$fh} '{"init":"/x"}';
        close $fh;
        for my $f (qw(bzImage initrd)) {   # present, no hashes recorded: unverified, not failed
            open my $af, '>', "$res/nixos/$pin/$p/$f" or die $!;
            print {$af} "x\n";
            close $af;
        }
    }
}
make_pin('pin-a', qw(audit node-base));
make_pin('pin-b', qw(audit node-base));
make_pin('pin-c', qw(audit node-base));
make_path("$res/nixos/pin-nobootjson/audit");
make_path("$res/nixos/pin-empty");
make_pin('pin-badjson', 'audit');
open my $bj, '>', "$res/nixos/pin-badjson/audit/boot.json" or die $!;
print {$bj} '{nope';
close $bj;
open my $lf, '>', "$res/nixos/latest" or die $!;
print {$lf} "pin-c\n";
close $lf;

my $held = '52:54:00:00:00:01';
my $host = '52:54:00:00:00:02';
my $bare = '52:54:00:00:00:03';
$reg->host_set($held, 'STATE', 'HELD');
$reg->host_set($host, 'STATE', 'NETWORK_BOOT');
$reg->host_set($host, 'system_pin', 'pin-a');
$reg->host_set($bare, 'STATE', 'INSTALLED');

my $ob = HPS::Onboard->new(registry => $reg, resources => $res);

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return; my $e = $@; return ref $e ? $e : undef }

# refusals leave the host untouched
my $e = err_of(sub { $ob->repin($held, { pin => 'pin-b' }) });
is( $e && $e->kind, 'refused', 'HELD host refused' );
like( $e->message, qr/HELD/, 'refusal names HELD' );
ok( !$reg->host_exists($held, 'system_pin'), 'HELD host gets no pin' );
$e = err_of(sub { $ob->repin('52:54:00:99:99:99', { pin => 'pin-b' }) });
is( $e && $e->kind, 'notfound', 'unknown host' );
$e = err_of(sub { $ob->repin('zz', { pin => 'pin-b' }) });
is( $e && $e->kind, 'usage', 'bad MAC' );
$e = err_of(sub { $ob->repin($host, { pin => 'pin-a' }) });
is( $e && $e->kind, 'refused', 'same pin refused' );
$e = err_of(sub { $ob->repin($host, {}) });
is( $e && $e->kind, 'usage', 'neither pin nor to_latest' );
$e = err_of(sub { $ob->repin($host, { pin => 'pin-b', to_latest => 1 }) });
is( $e && $e->kind, 'usage', 'both pin and to_latest' );
$e = err_of(sub { $ob->repin($host, { pin => 'Bad Pin' }) });
is( $e && $e->kind, 'usage', 'malformed pin' );
$e = err_of(sub { $ob->repin($host, { pin => 'pin-missing' }) });
is( $e && $e->kind, 'notfound', 'missing pin directory' );
like( $e->message, qr/pin-missing/, 'names the pin' );
for my $bad (qw(pin-nobootjson pin-empty pin-badjson)) {
    $e = err_of(sub { $ob->repin($host, { pin => $bad }) });
    is( $e && $e->kind, 'notfound', "$bad is not usable" );
}
like( err_of(sub { $ob->repin($host, { pin => 'pin-nobootjson' }) })->message, qr/audit has no boot\.json/, 'names the profile' );
is( $reg->host_get($host, 'system_pin'), 'pin-a', 'pin unchanged after refusals' );
ok( !$reg->host_exists($host, 'repinned_at'), 'no timestamp after refusals' );
ok( !$reg->host_exists($host, 'system_pin_previous'), 'no previous after refusals' );

# happy path
my $r = $ob->repin($host, { pin => 'pin-b' });
is_deeply( $r, { mac => '525400000002', from => 'pin-a', to => 'pin-b' }, 'result' );
is( $reg->host_get($host, 'system_pin'), 'pin-b', 'pin set' );
is( $reg->host_get($host, 'system_pin_previous'), 'pin-a', 'previous recorded' );
like( $reg->host_get($host, 'repinned_at'), qr/^\d{4}-\d\d-\d\d /, 'repinned_at recorded' );
is( $reg->host_get($host, 'STATE'), 'NETWORK_BOOT', 'state untouched' );

# rollback is the same change
$ob->repin($host, { pin => 'pin-a' });
is( $reg->host_get($host, 'system_pin'), 'pin-a', 'rolled back' );
is( $reg->host_get($host, 'system_pin_previous'), 'pin-b', 'previous follows' );

# --to-latest
$r = $ob->repin($host, { to_latest => 1 });
is( $r->{to}, 'pin-c', 'latest read from the file' );
is( $reg->host_get($host, 'system_pin'), 'pin-c', 'pin is latest' );

# a host with no pin yet: no previous
$r = $ob->repin($bare, { pin => 'pin-a' });
is( $r->{from}, undef, 'no old pin' );
ok( !$reg->host_exists($bare, 'system_pin_previous'), 'no previous recorded' );
is( $reg->host_get($bare, 'system_pin'), 'pin-a', 'pin set on an unpinned host' );

# latest missing or pointing nowhere
unlink "$res/nixos/latest";
$e = err_of(sub { $ob->repin($host, { to_latest => 1 }) });
is( $e && $e->kind, 'notfound', 'no latest file' );
open $lf, '>', "$res/nixos/latest" or die $!;
print {$lf} "pin-gone\n";
close $lf;
$e = err_of(sub { $ob->repin($host, { to_latest => 1 }) });
is( $e && $e->kind, 'notfound', 'latest names a missing pin' );
is( $reg->host_get($host, 'system_pin'), 'pin-c', 'pin unchanged' );

# CLI
{
    local $ENV{HPS_CONFIG_BASE}     = $base;
    local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
    local $ENV{HPS_RESOURCES}       = $res;
    my $out = qx($^X -I$Bin/../lib/perl $Bin/../bin/hps-onboard repin $host --pin pin-b 2>&1);
    is( $? >> 8, 0, 'CLI repin exits 0' );
    like( $out, qr/Repinned 525400000002: pin-c -> pin-b/, 'CLI says what changed' );
    $out = qx($^X -I$Bin/../lib/perl $Bin/../bin/hps-onboard repin $held --pin pin-b 2>&1);
    is( $? >> 8, 3, 'CLI HELD host exits 3' );
    $out = qx($^X -I$Bin/../lib/perl $Bin/../bin/hps-onboard repin $host --pin pin-zzz 2>&1);
    is( $? >> 8, 4, 'CLI missing pin exits 4' );
    $out = qx($^X -I$Bin/../lib/perl $Bin/../bin/hps-onboard repin $host 2>&1);
    is( $? >> 8, 2, 'CLI without --pin exits 2' );
}

done_testing;
