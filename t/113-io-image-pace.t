#!/usr/bin/env perl
# Workload create: vm-image-write gets --mbps-max N, derived on the IPS from
# the leg hosts' measured pool write speed times image_write_fraction (default
# 0.5; the lowest across the disk's legs); no measurement, no pacing and a log
# line saying so. No MiB/s number is held anywhere but the registry.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my ($m1, $m2) = ($StorageFixture::MAC, $StorageFixture::MAC2);

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

# A workload whose root disks mirror sch-001 (local) and sch-002 (remote).
sub fixture {
    my $f = StorageFixture::setup_workload(no_def => 1);
    $f->{reg}->host_set($m2, 'STATE', 'NETWORK_BOOT');
    $f->{reg}->host_set($m2, 'HOSTNAME', 'sch-002');
    $f->{reg}->host_set($m2, 'TYPE', 'SCH');
    my $d = $f->{def};
    for my $vm (@{ $d->{vms} }) {
        $vm->{disks}[0]{legs}[1] = { host => 'sch-002', iqn => "iqn.2026-01.lab.sch2:hpslab-$vm->{name}", portal => '192.0.2.52' };
    }
    StorageFixture::write_def($f, $d);
    return $f;
}
sub write_args { my ($plan, $vm) = @_; my ($s) = grep { $_->{script} eq 'vm-image-write' && $_->{args}[0] eq $vm } @$plan; return $s ? $s->{args} : undef }
sub measured { my ($f, $mac, $mbps, $at) = @_; $f->{reg}->host_set($mac, 'storage_pool_write_mbps', $mbps); $f->{reg}->host_set($mac, 'storage_measured_at', $at // '2026-11-13T09:00:00Z') }

# --- no measurement: no pacing, no option, one log line per image write on run
{
    my $f = fixture();
    my $plan = $f->{wl}->()->plan('create', 't0');
    my $a = write_args($plan, 't0-app');
    ok($a, 'a vm-image-write step');
    is_deeply($a, [ 't0-app', '--disk', '/dev/md/t0-app-root', '--image', '/lab/enc/images/debian-13-generic-amd64.qcow2' ], 'no --mbps-max without a measurement');
    $f->{wl}->()->run('create', 't0');
    my @l = grep { /image write of t0-app is not paced/ } @{ $f->{log} };
    is(scalar @l, 1, 'one log line: not paced');
    like($l[0], qr/no storage host of the disk has a measured storage_pool_write_mbps \(hps-storage <host> measure\)/, 'the line says why and how to fix it');
}

# --- measured on one leg host only: that figure x 0.5 (the default fraction)
{
    my $f = fixture();
    measured($f, $m1, 400);
    my $plan = $f->{wl}->()->plan('create', 't0');
    is_deeply([ @{ write_args($plan, 't0-app') }[ 5, 6 ] ], [ '--mbps-max', 200 ], '400 x 0.5 = 200');
    $f->{wl}->()->run('create', 't0');
    ok((grep { /image write of t0-app paced to 200 MiB\/s: image_write_fraction 0\.5 \(default\) x storage_pool_write_mbps 400 of sch-001 \(lowest of 1 measured of 2 hosts\), measured 2026-11-13T09:00:00Z/ } @{ $f->{log} }), 'the log line names fraction, source figure, host, date');
}

# --- both legs measured: the lowest wins
{
    my $f = fixture();
    measured($f, $m1, 400);
    measured($f, $m2, 150, '2026-11-12T10:00:00Z');
    my $plan = $f->{wl}->()->plan('create', 't0');
    is_deeply([ @{ write_args($plan, 't0-db') }[ 5, 6 ] ], [ '--mbps-max', 75 ], 'lowest of the legs: 150 x 0.5 = 75');
    $f->{wl}->()->run('create', 't0');
    ok((grep { /paced to 75 MiB\/s: .* of sch-002 \(lowest of 2 measured of 2 hosts\), measured 2026-11-12T10:00:00Z/ } @{ $f->{log} }), 'the log names the limiting host and how many legs had a figure');
}

# --- the cluster key is a fraction; a different one changes the figure
{
    my $f = fixture();
    measured($f, $m1, 400);
    $f->{reg}->cluster_set('lab', 'image_write_fraction', '0.25');
    my $plan = $f->{wl}->()->plan('create', 't0');
    is_deeply([ @{ write_args($plan, 't0-app') }[ 5, 6 ] ], [ '--mbps-max', 100 ], '0.25 x 400');
    $f->{reg}->cluster_set('lab', 'image_write_fraction', '0.01');
    $plan = $f->{wl}->()->plan('create', 't0');
    is(write_args($plan, 't0-app')->[6], 4, '0.01 x 400');
    measured($f, $m1, 50);
    $plan = $f->{wl}->()->plan('create', 't0');
    is(write_args($plan, 't0-app')->[6], 1, 'a figure under 1 MiB/s is 1, never 0 (0 would mean no pacing)');
}
{
    my $f = fixture();
    measured($f, $m1, 400);
    for my $bad ('1', '0', '0.0', '1.5', 'half', '50', '-0.5', '0.5x') {
        $f->{reg}->cluster_set('lab', 'image_write_fraction', $bad);
        my $e = err_of(sub { $f->{wl}->()->plan('create', 't0') });
        ok($e && ref $e && $e->kind eq 'refused', "image_write_fraction '$bad' is refused");
        like(ref $e ? $e->message : '', qr/image_write_fraction.*fraction above 0 and below 1.*hps-cluster-config set image_write_fraction 0\.5/, 'and the fix is named') if $bad eq '50';
    }
}

# --- a disk with one local leg only: its host's figure
{
    my $f = StorageFixture::setup_workload(no_def => 1);
    $f->{def}{vms}[0]{disks}[0]{legs} = [ { host => 'sch-001', pool => 'lab' } ];
    StorageFixture::write_def($f, $f->{def});
    measured($f, $m1, 300);
    my $plan = $f->{wl}->()->plan('create', 't0');
    my $a = write_args($plan, 't0-app');
    is_deeply([ @$a[ 5, 6 ] ], [ '--mbps-max', 150 ], 'one local leg');
    like($a->[2], qr{^/dev/zvol/lab/enc/vm/t0-t0-app-root$}, 'the device is the zvol');
}

# --- a network-boot VM has no image write, so no pacing question
{
    my $f = StorageFixture::setup_workload(no_def => 1);
    $f->{def}{vms}[0]{boot} = 'network';
    delete $f->{def}{vms}[0]{image};
    StorageFixture::write_def($f, $f->{def});
    my $plan = $f->{wl}->()->plan('create', 't0');
    ok(!write_args($plan, 't0-app'), 'no image write for a network-boot VM');
}

# --- no number of MiB/s lives in the code
{
    open(my $fh, '<', "$Bin/../lib/perl/HPS/Workload.pm") or die;
    my $src = do { local $/; <$fh> };
    my ($block) = $src =~ /(#=== I\/O budget.*?#=== definitions on disk)/s;
    ok($block, 'found the I/O budget code');
    my @nums = grep { !/^\s*#/ && !/FRACTION_DEFAULT/ } grep { /\b[0-9]{2,}\b/ } split /\n/, $block;
    is_deeply(\@nums, [], 'no multi-digit constant in the I/O budget code');
}

done_testing;
