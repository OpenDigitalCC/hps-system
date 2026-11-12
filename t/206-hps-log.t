#!/usr/bin/env perl
# hps-log (docs/LOGGING.md): the newest lines of a host from every address the
# registry knows for it, of the IPS itself, the filters, the limits, and that a
# line naming a secret never comes out. A temp log tree and registry.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Registry;
use HPS::Log;

my $base = tempdir(CLEANUP => 1);
my $logd = "$base/log";
my $reg  = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
$reg->system_set('ACTIVE_CLUSTER', 'lab');
$reg->cluster_set('lab', 'network_dns_domain', 'hps.test');
my $mac = 'aabbccddee01';
$reg->host_set($mac, 'HOSTNAME', 'cnh-001');
$reg->host_set($mac, 'IP', '10.9.0.12');
$reg->host_set($mac, 'audit', { net => { addr => [
    { ifname => 'lo',  addr_info => [ { family => 'inet', local => '127.0.0.1' } ] },
    { ifname => 'en0', addr_info => [ { family => 'inet', local => '10.9.0.136' }, { family => 'inet6', local => 'fe80::1' } ] },
] } });
$reg->host_set('aabbccddee02', 'HOSTNAME', 'tch-001');
$reg->host_set('aabbccddee02', 'IP', '10.9.0.11');

sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }
sub sl { my ($t, $ip, $h, $tag, $msg) = @_; return "Nov 12 $t $ip [$h] $tag: $msg" }

make_path("$logd/10.9.0.12", "$logd/10.9.0.136", "$logd/10.9.0.11", "$logd/ips", "$logd/ips/hps");
spew("$logd/10.9.0.136/2026-11-10.log",
    'Nov 10 09:00:00 10.9.0.136 [nixos] hps-audit: audit sent');
spew("$logd/10.9.0.12/2026-11-11.log",
    'Nov 11 23:59:00 10.9.0.12 [cnh-001] podman: yesterday');
spew("$logd/10.9.0.12/2026-11-12.log",
    sl('08:00:00', '10.9.0.12', 'cnh-001', 'kernel', 'booted'),
    sl('08:01:00', '10.9.0.12', 'cnh-001', 'podman[812]', 'write /var/lib/containers/x: No space left on device'),
    sl('08:02:00', '10.9.0.12', 'cnh-001', 'hps-ips', 'WARN exited: opensvc (exit status 1)'),
    sl('08:03:00', '10.9.0.12', 'cnh-001', 'osvc', 'set cluster secret abc'),
    sl('08:04:00', '10.9.0.12', 'cnh-001', 'sshd', 'api_key=hunter2 accepted'),
    sl('08:05:00', '10.9.0.12', 'cnh-001', 'x', 'unlock with ' . ('a1' x 32)),
    sl('08:06:00', '10.9.0.12', 'cnh-001', 'x', '-----BEGIN OPENSSH PRIVATE KEY-----'),
    sl('08:07:00', '10.9.0.12', 'cnh-001', 'x', 'operator hpsop_AbC123 used'),
    sl('08:08:00', '10.9.0.12', 'cnh-001', 'kernel', 'monkey keys are fine'),
    sl('08:09:00', '10.9.0.12', 'cnh-001', 'hps', 'Init sequence complete: 9 succeeded, 0 failed'),
    'not a syslog line at all',
    sl('08:10:00', '10.9.0.12', 'cnh-001', 'ctrl-exec-agent[9]', "ACTION=run EXIT=0 #033[0;32mOK#033[0m"),
);
spew("$logd/10.9.0.11/2026-11-12.log", sl('08:00:30', '10.9.0.11', 'tch-001', 'kernel', 'other host'));
spew("$logd/ips/2026-11-12.log",
    sl('08:00:10', '127.0.0.1', 'ips', 'hps-auth-hook', 'ALLOW action=run script=nagios-check'),
    sl('08:00:20', '127.0.0.1', 'ips', 'hps-auth-hook', 'ALLOW action=run script=osvc-secret-set'),
);
make_path("$logd/ips/dnsmasq");
spew("$logd/ips/hps/2026-11-12.log",
    sl('08:00:15', '127.0.0.1', 'ips', 'hps', 'hps-onboard: host cnh-001 approved'),
    sl('08:00:16', '127.0.0.1', 'ips', 'hps', 'hps-monitor: host=sch-001.hps.test check=mem state=OK'),
    sl('08:00:17', '127.0.0.1', 'ips', 'hps', 'hps-monitor: tick hosts=3 duration=6.5'),
);
spew("$logd/ips/dnsmasq/2026-11-12.log", sl('08:00:18', '127.0.0.1', 'ips', 'dnsmasq', 'another service, not read'));
spew("$logd/events.log",
    '2026-11-12T08:00:12.5+00:00 job ips supervisord: job 7 done',
    '2026-11-12T08:00:13+00:00 metric ips hps: hps-monitor: host=x check=mem state=OK',
    '2026-11-12T09:00:14+01:00 error ips hps-jobs: storage failed on sch-001',
    '2026-11-12T08:00:15+00:00 node ips hps: hps-onboard: host cnh-001 approved',
    '2026-11-12T08:00:16+00:00 error cnh-001 rsyslogd: a node event',
);

my $now = timegm(0, 11, 8, 12, 10, 2026);    # 2026-11-12 08:11:00 UTC
my $log = HPS::Log->new(log_dir => $logd, registry => $reg, now => $now);

#--- addresses -------------------------------------------------------------------------
is_deeply([ $log->host_addresses($mac) ], [ '10.9.0.12', '10.9.0.136' ],
    'addresses: the current IP, then the audit\'s IPv4 addresses (no loopback, no IPv6)');

#--- a host -----------------------------------------------------------------------------
my $r = $log->host_log('cnh-001');
is($r->{target}, 'host', 'host target');
is($r->{mac}, $mac, 'the host is found by name');
is_deeply($r->{sources}, [ '10.9.0.12', '10.9.0.136' ], 'both address directories are read');
my @t = map { $_->{time} } @{ $r->{lines} };
is($t[0], '2026-11-10T09:00:00Z', 'oldest first: the audit-address line from two days ago');
is($t[-1], '2026-11-12T08:10:00Z', 'newest last');
is($r->{count}, 13, 'every parsed line of both addresses (the unparsable one skipped)');
is_deeply([ sort @t ], \@t, 'merged in time order');
ok(!(grep { $_->{message} =~ /other host/ } @{ $r->{lines} }), "another host's address is not read");

my %by = map { $_->{time} => $_ } @{ $r->{lines} };
is($by{'2026-11-12T08:01:00Z'}{level}, 'error', 'No space left is an error');
is($by{'2026-11-12T08:01:00Z'}{tag}, 'podman', 'the tag loses its [pid]');
is($by{'2026-11-12T08:02:00Z'}{level}, 'warning', 'WARN is a warning');
is($by{'2026-11-12T08:09:00Z'}{level}, 'info', '"0 failed" is a count, not an error');
is($by{'2026-11-12T08:10:00Z'}{message}, 'ACTION=run EXIT=0 OK', 'escaped terminal colours are removed');
is($by{'2026-11-12T08:08:00Z'}{message}, 'monkey keys are fine', '"keys" and "monkey" are not secret names');

for my $tm (qw(08:03:00 08:04:00 08:05:00 08:06:00 08:07:00)) {
    my $e = $by{"2026-11-12T${tm}Z"};
    is($e->{message}, '[redacted]', "$tm: a secret line is redacted");
    ok($e->{redacted}, "$tm: marked redacted");
}
is($r->{redacted}, 5, 'the count of redacted lines');
my $text = JSON::PP->new->canonical->encode($r);
unlike($text, qr/hunter2|BEGIN OPENSSH|hpsop_AbC|secret abc|(?:a1){32}/, 'no secret text anywhere in the result');

#--- by MAC, --lines, --since, --grep ------------------------------------------------------
is($log->host_log('AA:BB:CC:DD:EE:01')->{mac}, $mac, 'found by MAC in any form');
is($log->host_log('cnh-001.hps.test')->{mac}, $mac, 'found by FQDN');
$r = $log->host_log('cnh-001', lines => 3);
is_deeply([ map { $_->{time} } @{ $r->{lines} } ], [ map { "2026-11-12T08:${_}Z" } qw(08:00 09:00 10:00) ], '--lines 3: the newest three, newest last');
$r = $log->host_log('cnh-001', since => 5);
is($r->{lines}[0]{time}, '2026-11-12T08:06:00Z', '--since 5: from 08:06 on');
is($r->{count}, 5, '--since 5: five lines');
$r = $log->host_log('cnh-001', grep => 'SPACE');
is($r->{count}, 1, '--grep is case-insensitive');
$r = $log->host_log('cnh-001', grep => 'hunter2');
is($r->{count}, 0, '--grep matches after redaction: a secret cannot be probed');
$r = $log->host_log('cnh-001', grep => 'redacted');
is($r->{count}, 5, '--grep redacted finds the withheld lines');

#--- the IPS ------------------------------------------------------------------------------
$r = $log->ips_log;
is($r->{target}, 'ips', 'ips target');
my @m = map { "$_->{source}:$_->{message}" } @{ $r->{lines} };
is_deeply(\@m, [
    'ips:ALLOW action=run script=nagios-check',
    'events:job 7 done',
    'events:storage failed on sch-001',
    'ips/hps:hps-onboard: host cnh-001 approved',
    'ips:[redacted]',
], 'ips: ips/<date>.log, ips/hps and the events of host ips in time order (+01:00 converted); '
 . 'monitor results, metric events, hps-tagged event copies, node events and other services left out');
is_deeply($r->{sources}, [ 'ips', 'ips/hps', 'events' ], 'ips: the three sources');
is($r->{lines}[2]{level}, 'error', 'an error event is an error');

#--- refusals ------------------------------------------------------------------------------
sub refused {
    my ($code, $kind, $label) = @_;
    my $ok = eval { $code->(); 1 };
    my $e = $@;
    ok(!$ok && ref $e && $e->kind eq $kind, $label) or diag(ref $e ? $e->message : $e);
}
refused(sub { $log->host_log('nosuch') }, 'notfound', 'an unknown host name: notfound');
refused(sub { $log->host_log('aabbccddeeff') }, 'notfound', 'an unknown MAC: notfound');
refused(sub { $log->host_log('cnh-001', lines => 501) }, 'usage', '--lines 501: usage');
refused(sub { $log->host_log('cnh-001', lines => 0) }, 'usage', '--lines 0: usage');
refused(sub { $log->host_log('cnh-001', since => 'x') }, 'usage', '--since x: usage');
refused(sub { $log->host_log('cnh-001', grep => 'a b') }, 'usage', '--grep with a space: usage');
refused(sub { $log->host_log('cnh-001', grep => '../x') }, 'usage', '--grep with a slash: usage');

#--- an address that is not IPv4 never becomes a path ----------------------------------------
$reg->host_set('aabbccddee03', 'HOSTNAME', 'odd-001');
$reg->host_set('aabbccddee03', 'IP', '../ips');
is_deeply([ $log->host_addresses('aabbccddee03') ], [], 'an IP value that is not IPv4 is ignored');
is($log->host_log('odd-001')->{count}, 0, '... and nothing is read for it');

#--- the CLI --------------------------------------------------------------------------------
$ENV{HPS_LOG} = $logd;
$ENV{HPS_CONFIG_BASE} = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
my $bin = "$Bin/../bin/hps-log";
my $out = `$^X $bin host cnh-001 --lines 2 --json`;
is($? >> 8, 0, 'cli: host --json exits 0');
my $d = decode_json($out);
is($d->{count}, 2, 'cli: --lines 2');
is($d->{lines}[-1]{time}, '2026-11-12T08:10:00Z', 'cli: newest last');
$out = `$^X $bin ips --lines 1`;
like($out, qr/\A\S+Z (?:info|warning|error) +ips \S+: /, 'cli: plain text line: time level host tag: message');
system("$^X $bin host nosuch 2>/dev/null");
is($? >> 8, 4, 'cli: no such host exits 4');
system("$^X $bin host cnh-001 --lines 9999 2>/dev/null");
is($? >> 8, 2, 'cli: --lines over 500 exits 2');
system("$^X $bin purge 2>/dev/null");
is($? >> 8, 2, 'cli: an unknown verb exits 2');
system("$^X $bin --help 2>/dev/null");
is($? >> 8, 2, 'cli: --help prints usage');

done_testing;
