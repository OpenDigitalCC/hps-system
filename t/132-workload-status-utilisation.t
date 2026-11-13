#!/usr/bin/env perl
# hps-workload status: per VM the latest utilisation from its compute host's
# `vms` perfdata, or "utilisation": null with a reason.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Metrics;

{
    package StubMetrics;
    sub new { my ($c, %o) = @_; return bless { %o, calls => 0 }, $c }
    sub latest { my ($s, $h) = @_; $s->{calls}++; die $s->{die} if $s->{die}; return $s->{r} }
}

my $f = StorageFixture::setup_workload();
my $ce = $f->{ce};
{
    my $wl = $f->{wl}->(storage => sub { $f->{mk}->(host => $_[0]) });
    $wl->run('create', 't0');
}
my $ep = 1794584157;
sub rec { return { hosts => [ { checks => [ { check => 'cpu', epoch => $ep, perf => {} },
    { check => 'vms', epoch => $ep, perf => { vms => 1, 't0-app_cpu_pct' => 12.5, 't0-app_rss' => 2097152, 't0-app_mem' => 4194304,
        't0-app_vcpus' => 2, 't0-app_rd_Bps' => 1, 't0-app_wr_Bps' => 2, 't0-app_rx_Bps' => 3, 't0-app_tx_Bps' => 4 } } ] } ] } }
$ce->{out} = { 'vm-status' => "dominfo\nVM x running\n", 'mirror-status' => "detail\nMIRROR x clean\n" };

my $st = StubMetrics->new(r => rec());
my $wl = $f->{wl}->(storage => sub { $f->{mk}->(host => $_[0]) }, metrics => $st);
my $r = $wl->run('status', 't0');
my %v = map { $_->{vm} => $_ } @{ $r->{vms} };
my $u = $v{'t0-app'}{utilisation};
is_deeply({ map { $_ => $u->{$_} } grep { $_ ne 'sampled_at' } keys %$u },
    { cpu_pct => 12.5, rss_mib => 2, mem_mib => 4, vcpus => 2, rd_bps => 1, wr_bps => 2, rx_bps => 3, tx_bps => 4 }, 'utilisation of a listed VM');
like($u->{sampled_at}, qr/\A2026-11-1\dT\d\d:\d\d:\d\dZ\z/, 'sampled_at is the vms check time, ISO UTC');
ok(!exists $v{'t0-app'}{utilisation_reason}, 'no reason when there is a sample');
ok(!defined $v{'t0-db'}{utilisation}, 'a VM the sample does not list: null');
like($v{'t0-db'}{utilisation_reason}, qr/does not list t0-db/, 'with the reason');
is($st->{calls}, 1, 'one read per compute host');
like(JSON::PP->new->canonical->encode($v{'t0-db'}), qr/"utilisation":null/, 'JSON says "utilisation": null');

$wl = $f->{wl}->(storage => sub { $f->{mk}->(host => $_[0]) }, metrics => StubMetrics->new(die => bless({ kind => 'notfound', message => 'no hps-monitor result for x in the newest 900s' }, 'HPS::Metrics::Error')));
$r = $wl->run('status', 't0');
ok(!defined $r->{vms}[0]{utilisation}, 'host without a sample: null');
like($r->{vms}[0]{utilisation_reason}, qr/no monitor sample for host .*no hps-monitor result/, 'with the host error as reason');
ok($r->{ok}, 'and status stays ok');

$wl = $f->{wl}->(storage => sub { $f->{mk}->(host => $_[0]) }, metrics => StubMetrics->new(r => { hosts => [ { checks => [] } ] }));
$r = $wl->run('status', 't0');
like($r->{vms}[0]{utilisation_reason}, qr/no vms check/, 'host run without a vms check: said so');
done_testing;
