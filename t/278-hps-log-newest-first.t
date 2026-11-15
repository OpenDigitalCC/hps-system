#!/usr/bin/env perl
# hps-log without --since: `--lines N` is the NEWEST N matching lines, found newest file
# first and from the end of each file backwards, in a byte budget of its own per source
# (docs/LOGGING.md "Reading the logs"). A day file much larger than the budget must not hide
# the newest lines, nor the other sources of the same call; when the budget is hit the read
# says how far back it got. hps-browser calls `hps-log ips --lines 200 --grep DHCPACK`.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Time::Local qw(timegm);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl";
use HPS::Log;

my $base = tempdir(CLEANUP => 1);
my $logd = "$base/log";
my $now = timegm(0, 0, 10, 12, 10, 2026);    # 2026-11-12 10:00:00 UTC
$ENV{HPS_CONFIG_BASE} = $base;
$ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";

# syslog_line($sec_of_day, $ip, $host, $text): a line of a 2026-11-12 day file
sub syslog_line {
    my ($sec, $ip, $host, $text) = @_;
    return sprintf('Nov 12 %02d:%02d:%02d %s [%s] %s', int($sec / 3600), int($sec / 60) % 60, $sec % 60, $ip, $host, $text);
}
sub spew { my ($f, @l) = @_; open(my $fh, '>', $f) or die "$f: $!"; print {$fh} map { "$_\n" } @l; close $fh }

# a deterministic filler: lines of about 100 bytes, none containing the word searched for
sub filler { my ($from, $to, $ip, $host) = @_; return map { syslog_line($_, $ip, $host, "dnsmasq[1]: query[A] host-$_.example from 10.100.1.$_ padding padding padding padding") } $from .. $to }

#=== the DHCP source is not starved by the IPS's own big file (the browser's call)
make_path("$logd/ips/dnsmasq-dhcp");
spew("$logd/ips/2026-11-12.log", filler(0, 8000, '127.0.0.1', 'ips'));    # about 800 KB, no DHCPACK
spew("$logd/ips/dnsmasq-dhcp/2026-11-12.log",
    (map { syslog_line(30_000 + $_, '127.0.0.1', 'ips', "dnsmasq-dhcp[7]: DHCPACK(br0) 10.100.1.$_ 52:54:00:00:00:$_ node$_") } 10 .. 19));
my $log = HPS::Log->new(log_dir => $logd, now => $now, max_scan => 200 * 1024);    # the budget is a quarter of the file
my $r = $log->ips_log(lines => 5, grep => 'DHCPACK');
is(scalar @{ $r->{lines} }, 5, 'five DHCPACK lines although the IPS day file is far above the budget');
like($r->{lines}[-1]{message}, qr/10\.100\.1\.19 /, 'the newest is the last line');
like($r->{lines}[0]{message}, qr/10\.100\.1\.15 /, 'and they are the newest five');
is($r->{truncated} ? 1 : 0, 1, 'the IPS source ran out of budget before it found a line: said');
ok(defined $r->{scanned_back_to} && $r->{scanned_back_to} =~ /\A2026-11-12T\d\d:\d\d:\d\dZ\z/, 'with how far back it got (a time): ' . ($r->{scanned_back_to} // 'undef'));

#=== the newest matching lines of a file bigger than the budget, found from the end
spew("$logd/ips/dnsmasq-dhcp/2026-11-12.log", (filler(0, 8000, '127.0.0.1', 'ips')),
    (map { syslog_line(40_000 + $_, '127.0.0.1', 'ips', "dnsmasq-dhcp[7]: DHCPACK(br0) 10.100.1.$_ x node$_") } 1 .. 30));
$log = HPS::Log->new(log_dir => $logd, now => $now, max_scan => 200 * 1024);
$r = $log->ips_log(lines => 7, grep => 'dhcpack');
is(scalar @{ $r->{lines} }, 7, 'lines at the very end of a big file: found');
like($r->{lines}[-1]{message}, qr/10\.100\.1\.30 /, 'newest last');
like($r->{lines}[0]{message}, qr/10\.100\.1\.24 /, 'the newest seven');
my $scanned = $log->{scanned};
cmp_ok($scanned, '<', 400 * 1024, 'it stopped when it had seven: not the whole file read');

#=== matches only far back: the budget is hit, and the read says how far it got
spew("$logd/ips/dnsmasq-dhcp/2026-11-12.log",
    (map { syslog_line(100 + $_, '127.0.0.1', 'ips', "dnsmasq-dhcp[7]: DHCPACK(br0) 10.100.1.$_ x old$_") } 1 .. 3),
    filler(1000, 9000, '127.0.0.1', 'ips'));
$log = HPS::Log->new(log_dir => $logd, now => $now, max_scan => 200 * 1024);
$r = $log->ips_log(lines => 5, grep => 'DHCPACK');
is($r->{truncated} ? 1 : 0, 1, 'matches beyond the budget: truncated');
is(scalar @{ $r->{lines} }, 0, 'none found within it');
my $back = $r->{scanned_back_to};
ok(defined $back, 'scanned_back_to is given');
my ($h) = $back =~ /T(\d\d):/;
cmp_ok($h, '>=', 1, 'it is a time later than the start of the file (the scan did not get to the lines at the top)');
$log = HPS::Log->new(log_dir => $logd, now => $now, max_scan => 50 * 1024 * 1024);
$r = $log->ips_log(lines => 5, grep => 'DHCPACK');
is(scalar @{ $r->{lines} }, 3, 'with a budget that holds the file: the three old lines');
ok(!$r->{truncated} && !exists $r->{scanned_back_to}, 'and no truncation is said');

#=== the grep prefilter loses nothing across block boundaries: compare with a plain scan
{
    my @all;
    my $seed = 12345;
    for my $i (0 .. 4999) {
        $seed = ($seed * 1103515245 + 12345) % 2147483648;
        my $hit = $seed % 53 == 0;
        push @all, syslog_line($i * 7, '10.9.9.9', 'node', 'hps: ' . ($hit ? "NEEDLE-line-$i " : "ordinary line $i ") . ('x' x ($seed % 90)));
    }
    make_path("$logd/10.9.9.9");
    spew("$logd/10.9.9.9/2026-11-12.log", @all);
    my @want = grep { /NEEDLE/ } @all;
    for my $n (1, 5, 30, 500) {
        my $l = HPS::Log->new(log_dir => $logd, now => $now);
        my $rr = $l->_result({}, [], { lines => $n }, [ $l->_collect([ [ "$logd/10.9.9.9/2026-11-12.log", 2026, 11 ] ], \&HPS::Log::parse_syslog, 'x', { lines => $n, grep => 'needle' }) ]);
        my @got = map { $_->{message} } @{ $rr->{lines} };
        my @exp = map { s/\A.*?\] hps: //r } @want[ ($#want - $n + 1 < 0 ? 0 : $#want - $n + 1) .. $#want ];
        is_deeply(\@got, \@exp, "grep over 5000 lines (many 64 KiB blocks): the newest $n, same as a plain scan");
    }
    my $l = HPS::Log->new(log_dir => $logd, now => $now);
    my $rr = $l->_result({}, [], { lines => 500 }, [ $l->_collect([ [ "$logd/10.9.9.9/2026-11-12.log", 2026, 11 ] ], \&HPS::Log::parse_syslog, 'x', { lines => 500, grep => 'needle' }) ]);
    is(scalar @{ $rr->{lines} }, scalar @want, 'all of them when fewer than N');
}

#=== hps-log host: a big file of one address does not hide the newest lines
{
    require HPS::Registry;
    make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    my $reg = HPS::Registry->new(config_base => $base, system_registry => "$base/system.db");
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set('525400aabbcc', 'HOSTNAME', 'sch-009');
    $reg->host_set('525400aabbcc', 'IP', '10.9.8.7');
    make_path("$logd/10.9.8.7");
    spew("$logd/10.9.8.7/2026-11-12.log", filler(0, 8000, '10.9.8.7', 'sch-009'),
        (map { syslog_line(50_000 + $_, '10.9.8.7', 'sch-009', "hps: ZFS-EVENT $_") } 1 .. 4));
    my $l = HPS::Log->new(log_dir => $logd, now => $now, registry => $reg, max_scan => 200 * 1024);
    my $rr = $l->host_log('sch-009', lines => 3, grep => 'zfs-event');
    is(scalar @{ $rr->{lines} }, 3, 'host: the newest three');
    like($rr->{lines}[-1]{message}, qr/ZFS-EVENT 4\z/, 'newest last');
    $rr = $l->host_log('sch-009', lines => 3);
    like($rr->{lines}[-1]{message}, qr/ZFS-EVENT 4\z/, 'host without a grep: the newest lines too');
}

#=== events and audit: newest first from a view file bigger than the budget
{
    my @ev = map { sprintf('2026-11-12T%02d:%02d:%02dZ ips HPS-EVENT pri=info kind=job subject=j%d state=ended hps-jobs: job j%d filler filler filler filler filler filler', int($_ / 3600) % 24, int($_ / 60) % 60, $_ % 60, $_, $_) } 0 .. 8000;
    spew("$logd/events.log", '2026-11-12T00:00:00Z ips HPS-EVENT pri=info kind=job subject=jearly state=ended hps-jobs: the earliest one', @ev, '2026-11-12T09:59:00Z ips HPS-EVENT pri=info kind=job subject=jfinal state=ended hps-jobs: the last one');
    my $l = HPS::Log->new(log_dir => $logd, now => $now, max_scan => 100 * 1024);
    my $rr = $l->events_log(lines => 3);
    is(scalar @{ $rr->{lines} }, 3, 'events: three lines from a file above the budget');
    like($rr->{lines}[-1]{message}, qr/the last one/, 'the newest');
    ok(!$rr->{truncated}, 'found within the budget: not truncated');
    $rr = $l->events_log(lines => 3, grep => 'earliest');
    is(scalar @{ $rr->{lines} }, 0, 'events: a line beyond the budget is not found');
    ok($rr->{truncated} && $rr->{scanned_back_to}, 'and it is said how far back the read got');
    spew("$logd/audit.log", map { sprintf('2026-11-12T%02d:%02d:%02dZ 10.1.1.1 [sch-001] ctrl-exec-api[1]:  ACTION=run n=%d padding padding padding padding padding', int($_ / 3600) % 24, int($_ / 60) % 60, $_ % 60, $_) } 0 .. 8000);
    $rr = $l->audit_log(lines => 2, grep => 'ACTION=run');
    is(scalar @{ $rr->{lines} }, 2, 'audit: the newest two');
    like($rr->{lines}[-1]{message}, qr/n=8000/, 'newest last');
}

#=== the CLI with the real budget: hps-browser's call, a day file above 64 MiB
{
    my $cli = "$Bin/../bin/hps-log";
    my $cl = "$base/clilog";
    make_path("$cl/ips/dnsmasq-dhcp");
    {
        open(my $fh, '>', "$cl/ips/2026-11-12.log") or die;
        my $line = 'dnsmasq[1]: query[A] host.example from 10.100.1.5 padding padding padding padding padding padding padding';
        for my $i (0 .. 720_000) { printf {$fh} "Nov 12 %02d:%02d:%02d 127.0.0.1 [ips] %s\n", int($i / 36000) % 24, int($i / 600) % 60, int($i / 10) % 60, $line }
        close $fh;
    }
    cmp_ok(-s "$cl/ips/2026-11-12.log", '>', 64 * 1024 * 1024, 'set up: the IPS day file is above the 64 MiB budget');
    spew("$cl/ips/dnsmasq-dhcp/2026-11-12.log",
        (map { syslog_line(20_000 + $_, '127.0.0.1', 'ips', "dnsmasq-dhcp[7]: DHCPACK(br0) 10.100.1.$_ 52:54:00:00:00:$_ node$_") } 1 .. 300));
    local $ENV{HPS_LOG} = $cl;
    my $out = `$^X $cli ips --lines 200 --grep DHCPACK --json 2>&1`;
    is($? >> 8, 0, 'hps-log ips --lines 200 --grep DHCPACK exits 0');
    my $d = decode_json($out);
    is($d->{count}, 200, '200 lines, no --since');
    like($d->{lines}[-1]{message}, qr/10\.100\.1\.300 /, 'the newest lease is the last');
    like($d->{lines}[0]{message}, qr/10\.100\.1\.101 /, 'the oldest of the 200 is the 101st');
    ok($d->{truncated}, 'the IPS day file used up its own budget: said');
    ok($d->{scanned_back_to}, 'with how far back it got');
    $out = `$^X $cli ips --lines 200 --grep DHCPACK 2>&1`;
    like($out, qr/# stopped early: the scan limit was reached; searched back to 2026-11-12T\d\d:\d\d:\d\dZ, older lines were not read\n/, 'the text view says it too');
    # nothing matches anywhere: no lines, and the same statement
    $out = `$^X $cli ips --lines 5 --grep NOSUCHWORD 2>&1`;
    like($out, qr/# no log lines\n# stopped early: the scan limit was reached; searched back to /, 'a word that is nowhere: no lines, and how far back it looked');
}

done_testing;
