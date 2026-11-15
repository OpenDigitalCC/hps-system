#!/usr/bin/env perl
# Layer 3 (docs/BOOT-RELIABILITY.md): HPS::BootReady - the boot-services check, its
# verdicts, the wait and the gate. Every function and every verdict.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use BootFixture;
use HPS::BootReady;

my $IPS = $BootFixture::IPS;

#--- exit codes
is(HPS::BootReady::exit_code('ready'), 0, 'ready: exit 0');
is(HPS::BootReady::exit_code('not_ready'), 1, 'not ready: exit 1');
is(HPS::BootReady::exit_code('unknown'), 3, 'cannot tell: exit 3');

#--- int_setting
is_deeply([ HPS::BootReady::int_setting(undef, 60, 0, 600, 'k') ], [ 60, undef ], 'unset: the default, silently');
is_deeply([ HPS::BootReady::int_setting('', 60, 0, 600, 'k') ], [ 60, undef ], 'empty: the default, silently');
is_deeply([ HPS::BootReady::int_setting('0', 60, 0, 600, 'k') ], [ 0, undef ], '0 is allowed when the minimum is 0');
is_deeply([ HPS::BootReady::int_setting(' 90 ', 60, 0, 600, 'k') ], [ 90, undef ], 'a number is used');
for my $bad ('601', '-1', 'abc', '1.5', '007') {
    my ($v, $w) = HPS::BootReady::int_setting($bad, 60, 0, 600, 'k');
    is($v, 60, "'$bad': the default");
    like($w, qr/k='\Q$bad\E' is not an integer 0\.\.600; using 60/, "'$bad': warned, naming the key and the value");
}
is_deeply([ HPS::BootReady::wait_seconds(undef) ], [ 60, undef ], 'wait_seconds: default 60');
is_deeply([ HPS::BootReady::wait_seconds('5') ], [ 5, undef ], 'wait_seconds: 5');

#--- udp_bound
my $udp = BootFixture::udp_text(67, 69);
ok(HPS::BootReady::udp_bound($udp, 67, [$IPS]), 'UDP 67 bound on the provisioning address');
ok(!HPS::BootReady::udp_bound($udp, 68, [$IPS]), 'port 68 is not bound');
ok(!HPS::BootReady::udp_bound($udp, 67, ['10.9.9.9']), 'bound on another address only: not bound here');
ok(!HPS::BootReady::udp_bound('', 67, [$IPS]), 'empty table: not bound');
ok(!HPS::BootReady::udp_bound(undef, 67, [$IPS]), 'undef table: not bound');
my $wild = "  0: 00000000:0043 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 1 2 0\n";
ok(HPS::BootReady::udp_bound($wild, 67, [$IPS]), 'the wildcard address counts');
ok(HPS::BootReady::udp_bound($wild, 67, ['bad']), 'a bad address is ignored; the wildcard still counts');
ok(!HPS::BootReady::udp_bound("garbage line\n", 67, [$IPS]), 'a line that is not a socket is ignored');

#--- process_running
{
    my $f = BootFixture::make();
    is(HPS::BootReady::process_running($f->{proc}, 'dnsmasq'), 1, 'a dnsmasq process is found');
    is(HPS::BootReady::process_running($f->{proc}, 'lighttpd'), 0, 'another name is not');
    is(HPS::BootReady::process_running("$f->{dir}/no-such-proc", 'dnsmasq'), undef, 'an unreadable process table: undef');
}

#--- verdict
is(HPS::BootReady::verdict([]), 'unknown', 'no checks: unknown');
is(HPS::BootReady::verdict([ { status => 'pass' }, { status => 'pass' } ]), 'ready', 'all pass: ready');
is(HPS::BootReady::verdict([ { status => 'pass' }, { status => 'unknown' } ]), 'unknown', 'one cannot be looked at: unknown');
is(HPS::BootReady::verdict([ { status => 'unknown' }, { status => 'fail' } ]), 'not_ready', 'a fail beats an unknown');

#--- check: every verdict, with an in-process HTTP answer
my $http_ok = sub { return (200, "hps.test\n") };
sub run_check { my ($f, %o) = @_; return HPS::BootReady::check(registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp}, http_get => $http_ok, %o) }
sub by_name { my ($r) = @_; return { map { $_->{name} => $_ } @{ $r->{checks} } } }

{
    my $f = BootFixture::make();
    my $r = run_check($f);
    is($r->{verdict}, 'ready', 'everything answers: ready');
    is_deeply([ map { $_->{name} } @{ $r->{checks} } ], [qw(dnsmasq dhcp tftp http)], 'the four checks, in order');
    is_deeply([ map { $_->{status} } @{ $r->{checks} } ], [ ('pass') x 4 ], 'all pass');
    like(by_name($r)->{http}{reason}, qr{HTTP 200 from http://\Q$IPS\E/cgi-bin/boot_manager\.sh\?cmd=cluster_variable}, 'the http probe is read-only (cluster_variable, not init)');
}
{
    my $f = BootFixture::make(dnsmasq => 0);
    my $r = run_check($f);
    is($r->{verdict}, 'not_ready', 'dnsmasq not running: not ready');
    is(by_name($r)->{dnsmasq}{status}, 'fail', 'dnsmasq fails');
    like(by_name($r)->{dnsmasq}{reason}, qr/not running/, 'and says so');
}
{
    my $f = BootFixture::make(ports => [69]);
    my $r = run_check($f);
    is($r->{verdict}, 'not_ready', 'no DHCP listener: not ready');
    like(by_name($r)->{dhcp}{reason}, qr/nothing listens for DHCP \(UDP 67\) on \Q$IPS\E/, 'dhcp names the address');
    is(by_name($r)->{tftp}{status}, 'pass', 'tftp still passes');
}
{
    my $f = BootFixture::make(ports => [67]);
    my $r = run_check($f);
    is(by_name($r)->{tftp}{status}, 'fail', 'no TFTP listener: tftp fails');
    like(by_name($r)->{tftp}{reason}, qr/UDP 69/, 'naming port 69');
}
{
    my $f = BootFixture::make(tftp_files => 0);
    my $r = run_check($f);
    is(by_name($r)->{tftp}{status}, 'fail', 'no first-stage file: tftp fails');
    like(by_name($r)->{tftp}{reason}, qr/snponly\.efi undionly\.kpxe/, 'naming both files');
    open(my $h, '>', "$f->{tftp}/snponly.efi") or die;
    close $h;
    $r = run_check($f);
    like(by_name($r)->{tftp}{reason}, qr/missing or empty.*snponly\.efi undionly\.kpxe/, 'an empty file counts as missing');
    BootFixture::write_file("$f->{tftp}/snponly.efi", 'x');
    BootFixture::write_file("$f->{tftp}/undionly.kpxe", 'x');
    is(run_check($f)->{verdict}, 'ready', 'both present: ready again');
}
{
    my $f = BootFixture::make();
    for my $case ([ 'no answer', sub { return } , qr/no HTTP answer/ ], [ '503', sub { (503, 'x') }, qr/HTTP 503/ ], [ 'empty 200', sub { (200, "  \n") }, qr/answer is empty/ ],
        [ 'dies', sub { die "boom\n" }, qr/no HTTP answer/ ]) {
        my ($label, $get, $re) = @$case;
        my $r = run_check($f, http_get => $get);
        is($r->{verdict}, 'not_ready', "http $label: not ready");
        like(by_name($r)->{http}{reason}, $re, "http $label: reason");
    }
}
{
    # cannot tell: no address, no process table, no udp table
    my $f = BootFixture::make(no_ip => 1);
    my $r = run_check($f);
    is($r->{verdict}, 'unknown', 'no provisioning address: cannot tell');
    is(by_name($r)->{dhcp}{status}, 'unknown', 'dhcp unknown');
    is(by_name($r)->{http}{status}, 'unknown', 'http unknown');
    $f = BootFixture::make();
    $r = run_check($f, proc_dir => "$f->{dir}/nope");
    is($r->{verdict}, 'unknown', 'process table unreadable: cannot tell');
    is(by_name($r)->{dnsmasq}{status}, 'unknown', 'dnsmasq unknown');
    $r = run_check($f, proc_net_udp => "$f->{dir}/nope");
    is($r->{verdict}, 'unknown', 'udp table unreadable: cannot tell');
    is(by_name($r)->{dhcp}{status}, 'unknown', 'dhcp unknown');
    is(by_name($r)->{tftp}{status}, 'unknown', 'tftp unknown');
    $f = BootFixture::make(dnsmasq => 0, no_ip => 1);
    is(run_check($f)->{verdict}, 'not_ready', 'a failed check wins over an unknown one');
}

#--- wait_ready: bounded, on a fake clock
{
    my $f = BootFixture::make(dnsmasq => 0);
    my $t = 1000;
    my @sleeps;
    my $r = HPS::BootReady::wait_ready(registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp},
        http_get => $http_ok, wait => 7, interval => 2, now => sub { $t }, sleep => sub { push @sleeps, $_[0]; $t += $_[0] });
    is($r->{verdict}, 'not_ready', 'never ready: not ready after the wait');
    is($r->{waited}, 7, 'waited exactly the bound');
    is_deeply(\@sleeps, [ 2, 2, 2, 1 ], 'in steps of the interval, the last one short');
    @sleeps = ();
    $r = HPS::BootReady::wait_ready(registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp},
        http_get => $http_ok, wait => 0, now => sub { $t }, sleep => sub { push @sleeps, $_[0] });
    is_deeply(\@sleeps, [], 'wait 0: one check, no sleep');
    # becomes ready during the wait
    my $calls = 0;
    my $get = sub { return $calls++ < 2 ? (503, 'x') : (200, 'ok') };
    $f = BootFixture::make();
    $r = HPS::BootReady::wait_ready(registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp},
        http_get => $get, wait => 60, interval => 5, now => sub { $t }, sleep => sub { $t += $_[0] });
    is($r->{verdict}, 'ready', 'ready during the wait: ready');
    is($r->{waited}, 10, 'it stopped waiting at once');
}

#--- gate
{
    my $f = BootFixture::make(dnsmasq => 0);
    my $t = 0;
    my %base = (registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp}, http_get => $http_ok,
        now => sub { $t }, sleep => sub { $t += $_[0] });
    local $ENV{HPS_BOOT_READY_SKIP};
    my $g = HPS::BootReady::gate(%base, wait => 4);
    ok(!$g->{ok}, 'gate: not ready refuses');
    like($g->{message}, qr/do not answer after 4 s \(dnsmasq: dnsmasq is not running\)/, 'the message names the wait and what does not answer');
    like($g->{message}, qr/--no-boot-wait/, 'and the way round');
    $f = BootFixture::make();
    %base = (%base, registry => $f->{reg}, proc_dir => $f->{proc}, proc_net_udp => $f->{udp}, tftp_dir => $f->{tftp});
    $g = HPS::BootReady::gate(%base, wait => 4);
    ok($g->{ok}, 'gate: ready goes ahead');
    is($g->{verdict}, 'ready', 'verdict ready');
    is_deeply($g->{warnings}, [], 'no warnings');
    $g = HPS::BootReady::gate(%base, wait => 1, proc_dir => "$f->{dir}/nope");
    ok($g->{ok}, 'gate: cannot tell goes ahead');
    is($g->{verdict}, 'unknown', 'verdict unknown');
    like($g->{warnings}[0], qr/could not be checked.*going ahead/, 'with a warning that says so');
    $f->{reg}->cluster_set('lab', 'boot_ready_wait_seconds', '3');
    my $f2 = BootFixture::make(dnsmasq => 0);
    $f2->{reg}->cluster_set('lab', 'boot_ready_wait_seconds', '3');
    $g = HPS::BootReady::gate(%base, registry => $f2->{reg}, proc_dir => $f2->{proc}, proc_net_udp => $f2->{udp}, tftp_dir => $f2->{tftp});
    like($g->{message}, qr/after 3 s/, 'the wait comes from boot_ready_wait_seconds');
    $f2->{reg}->cluster_set('lab', 'boot_ready_wait_seconds', '9999');
    $g = HPS::BootReady::gate(%base, registry => $f2->{reg}, proc_dir => $f2->{proc}, proc_net_udp => $f2->{udp}, tftp_dir => $f2->{tftp});
    like($g->{message}, qr/after 60 s/, 'a bad value: the default 60 s');
    like($g->{warnings}[0], qr/boot_ready_wait_seconds='9999'/, 'and a warning names it');
    local $ENV{HPS_BOOT_READY_SKIP} = 1;
    $g = HPS::BootReady::gate(%base, registry => $f2->{reg}, proc_dir => $f2->{proc});
    ok($g->{ok} && $g->{verdict} eq 'skipped', 'HPS_BOOT_READY_SKIP skips the gate');
}

done_testing;
