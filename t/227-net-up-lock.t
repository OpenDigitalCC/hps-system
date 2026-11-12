#!/usr/bin/env perl
# IPS-34 item 7: one net-up at a time per host. Two net-up runs on one host (the
# pairing job and an operator call) raced and each failed to create the
# interface the other had just made. HPS::Node::net_up holds an flock on
# <jobs>/run/net-up-<mac>.lock for this host's calls, then takes each refreshed
# host's lock in turn for its refresh call. The test holds the locks itself
# (a second open file description conflicts with flock even in one process).
use strict;
use warnings;
use Test::More;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Node;
use HPS::Jobs;

my $MAC  = $StorageFixture::MAC;    # tch-001
my $PEER = '525400000012';          # tch-002
my $TRANSIT = { cidr => '10.11.2.0/24', vlan => 112, bridge => 'br-transit', purpose => 'transit' };
my $CLIENT  = { kind => 'vxlan', vni => 1100, over => 'transit', bridge => 'br-client', purpose => 'workload' };

# Two TCHs on one vxlan network: net-up on tch-001 makes its own two calls and
# refreshes tch-002. sleep advances the clock and runs $o{on_sleep}.
sub s1 {
    my (%o) = @_;
    my $f = StorageFixture::setup();
    my $reg = $f->{reg};
    my %hosts = ($MAC => [ 'tch-001', '10.11.0.12' ], $PEER => [ 'tch-002', '10.11.0.13' ]);
    for my $m (sort keys %hosts) {
        $reg->host_set($m, 'HOSTNAME', $hosts{$m}[0]);
        $reg->host_set($m, 'TYPE', 'TCH');
        $reg->host_set($m, 'os_id', 'x86_64:nixos:26.05');
        $reg->host_set($m, 'IP', $hosts{$m}[1]);
        $reg->host_set($m, 'NETMASK', '255.255.255.0');
    }
    $reg->cluster_set('lab', 'network_cidr', '10.11.0.0/24');
    $reg->cluster_set('lab', 'network_layout', { transit => $TRANSIT, client => $CLIENT });
    my @log;
    my $clock = 1_800_000_000;
    my $sleeps = 0;
    my $n = HPS::Node->new(host => 'tch-001', registry => $reg, storage => $f->{mk}->(host => $MAC), runner => $f->{ce},
        logger => sub { push @log, "$_[0] $_[1]" }, now => sub { $clock }, lock_wait => 10,
        sleep => sub { $clock += $_[0]; $sleeps++; $o{on_sleep}->($sleeps) if $o{on_sleep} });
    my $dir = HPS::Jobs->new(registry => $reg)->sub_dir('run');
    return ($n, $f, \@log, $dir, \$clock);
}

sub calls { my ($f) = @_; return [ map { "$_->{mac} $_->{script}" } $f->{ce}->calls ] }

sub hold {
    my ($dir, $mac) = @_;
    make_path($dir);
    open(my $fh, '>>', "$dir/net-up-$mac.lock") or die "lock: $!";
    flock($fh, LOCK_EX | LOCK_NB) or die "test could not take the lock";
    return $fh;
}

#--- no contention: the lock lives in the jobs run/ dir and is free afterwards
{
    my ($n, $f, $log, $dir) = s1();
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'free lock: ok');
    is_deeply(calls($f), [ "$MAC net-vlan-address", "$MAC net-vxlan-ensure", "$PEER net-vxlan-ensure" ],
        'its own two calls, then the refresh');
    ok(-e "$dir/net-up-$MAC.lock", 'the lock file is <jobs>/run/net-up-<mac>.lock');
    ok(-e "$dir/net-up-$PEER.lock", 'the refreshed host has its own lock file');
    my $fh = hold($dir, $MAC);
    ok($fh, 'released when net_up returns');
    is_deeply([ HPS::Jobs->new(registry => $f->{reg})->stale_run ], [], 'lock files are not stale jobs to the runner');
    ok(!grep({ /waiting/ } @$log), 'no wait logged');
}

#--- another net-up on this host: wait for it, then run
{
    my $held;
    my ($n, $f, $log, $dir) = s1(on_sleep => sub { undef $held if $_[0] == 3 });
    $held = hold($dir, $MAC);
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'held, then released: ok');
    is(scalar @{ calls($f) }, 3, 'all calls made after the wait');
    is(scalar(grep { /^info net-up: waiting for another net-up on $MAC/ } @$log), 1, 'the wait logged once');
}

#--- another net-up on this host never finishes: fail, call nothing
{
    my ($n, $f, $log, $dir, $clock) = s1();
    my $start = $$clock;
    my $held = hold($dir, $MAC);
    my $r = eval { $n->net_up };
    my $e = $@;
    ok(!$r, 'still held after lock_wait: dies');
    is(ref $e && $e->kind, 'failed', 'kind failed (hps-node exit 1)');
    like(ref $e && $e->message, qr/tch-001: another net-up for this host is still running after 10s/, 'says why');
    is_deeply(calls($f), [], 'no node call');
    is($$clock - $start, 10, 'waited lock_wait seconds');
}

#--- the refreshed host's own net-up holds its lock: that refresh skipped
{
    my ($dir, $own_free);
    my ($n, $f, $log);
    ($n, $f, $log, $dir) = s1(on_sleep => sub {
        return if defined $own_free;
        open(my $t, '>>', "$dir/net-up-$MAC.lock") or die;
        $own_free = flock($t, LOCK_EX | LOCK_NB) ? 1 : 0;
    });
    my $held = hold($dir, $PEER);
    my $r = $n->net_up;
    is($r->{result}, 'ok', 'a busy peer: still ok (a refresh never changes the result)');
    is_deeply(calls($f), [ "$MAC net-vlan-address", "$MAC net-vxlan-ensure" ], 'the peer not called');
    like($r->{refresh}[0]{error}, qr/not called: another net-up for tch-002 is still running after 10s/, 'kept on the entry');
    ok((grep { /^warning .*refresh tch-002 client: not called/ } @$log), 'logged as a warning');
    is($own_free, 1, "this host's lock is free while net_up waits on the peer's (never two held)");
}

#--- dry run takes no lock
{
    my ($n, $f, $log, $dir) = s1();
    my $held = hold($dir, $MAC);
    my $r = $n->net_up(dry_run => 1);
    ok($r, 'dry run with the lock held: no wait, no failure');
}

done_testing;
