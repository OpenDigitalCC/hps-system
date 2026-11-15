#!/usr/bin/env perl
# Storage faults (docs/STORAGE-FAULTS.md): the four cluster keys (catalogue,
# validation, registry key table) and the vm-define argument that
# vm_disk_error_policy adds only when it is not the default.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;
use HPS::ClusterConfig;
use HPS::Registry::Keys;

# --- catalogue and validation ---------------------------------------------------------------
{
    my %q = map { $_->{key} => $_ } HPS::ClusterConfig::questions();
    is($q{vm_disk_error_policy}{default}, 'stop', 'vm_disk_error_policy: default stop');
    is($q{iscsi_max_sectors_kb}{default}, '256', 'iscsi_max_sectors_kb: default 256');
    is($q{iscsi_replacement_timeout}{default}, '15', 'iscsi_replacement_timeout: default 15 (the 2026-11-12 ruling)');
    is($q{storage_min_free_pct}{default}, '2', 'storage_min_free_pct: default 2');
    my $v = sub { HPS::ClusterConfig::validate_value($q{ $_[0] }, $_[1]) };
    ok(!defined $v->(vm_disk_error_policy => 'stop'), 'policy stop');
    ok(!defined $v->(vm_disk_error_policy => 'report'), 'policy report');
    ok(defined $v->(vm_disk_error_policy => 'ignore'), 'policy ignore refused');
    ok(!defined $v->(iscsi_max_sectors_kb => '0'), 'max_sectors_kb 0 (kernel limit)');
    ok(!defined $v->(iscsi_max_sectors_kb => '64'), 'max_sectors_kb 64');
    ok(!defined $v->(iscsi_max_sectors_kb => '4096'), 'max_sectors_kb 4096');
    ok(defined $v->(iscsi_max_sectors_kb => '32'), 'max_sectors_kb 32 refused');
    ok(defined $v->(iscsi_max_sectors_kb => '4097'), 'max_sectors_kb 4097 refused');
    ok(!defined $v->(iscsi_replacement_timeout => '5'), 'replacement_timeout 5');
    ok(!defined $v->(iscsi_replacement_timeout => '600'), 'replacement_timeout 600');
    ok(defined $v->(iscsi_replacement_timeout => '4'), 'replacement_timeout 4 refused');
    ok(defined $v->(iscsi_replacement_timeout => '0'), 'replacement_timeout 0 refused');
    ok(defined $v->(iscsi_replacement_timeout => '601'), 'replacement_timeout 601 refused');
    ok(!defined $v->(storage_min_free_pct => '0'), 'min_free_pct 0 (kernel value)');
    ok(!defined $v->(storage_min_free_pct => '10'), 'min_free_pct 10');
    ok(defined $v->(storage_min_free_pct => '11'), 'min_free_pct 11 refused');
}

# --- the registry key table -----------------------------------------------------------------
{
    my %have = map { $_->{name} => $_ } HPS::Registry::Keys::keys_table();
    for my $k (qw(vm_disk_error_policy iscsi_max_sectors_kb iscsi_replacement_timeout storage_min_free_pct)) {
        ok($have{$k}, "$k is in the registry key table");
        is($have{$k}{scope}, 'cluster', "$k: cluster scope");
    }
}

# --- the vm-define arguments ----------------------------------------------------------------
{
    my $f = StorageFixture::setup_workload();
    StorageFixture::write_def($f, StorageFixture::base_def());
    my $define = sub {
        my $plan = $f->{wl}->()->plan('create', 't0');
        my ($app) = grep { $_->{script} eq 'vm-define' && $_->{args}[0] eq 't0-app' } @$plan;
        return $app ? join(' ', @{ $app->{args} }) : undef;
    };
    my $none = $define->();
    ok(defined $none, 'plan has the vm-define of t0-app') or BAIL_OUT('no vm-define');
    unlike($none, qr/--disk-error-policy/, 'key unset: no argument (vm-define defaults to stop)');
    $f->{reg}->cluster_set('lab', 'vm_disk_error_policy', 'stop');
    is($define->(), $none, 'key stop: the argument list is the one without the key');
    $f->{reg}->cluster_set('lab', 'vm_disk_error_policy', 'report');
    is($define->(), "$none --disk-error-policy report", 'key report: --disk-error-policy report, last');
    $f->{reg}->cluster_set('lab', 'vm_disk_error_policy', 'ignore');
    my $e = eval { $define->(); 1 } ? undef : $@;
    ok(defined $e && ref $e, 'key ignore: refused');
    like(ref $e ? $e->message : '', qr/vm_disk_error_policy is 'ignore'; it must be stop or report/, 'reason named');
}

done_testing;
