#!/usr/bin/env perl
# Scale test probes: a VM's cloud-init NoCloud seed. The definition loader
# checks it (strings only, size limits); create runs vm-seed-write right after
# vm-image-write with the seed as the run's input (never an argument), under
# the resume key seed:<vm>; status says when the definition's seed is not the
# one written at create.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload;

sub err_of {
    my ($code) = @_;
    return eval { $code->(); 1 } ? undef : $@;
}

my $SEED = { user_data => "#cloud-config\nhostname: p1\n", network_config => "version: 2\n" };

sub def_with {
    my (%seed) = @_;
    my $d = StorageFixture::base_def();
    $d->{vms}[0]{seed} = {%seed};
    return $d;
}

sub refused_like {
    my ($def, $re, $what) = @_;
    my $e = err_of(sub { HPS::Workload::validate($def, layout => StorageFixture::layout()) });
    ok($e && $e->kind eq 'refused', "$what: refused") or diag explain $e;
    like($e ? $e->message : '', $re, "$what: says why");
    return;
}

#--- the loader
{
    my $v = HPS::Workload::validate(def_with(%$SEED), layout => StorageFixture::layout());
    is_deeply($v->{vms}[0]{seed}, $SEED, 'a seed of strings is kept as it is');
    ok(!exists $v->{vms}[1]{seed}, 'a VM without a seed has none');
    $v = HPS::Workload::validate(def_with(user_data => "#cloud-config\n"), layout => StorageFixture::layout());
    is_deeply($v->{vms}[0]{seed}, { user_data => "#cloud-config\n" }, 'user_data alone is enough');

    refused_like(do { my $d = StorageFixture::base_def(); $d->{vms}[0]{seed} = 'x'; $d }, qr/seed: must be an object/, 'a seed that is not an object');
    refused_like(def_with(network_config => 'x'), qr/user_data is required/, 'no user_data');
    refused_like(def_with(user_data => ''), qr/user_data must not be empty/, 'an empty user_data');
    refused_like(def_with(user_data => 'x', vendor_data => 'y'), qr/unknown field 'vendor_data'/, 'an unknown field');
    refused_like(def_with(user_data => 5), qr/user_data must be a string/, 'a number');
    refused_like(def_with(user_data => 'x', network_config => JSON::PP::true), qr/network_config must be a string/, 'a boolean');
    refused_like(def_with(user_data => 'x', meta_data => undef), qr/meta_data must be a string/, 'a null');
    refused_like(def_with(user_data => ['x']), qr/user_data must be a string/, 'a list');
    refused_like(def_with(user_data => "a\0b"), qr/NUL/, 'a NUL character');
    refused_like(def_with(user_data => 'x' x (64 * 1024 + 1)), qr/user_data is 65537 bytes; at most 65536/, 'user_data over 64 KiB');
    refused_like(def_with(user_data => 'x', network_config => 'x' x (16 * 1024 + 1)), qr/network_config is 16385 bytes/, 'network_config over 16 KiB');
    refused_like(def_with(user_data => 'x', meta_data => 'x' x (4 * 1024 + 1)), qr/meta_data is 4097 bytes/, 'meta_data over 4 KiB');
    refused_like(def_with(user_data => "\x{e9}" x (32 * 1024 + 1)), qr/user_data is 65538 bytes/, 'the limit counts UTF-8 bytes');
    my $nb = { name => 'n1', project => 'lab', vms => [ { name => 'n1-a', memory_mib => 512, vcpus => 1, boot => 'network',
        compute_host => 'sch-001', nets => ['mgmt'], seed => { user_data => 'x' } } ] };
    refused_like($nb, qr/a network-boot VM has no seed/, 'a seed on a network-boot VM');

    my $text = JSON::PP->new->encode({ %{ def_with(user_data => 5) }, name => 't0' });
    my $f = StorageFixture::setup_workload(no_def => 1);
    my $e = err_of(sub { $f->{wl}->()->define('t0', $text) });
    ok($e && $e->kind eq 'refused', 'define refuses a bad seed too (the one check)');
}

#--- create: the step, its input, the record
{
    my $f = StorageFixture::setup_workload(no_def => 1);
    StorageFixture::write_def($f, def_with(%$SEED));
    my $wl = $f->{wl}->();
    my $plan = $wl->plan('create', 't0');
    my @scripts = map { $_->{script} } @$plan;
    my ($iw) = grep { $scripts[$_] eq 'vm-image-write' } 0 .. $#scripts;
    is($scripts[ $iw + 1 ], 'vm-seed-write', 'vm-seed-write comes right after the VM\'s vm-image-write');
    is(scalar(grep { $_ eq 'vm-seed-write' } @scripts), 1, 'only the VM with a seed gets one');
    my ($sp) = grep { $_->{script} eq 'vm-seed-write' } @$plan;
    is_deeply($sp->{args}, [ 't0-app', '--disk', '/dev/md/t0-app-root' ], 'vm-seed-write <vm> --disk <boot disk>');
    like($sp->{input}, qr/^<seed: user_data 27 bytes, network_config 11 bytes, meta_data default \(instance-id and local-hostname t0-app\); sha256 [0-9a-f]{64}>$/,
        'the plan shows the seed sizes, never the text');
    unlike(join(' ', @{ $sp->{args} }), qr/cloud-config/, 'the seed is never an argument');

    my $r = $wl->run('create', 't0');
    ok($r->{ok}, 'create ok');
    my ($call) = grep { $_->{script} eq 'vm-seed-write' } $f->{ce}->calls;
    is_deeply(decode_json($call->{input}), $SEED, 'the node gets the seed as the run input');
    ok(!grep({ $_->{script} ne 'vm-seed-write' && defined $_->{input} } $f->{ce}->calls), 'no other node call has an input');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t0');
    like($rec->{vms}{'t0-app'}{seed_sha256}, qr/^[0-9a-f]{64}$/, 'create records the sha256 of the seed written');
    ok(!exists $rec->{vms}{'t0-db'}{seed_sha256}, 'none for the VM without a seed');
    ok(!grep({ /cloud-config/ } @{ $f->{log} }), 'the seed text is never logged');

    # status: as written, then changed in the definition.
    my $st = $wl->run('status', 't0');
    my ($app) = grep { $_->{vm} eq 't0-app' } @{ $st->{vms} };
    my ($db) = grep { $_->{vm} eq 't0-db' } @{ $st->{vms} };
    is($app->{seed}, 'as written', 'status: the seed is the one written');
    ok(!exists $db->{seed}, 'status: nothing for a VM that never had a seed');
    StorageFixture::write_def($f, def_with(user_data => "#cloud-config\nhostname: p2\n"));
    $st = $f->{wl}->()->run('status', 't0');
    ($app) = grep { $_->{vm} eq 't0-app' } @{ $st->{vms} };
    like($app->{seed}, qr/changed since create \(destroy and create to apply it\)/, 'status: a changed seed needs a re-create');
}

#--- resume: a create that failed at vm-seed-write runs it again, not vm-image-write
{
    my $f = StorageFixture::setup_workload(no_def => 1, ce => { rc => { 'vm-seed-write' => [ 1, 0 ] } });
    StorageFixture::write_def($f, def_with(%$SEED));
    my $wl = $f->{wl}->();
    my $e = err_of(sub { $wl->run('create', 't0') });
    ok($e, 'create stops at the failing vm-seed-write');
    like($e->message, qr/vm-seed-write exited 1/, 'and says so');
    my $rec = $f->{reg}->cluster_get_json('lab', 'workload_t0');
    is($rec->{state}, 'creating', 'the workload stays creating');
    is($rec->{attempting}, 'seed:t0-app', 'the record names the step it was on');
    ok((grep { $_ eq 'write:t0-app' } @{ $rec->{done} }), 'vm-image-write is done');
    $f->{ce}{calls} = [];
    my $r = $wl->run('create', 't0', resume => 1);
    ok($r->{ok}, 'create --resume finishes');
    my @run = grep { !$_->{skipped} } @{ $r->{steps} };
    ok(!grep({ $_->{script} eq 'vm-image-write' && $_->{args}[0] eq 't0-app' } @run), 'resume does not write the image again');
    is(scalar(grep { $_->{script} eq 'vm-seed-write' } @run), 1, 'resume runs vm-seed-write');
    ok((grep { $_->{script} eq 'vm-seed-write' && defined $_->{input} } $f->{ce}->calls), 'with the seed as input');
}

#--- no seed: no step, plan unchanged
{
    my $f = StorageFixture::setup_workload();
    my @scripts = map { $_->{script} } @{ $f->{wl}->()->plan('create', 't0') };
    ok(!grep({ $_ eq 'vm-seed-write' } @scripts), 'a definition without seeds has no vm-seed-write');
}

done_testing;
