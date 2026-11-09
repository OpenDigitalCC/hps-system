#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin qw($RealBin);
use lib 'lib/perl';
use HPS::Registry;
use HPS::Onboard;

my $base = tempdir(CLEANUP => 1);
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->os_set('x86_64:nixos:26.05', 'kernel', 'bzImage');

my $held  = '52:54:00:00:00:01';
my $held2 = '52:54:00:00:00:02';
my $other = '52:54:00:00:00:03';
my $audit = { disks => [ { id => 'ata-FAKE_1', size => 1000 } ], nics => [ { name => 'eth0' } ] };
$reg->host_set($held,  'STATE', 'HELD');
$reg->host_set($held,  'audit', $audit);
$reg->host_set($held,  'audit_at', '2026-11-09 10:00:00 UTC');
$reg->host_set($held2, 'STATE', 'HELD');
$reg->host_set($other, 'STATE', 'INSTALLED');

my $ob = HPS::Onboard->new(registry => $reg);

my @held = $ob->list_held;
is_deeply([ map { $_->{mac} } @held ], [ '525400000001', '525400000002' ], 'list_held lists only HELD hosts');
is($held[0]{audit_at}, '2026-11-09 10:00:00 UTC', 'audit_at listed');
is($held[0]{has_audit}, 1, 'has_audit set');
is($held[1]{has_audit}, 0, 'has_audit unset');

my $s = $ob->show($held);
is($s->{mac}, '525400000001', 'show mac');
is($s->{state}, 'HELD', 'show state');
is_deeply($s->{audit}, $audit, 'audit decoded');
is($s->{audit_at}, '2026-11-09 10:00:00 UTC', 'show audit_at');
ok(!exists $s->{identity}{audit}, 'identity excludes the audit blob');
is($s->{identity}{STATE}, 'HELD', 'identity holds keys');
is($ob->show($held2)->{audit}, undef, 'no audit gives undef');

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return; my $e = $@; return ref $e ? $e : undef }

my %good = (type => 'SCH,TCH', profile => 'CONVERGED', os => 'x86_64:nixos:26.05', pin => 'nixos-26.05.20261109', storage_note => 'tank on by-id pair');

# refusals
my $e = err_of(sub { $ob->show('52:54:00:99:99:99') });
is($e && $e->kind, 'notfound', 'show unknown host');
$e = err_of(sub { $ob->show('zz') });
is($e && $e->kind, 'usage', 'show bad MAC');
$e = err_of(sub { $ob->assign($other, {%good}) });
is($e && $e->kind, 'refused', 'non-HELD host refused');
like($e->message, qr/INSTALLED/, 'refusal names the state');
is($reg->host_get($other, 'STATE'), 'INSTALLED', 'refused host untouched');
$e = err_of(sub { $ob->assign('52:54:00:99:99:99', {%good}) });
is($e && $e->kind, 'notfound', 'assign unknown host');
for my $case (
    [ type => 'XCH' ], [ type => 'SCH,' ], [ type => '' ], [ type => 'SCH,SCH' ], [ type => 'sch' ],
    [ profile => 'converged' ], [ profile => '1ABC' ], [ profile => 'A-B' ], [ profile => '' ],
    [ pin => 'Bad' ], [ pin => 'a' ], [ pin => '-x1' ], [ pin => 'a b' ],
    [ os => 'nixos' ], [ os => 'x86_64:nixos' ],
) {
    my ($k, $v) = @$case;
    $e = err_of(sub { $ob->assign($held, { %good, $k => $v }) });
    is($e && $e->kind, 'usage', "bad $k '$v' is a usage error");
}
for my $k (qw(type profile os pin)) {
    my %a = %good;
    delete $a{$k};
    $e = err_of(sub { $ob->assign($held, \%a) });
    is($e && $e->kind, 'usage', "missing $k is a usage error");
}
$e = err_of(sub { $ob->assign($held, { %good, os => 'x86_64:nixos:99.99' }) });
is($e && $e->kind, 'notfound', 'unknown os refused');
like($e->message, qr/x86_64:nixos:99\.99/, 'names the os');
is($reg->host_get($held, 'STATE'), 'HELD', 'nothing written by any refusal');
ok(!$reg->host_exists($held, 'TYPE'), 'no partial write');

# happy path, no hook
delete $ENV{HPS_ONBOARD_NETCONF_CMD};
my $r = $ob->assign($held, {%good});
is($r->{state}, 'NETWORK_BOOT', 'assign result');
is($reg->host_get($held, $_->[0]), $_->[1], "wrote $_->[0]") for
    [ TYPE => 'SCH,TCH' ], [ HOST_PROFILE => 'CONVERGED' ], [ PROFILE => 'CONVERGED' ],
    [ os_id => 'x86_64:nixos:26.05' ], [ system_pin => 'nixos-26.05.20261109' ],
    [ storage_note => 'tank on by-id pair' ], [ STATE => 'NETWORK_BOOT' ];
like($reg->host_get($held, 'assigned_at'), qr/^\d{4}-\d\d-\d\d /, 'assigned_at stamped');
is_deeply([ map { $_->{mac} } $ob->list_held ], ['525400000002'], 'no longer listed as held');
$e = err_of(sub { $ob->assign($held, {%good}) });
is($e && $e->kind, 'refused', 'second assign refused');
like($e->message, qr/NETWORK_BOOT/, 'names the new state');

# no storage note -> no key
$ob->assign($held2, { %good, storage_note => undef });
ok(!$reg->host_exists($held2, 'storage_note'), 'storage_note omitted when not given');

# hook: runs with the MAC, before STATE is written
my $hook = "$base/hook.sh";
open(my $fh, '>', $hook) or die;
print {$fh} "#!/bin/sh\necho \"\$1\" > '$base/hook.out'\necho CONFIGURED > '$base/hook.state'\nexit \${FAKE_HOOK_RC:-0}\n";
close $fh;
chmod 0755, $hook;
my $h3 = '52:54:00:00:00:04';
$reg->host_set($h3, 'STATE', 'HELD');
$ENV{HPS_ONBOARD_NETCONF_CMD} = $hook;
$ENV{FAKE_HOOK_RC} = 5;
$e = err_of(sub { $ob->assign($h3, {%good}) });
is($e && $e->kind, 'failed', 'hook failure reported');
is($reg->host_get($h3, 'STATE'), 'HELD', 'state stays HELD when the hook fails');
$ENV{FAKE_HOOK_RC} = 0;
$ob->assign($h3, {%good});
is(do { open my $f, '<', "$base/hook.out"; local $/; <$f> }, "525400000004\n", 'hook received the normalised MAC');
is($reg->host_get($h3, 'STATE'), 'NETWORK_BOOT', 'STATE written after the hook');

done_testing;
