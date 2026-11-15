#!/usr/bin/env perl
# The boot-stalled watch writes HPS::Event marker lines (docs/LOGGING.md, kind boot):
# every line parses, the priorities are the documented ones, and `hps-log attention`
# (HPS::Log::attention) shows a stalled node and drops it when it boots.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX qw(strftime);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::BootWatch;
use HPS::Event;
use HPS::Issues;
use HPS::Log;

my $T = 1_800_000_000;
my $clock = sub { $T };
my $MAC = '52:54:00:12:34:56';
my $HOST = '525400123456';

my $layout = { %{ StorageFixture::layout() }, prov => { cidr => '10.100.1.0/24', vlan => undef, bridge => 'br-prov', purpose => 'provisioning', uplink => 'boot' } };

# fixture(): workload n0 with one network-boot VM, started at $T; the watch logs into $f->{lines}
# as events.log lines (<rfc3339 time> <host> <message>), the form rsyslog files.
sub fixture {
    my (%o) = @_;
    my $f = StorageFixture::setup_workload(no_def => 1, ce => { out => { 'vm-define' => "VM n0-node defined mac=$MAC\n" } });
    $f->{reg}->cluster_set('lab', 'network_layout', $layout);
    StorageFixture::write_def($f, { name => 'n0', project => 'lab', vms => [
        { name => 'n0-node', memory_mib => 4096, vcpus => 2, boot => 'network', nets => ['prov'], compute_host => 'sch-001' } ] });
    $f->{wl_obj} = $f->{wl}->(now => $clock);
    $f->{wl_obj}->run('create', 'n0');
    $f->{wl_obj}->run('start', 'n0', vm => 'n0-node');
    $f->{lines} = [];
    $f->{ready} = $o{ready} // 'ready';
    my $issues = HPS::Issues->new(registry => $f->{reg}, now => $clock, logger => sub { });
    $f->{bw} = HPS::BootWatch->new(registry => $f->{reg}, issues => $issues, workload => $f->{wl_obj}, now => $clock,
        ready => sub { $f->{ready} },
        logger => sub { my ($level, $msg) = @_; push @{ $f->{lines} }, { level => $level, msg => $msg, at => $T } if $msg =~ /\AHPS-/ },
        settings => { window => 180, max => 3, metal => 0, warnings => [], %{ $o{settings} // {} } });
    return $f;
}
sub tick_at { my ($f, $dt) = @_; $T += $dt; return $f->{bw}->tick }

# attention($f): HPS::Log's answer over an events.log made from the lines logged so far.
sub attention {
    my ($f) = @_;
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);
    open(my $h, '>', "$dir/events.log") or die;
    print {$h} strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($_->{at})), " ips.lab $_->{msg}\n" for @{ $f->{lines} };
    close $h;
    return HPS::Log->new(log_dir => $dir, now => $T)->attention(since => '1h');
}
sub states { my ($f) = @_; return map { HPS::Event::parse($_->{msg})->{state} } @{ $_[0]{lines} } }
sub problems { my ($a) = @_; return grep { $_->{kind} eq 'boot' } @{ $a->{problems} } }

#=== every line of the watch is an event line of kind boot, with the documented priority
{
    my $f = fixture();
    tick_at($f, 200);    # reset 1
    $f->{reg}->host_set($HOST, 'last_boot_at', $T);
    tick_at($f, 20);     # booted
    my %pri = (reset => 'notice', booted => 'notice', 'boot-stalled' => 'warning');
    ok(scalar @{ $f->{lines} } >= 3, 'the watch logged lines');
    my $bad = 0;
    for my $l (@{ $f->{lines} }) {
        my $e = HPS::Event::parse($l->{msg});
        if (!$e || $e->{kind} ne 'boot' || $e->{subject} ne 'n0/n0-node' || ($pri{ $e->{state} } // '') ne $e->{pri}
            || $l->{level} ne HPS::Event::syslog_level($e->{pri})) { $bad++; diag "bad line: $l->{level} $l->{msg}" }
    }
    is($bad, 0, 'each parses as HPS::Event, kind boot, the workload/VM as subject, the documented priority and syslog level');
    like($f->{lines}[0]{msg}, qr/\AHPS-ALERT pri=warning kind=boot subject=n0\/n0-node state=boot-stalled /, 'the first is the stall, an HPS-ALERT');
    like($f->{lines}[-1]{msg}, qr/\AHPS-EVENT pri=notice kind=boot subject=n0\/n0-node state=booted /, 'the last is booted, an HPS-EVENT');
}

#=== attention shows a stalled node and clears it when it boots (the boot services do not answer)
{
    my $f = fixture(ready => 'not_ready');
    is(tick_at($f, 400), 0, 'stalled with the IPS deaf: deferred, no reset');
    is_deeply([ states($f) ], ['boot-stalled'], 'one boot-stalled line');
    my $a = attention($f);
    is($a->{status}, 'attention', 'hps-log attention: attention');
    my @p = problems($a);
    is(scalar(@p), 1, 'one boot problem');
    is_deeply([ @{ $p[0] }{qw(pri kind subject state)} ], [ 'warning', 'boot', 'n0/n0-node', 'boot-stalled' ], 'the stalled node, a warning');
    like($p[0]{text}, qr/boot services do not answer/, 'with the reason');
    tick_at($f, 301);
    my $a2 = attention($f);
    is(scalar(problems($a2)), 1, 'later: still one problem (the line is repeated, not duplicated in the answer)');
    ok(@{ $f->{lines} } >= 2, 'the standing line was repeated after 5 minutes');

    $f->{reg}->host_set($HOST, 'last_boot_at', $T);
    tick_at($f, 20);
    my @s = states($f);
    is($s[-1], 'booted', 'the node reaches iPXE: a booted line follows');
    my $b = attention($f);
    is(scalar(problems($b)), 0, 'hps-log attention: the stalled node is gone');
    is($b->{status}, 'clear', 'and nothing else needs attention');
}

#=== a node that gave up shows until it boots, and is repeated while it holds
{
    my $f = fixture(settings => { max => 0 });
    tick_at($f, 400);
    is_deeply([ states($f) ], ['gave-up'], 'max 0: the stall is the give-up line');
    is($f->{lines}[0]{msg} =~ /\AHPS-ALERT pri=warning /, 1, 'a warning');
    is(scalar(problems(attention($f))), 1, 'attention shows it');
    tick_at($f, 100);
    is(scalar(@{ $f->{lines} }), 1, 'not repeated within 50 minutes');
    tick_at($f, HPS::Event::REMIND);
    is_deeply([ states($f) ], [ 'gave-up', 'gave-up' ], 'repeated after that');
    $f->{reg}->host_set($HOST, 'last_boot_at', $T);
    tick_at($f, 20);
    is((states($f))[-1], 'booted', 'booted follows');
    is(scalar(problems(attention($f))), 0, 'and attention drops it');
}

done_testing;
