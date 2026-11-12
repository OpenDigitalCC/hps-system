#!/usr/bin/env perl
# Resource isolation (owner 2026-11-12: guests must not starve the host or each
# other). Per-VM limits in the workload definition (validation, the vm-define
# arguments), the host reserve cluster keys, and hps-node resources.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;
use HPS::ClusterConfig;
use HPS::Node;

my $layout = StorageFixture::layout();

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }

sub refuses {
    my ($mut, $re, $label) = @_;
    my $d = StorageFixture::base_def();
    $mut->($d->{vms}[0]);
    my $e = err_of(sub { HPS::Workload::validate($d, layout => $layout) });
    ok(defined $e && ref $e, "$label: refused") or return;
    is($e->kind, 'refused', "$label: kind refused");
    like($e->message, $re, "$label: reason named");
    return;
}

sub accepts {
    my ($mut, $label) = @_;
    my $d = StorageFixture::base_def();
    $mut->($d->{vms}[0]);
    my $v = eval { HPS::Workload::validate($d, layout => $layout) };
    ok($v, "$label: valid") or diag $@ && $@->message;
    return $v;
}

# --- definitions without limits are unchanged ----------------------------------------
{
    my $v = HPS::Workload::validate(StorageFixture::base_def(), layout => $layout);
    for my $k (qw(cpu_weight cpu_max_pct mem_hard_limit_mib io_weight)) {
        ok(!exists $v->{vms}[0]{$k}, "no limits given: no $k key");
    }
    ok(!exists $v->{vms}[0]{disks}[0]{iops_max} && !exists $v->{vms}[0]{disks}[0]{mbps_max}, 'no disk limit keys');
}

# --- per-VM and per-disk limits: accepted and carried ----------------------------------
{
    my $v = accepts(sub {
        @{ $_[0] }{qw(cpu_weight cpu_max_pct mem_hard_limit_mib io_weight)} = (50, 50, 2560, 100);
        @{ $_[0]{disks}[0] }{qw(iops_max mbps_max)} = (2000, 200);
    }, 'every limit');
    my $vm = $v->{vms}[0];
    is_deeply([ @{$vm}{qw(cpu_weight cpu_max_pct mem_hard_limit_mib io_weight)} ], [ 50, 50, 2560, 100 ], 'VM limits carried');
    is_deeply([ @{ $vm->{disks}[0] }{qw(iops_max mbps_max)} ], [ 2000, 200 ], 'disk limits carried');
    accepts(sub { $_[0]{cpu_max_pct} = 100; $_[0]{cpu_weight} = 10000 }, 'upper bounds');
    accepts(sub { $_[0]{mem_hard_limit_mib} = 2048 + 128 }, 'hard limit exactly memory + 128');
    accepts(sub { $_[0]{disks}[0]{mbps_max} = 1 }, 'one disk limit alone');
}
refuses(sub { $_[0]{cpu_weight} = 0 }, qr/cpu_weight must be a whole number 1-10000/, 'cpu_weight 0');
refuses(sub { $_[0]{cpu_weight} = 10001 }, qr/cpu_weight must be/, 'cpu_weight too big');
refuses(sub { $_[0]{cpu_max_pct} = 0 }, qr/cpu_max_pct must be a whole number 1-100/, 'cpu_max_pct 0');
refuses(sub { $_[0]{cpu_max_pct} = 101 }, qr/cpu_max_pct must be/, 'cpu_max_pct 101');
refuses(sub { $_[0]{cpu_max_pct} = '50%' }, qr/cpu_max_pct must be/, 'cpu_max_pct with a percent sign');
refuses(sub { $_[0]{io_weight} = 5 }, qr/io_weight must be a whole number 10-1000/, 'io_weight 5');
refuses(sub { $_[0]{mem_hard_limit_mib} = 2048 }, qr/at least memory_mib \+ 128/, 'hard limit = memory');
refuses(sub { $_[0]{mem_hard_limit_mib} = 'x' }, qr/mem_hard_limit_mib must be/, 'hard limit text');
refuses(sub { $_[0]{disks}[0]{iops_max} = 0 }, qr/iops_max must be a whole number/, 'iops 0');
refuses(sub { $_[0]{disks}[0]{mbps_max} = [] }, qr/mbps_max must be a whole number/, 'mbps a list');
refuses(sub { $_[0]{cpu_limit} = 1 }, qr/unknown field 'cpu_limit'/, 'an unknown limit name');

# --- the vm-define arguments --------------------------------------------------------------
{
    my $f = StorageFixture::setup_workload();
    my $d = StorageFixture::base_def();
    @{ $d->{vms}[0] }{qw(cpu_weight cpu_max_pct mem_hard_limit_mib io_weight)} = (50, 50, 2560, 100);
    @{ $d->{vms}[0]{disks}[0] }{qw(iops_max mbps_max)} = (2000, 200);
    StorageFixture::write_def($f, $d);
    my $plan = $f->{wl}->()->plan('create', 't0');
    my ($app) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-app' } @$plan;
    ok($app, 'plan has the vm-define of t0-app') or BAIL_OUT('no vm-define');
    my @a = map {"$_"} @{ $app->{args} };
    my ($i) = grep { $a[$_] eq '--disk' } 0 .. $#a;
    is_deeply([ @a[ $i .. $i + 5 ] ], [ '--disk', '/dev/md/t0-app-root', '--disk-iops', 2000, '--disk-mbps', 200 ],
        'the disk limits follow their --disk') or diag "@a";
    like("@a", qr/--cpu-weight 50 --cpu-max-pct 50 --mem-hard-limit 2560 --io-weight 100\z/, 'the VM limits close the call');
    my ($db) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-db' } @$plan;
    unlike("@{ $db->{args} }", qr/--cpu-|--mem-hard|--io-weight|--disk-iops|--disk-mbps/,
        'a VM without limits gets none (vm-define writes its defaults; the recorded create arguments stay as they were)');
}

# --- cluster keys ---------------------------------------------------------------------------
{
    my %q = map { $_->{key} => $_ } HPS::ClusterConfig::questions();
    is($q{host_reserve_cpus}{default}, '', 'host_reserve_cpus: empty default (sized from the host)');
    is($q{host_reserve_mem_mib}{default}, '', 'host_reserve_mem_mib: empty default (sized from the host)');
    is($q{zfs_arc_max_pct}{default}, '25', 'zfs_arc_max_pct: default 25');
    my $v = sub { HPS::ClusterConfig::validate_value($q{ $_[0] }, $_[1]) };
    ok(!defined $v->(host_reserve_cpus => ''), 'host_reserve_cpus empty');
    ok(!defined $v->(host_reserve_cpus => '0'), 'host_reserve_cpus 0 (none kept)');
    ok(!defined $v->(host_reserve_cpus => '4'), 'host_reserve_cpus 4');
    ok(defined $v->(host_reserve_cpus => '-1'), 'host_reserve_cpus -1 refused');
    ok(defined $v->(host_reserve_cpus => 'two'), 'host_reserve_cpus text refused');
    ok(!defined $v->(host_reserve_mem_mib => '4096'), 'host_reserve_mem_mib 4096');
    ok(defined $v->(host_reserve_mem_mib => '100'), 'host_reserve_mem_mib below 256 refused');
    ok(!defined $v->(zfs_arc_max_pct => '50'), 'zfs_arc_max_pct 50');
    ok(defined $v->(zfs_arc_max_pct => '0'), 'zfs_arc_max_pct 0 refused');
    ok(defined $v->(zfs_arc_max_pct => '95'), 'zfs_arc_max_pct 95 refused');
}

# --- hps-node resources -----------------------------------------------------------------------
{
    my $f = StorageFixture::setup();
    my $n = HPS::Node->new(host => 'sch-001', registry => $f->{reg}, storage => $f->{mk}->(), runner => $f->{ce},
        logger => sub { });
    my $r = $n->resources;
    is($r->{rc}, 0, 'resources: 0');
    is_deeply([ map { join ' ', $_->{script}, @{ $_->{args} } } $f->{ce}->calls ], ['host-resources'],
        'resources: one call of host-resources, no arguments');
    is($r->{stdout}, "out of host-resources\n", 'resources: the node output kept');
}
{
    my $f   = StorageFixture::setup();
    my $tmp = tempdir(CLEANUP => 1);
    StorageFixture::write_hps_run_shim("$tmp/hps-run");
    local $ENV{HPS_CONFIG_BASE}     = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    local $ENV{HPS_RUN_CMD}         = "$tmp/hps-run";
    local $ENV{HPS_NODE_NO_SYSLOG}  = 1;
    local $ENV{SHIM_DIR}            = $tmp;
    my $cli = sub {
        my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-node", @_);
        my $out = qx(@cmd 2>$tmp/stderr);
        return ($? >> 8, $out);
    };
    my ($rc, $out) = $cli->('resources');
    is($rc, 2, 'CLI resources: no host: usage');
    ($rc) = $cli->('resources', 'sch-001', 'extra');
    is($rc, 2, 'CLI resources: two hosts: usage');
    ($rc) = $cli->('resources', 'nosuch');
    is($rc, 4, 'CLI resources: unknown host: not found');
    ($rc, $out) = $cli->('resources', 'sch-001');
    is($rc, 0, 'CLI resources: 0');
    is($out, "node says hi\n", 'CLI resources prints the node output');
    open(my $fh, '<', "$tmp/args") or die;
    like(do { local $/; <$fh> }, qr/ host-resources\s*$/m, 'CLI resources runs host-resources');
}

done_testing;
