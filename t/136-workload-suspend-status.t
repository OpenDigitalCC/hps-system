#!/usr/bin/env perl
# A suspended workload: status (text and --json), destroy removing the state
# file, and the CLI verbs.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }
sub calls { my ($f) = @_; return [ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ] }

$StorageFixture::NOW = time;
my $f = StorageFixture::setup_workload(ce => { out => {
    'vm-save' => "VM-SAVE x y 8589934592\n", 'vm-status' => "VM t0 shut off\n" } });
my $wl = $f->{wl}->();
$wl->run('create', 't0');
$wl->run('start', 't0');
$wl->run('suspend', 't0', vm => 't0-db');

#--- status
{
    $f->{ce}{calls} = [];
    my $r = $wl->run('status', 't0');
    my ($db) = grep { $_->{vm} eq 't0-db' } @{ $r->{vms} };
    is($db->{recorded_state}, 'suspended', 'status: recorded suspended');
    is($db->{state_file}, '/lab/enc/state/t0-db.save', 'status: state_file');
    is($db->{size_bytes}, 8589934592, 'status: size_bytes');
    ok(defined $db->{saved_at}, 'status: saved_at');
    is($r->{state}, 'partial', 'status: workload state');
    my ($app) = grep { $_->{vm} eq 't0-app' } @{ $r->{vms} };
    ok(!exists $app->{state_file}, 'a running VM carries no state_file');
    is_deeply([ sort keys %$app ], [ sort qw(vm host recorded_state state mirrors ok utilisation utilisation_reason addresses) ],
        'the other fields are as before') or diag join ',', sort keys %$app;
}

#--- destroy removes the state file after stopping and undefining the VM
{
    $f->{ce}{calls} = [];
    my $p = $wl->plan('destroy', 't0');
    my @s = map { join ' ', $_->{script}, @{ $_->{args} } } @$p;
    ok((grep { $_ eq 'vm-save t0-db --state /lab/enc/state/t0-db.save --discard' } @s), 'destroy plan: vm-save --discard of the suspended VM');
    ok(!(grep { /^vm-save t0-app/ } @s), 'not for the running one');
    my ($i_undef) = grep { $s[$_] eq 'vm-undefine t0-db' } 0 .. $#s;
    my ($i_disc)  = grep { $s[$_] =~ /--discard/ } 0 .. $#s;
    my ($i_zvol)  = grep { $s[$_] =~ /^storage-zvol-destroy/ } 0 .. $#s;
    ok($i_undef < $i_disc && $i_disc < $i_zvol, 'after vm-undefine, before the zvols go');
    $wl->run('destroy', 't0');
    ok((grep { $_->[0] eq 'vm-save' && $_->[-1] eq '--discard' } @{ calls($f) }), 'destroy ran it');
    ok(!$f->{reg}->cluster_exists('lab', 'workload_t0'), 'record removed');
}

#--- the CLI
{
    my $g = StorageFixture::setup_workload();
    my $tmp = tempdir(CLEANUP => 1);
    my $out = `$^X $Bin/../bin/hps-workload suspend 2>&1`;
    isnt($? >> 8, 0, 'suspend without a name: not 0');
    like($out, qr/hps-workload suspend <name> \[--vm <vm>\]/, 'usage names suspend');
    like($out, qr/hps-workload resume  <name> \[--vm <vm>\]/, 'usage names resume');
    $out = `$^X $Bin/../bin/hps-workload resume t0 --force 2>&1`;
    like($out, qr/--force is only for stop/, '--force is for stop only');
}

done_testing;
