#!/usr/bin/env perl
# hps-workload suspend / resume: the node calls (vm-save, then on resume what
# start does before vm-start, then vm-restore), the recorded state, --vm and
# --dry-run.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my @DB_MACS = ('52:54:00:aa:00:01', '52:54:00:aa:00:02');
my $DBFILE  = '/lab/enc/state/t0-db.save';
my $APPFILE = '/lab/enc/state/t0-app.save';

sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }
sub set_rec { my ($f, $cb) = @_; my $r = rec($f); $cb->($r); $f->{reg}->cluster_set('lab', 'workload_t0', $r); return }
sub calls { my ($f) = @_; return [ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ] }

sub running {
    my %o = @_;
    my $f = StorageFixture::setup_workload(ce => { out => { 'vm-save' => "VM-SAVE x y 4294967296\n" }, %{ $o{ce} // {} } });
    my $wl = $f->{wl}->();
    $wl->run('create', 't0');
    set_rec($f, sub { $_[0]{vms}{'t0-db'}{macs} = [@DB_MACS] });
    $wl->run('start', 't0');
    $f->{ce}{calls} = [];
    return ($f, $wl);
}

ok(scalar(grep { $_ eq 'suspend' } HPS::Workload::ops()), 'suspend is an op');
ok(scalar(grep { $_ eq 'resume' } HPS::Workload::ops()), 'resume is an op');

#--- dry run changes and sends nothing
{
    my ($f, $wl) = running();
    my $r = $wl->run('suspend', 't0', dry_run => 1);
    ok($r->{dry_run}, 'suspend --dry-run');
    is_deeply([ map { [ $_->{script}, @{ $_->{args} } ] } @{ $r->{plan} } ],
        [ [ 'vm-save', 't0-app', '--state', $APPFILE ], [ 'vm-save', 't0-db', '--state', $DBFILE ] ],
        'one vm-save per VM, stop order (priority 3 before 1), the state file on the pool');
    is(scalar(() = $f->{ce}->calls), 0, 'nothing sent');
    is(rec($f)->{vms}{'t0-db'}{state}, 'running', 'record unchanged');
}

#--- suspend: vm-save only; the record says suspended
{
    my ($f, $wl) = running();
    my $r = $wl->run('suspend', 't0', vm => 't0-db');
    ok($r->{ok}, 'suspend --vm ok');
    is_deeply(calls($f), [ [ 'vm-save', 't0-db', '--state', $DBFILE ] ], 'only vm-save of that VM: no mirror-stop, no vm-stop') or diag explain calls($f);
    my $v = rec($f)->{vms}{'t0-db'};
    is($v->{state}, 'suspended', 'recorded suspended');
    is($v->{state_file}, $DBFILE, 'with the state file');
    is($v->{size_bytes}, 4294967296, 'and the size vm-save reported');
    like($v->{saved_at}, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d UTC$/, 'and when');
    is(rec($f)->{vms}{'t0-app'}{state}, 'running', 'the other VM is untouched');
    is(rec($f)->{state}, 'partial', 'the workload is partial');
    $wl->run('suspend', 't0', vm => 't0-app');
    is(rec($f)->{state}, 'suspended', 'every VM suspended: the workload is suspended');
}

#--- resume: start's preparation, then vm-restore; the record is running again
{
    my ($f, $wl) = running();
    $wl->run('suspend', 't0', vm => 't0-db');
    $f->{ce}{calls} = [];
    my $r = $wl->plan('resume', 't0', vm => 't0-db');
    is_deeply([ map { $_->{script} } @$r ], [ 'mirror-assemble', 'vm-status', 'vm-define', 'vm-restore' ],
        'plan: mirror-assemble, vm-status, vm-define (only if missing), vm-restore');
    like($r->[2]{only}, qr/only if vm-status reports t0-db not defined/, 'the define is conditional');
    $r = $wl->run('resume', 't0', vm => 't0-db');
    ok($r->{ok}, 'resume ok');
    is_deeply(calls($f), [
        [ 'mirror-assemble', 't0-db-root', '--leg', 'local:lab/enc/vm/t0-t0-db-root', '--leg', 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-db' ],
        [ 'vm-status', 't0-db' ],
        [ 'vm-restore', 't0-db', '--state', $DBFILE ] ], 'defined VM: mirror assembled, status, restore') or diag explain calls($f);
    my $v = rec($f)->{vms}{'t0-db'};
    is($v->{state}, 'running', 'recorded running');
    ok(!exists $v->{state_file} && !exists $v->{saved_at} && !exists $v->{size_bytes}, 'the saved-state fields are gone');
    is(rec($f)->{state}, 'running', 'the workload is running again');
}

#--- resume after the host rebooted: the definition is put back first, with the recorded MACs
{
    my ($f, $wl) = running();
    $wl->run('suspend', 't0', vm => 't0-db');
    $f->{ce}{calls} = [];
    $f->{ce}{rc}{'vm-status'} = 4;
    $wl->run('resume', 't0', vm => 't0-db');
    is_deeply([ map { $_->[0] } @{ calls($f) } ], [ 'mirror-assemble', 'vm-status', 'vm-define', 'vm-restore' ], 'defined, then restored');
    my ($def) = grep { $_->{script} eq 'vm-define' } $f->{ce}->calls;
    is_deeply([ grep { /^52:54/ } @{ $def->{args} } ], \@DB_MACS, 'with the recorded MACs');
}

#--- a node refusal stops the run and leaves the record
{
    my ($f, $wl) = running(ce => { rc => { 'vm-save' => 3 } });
    my $e = eval { $wl->run('suspend', 't0', vm => 't0-db'); 1 } ? undef : $@;
    is($e && $e->kind, 'refused', 'vm-save exit 3: refused');
    like($e->message, qr/vm-save exited 3/, 'names the step');
    is(rec($f)->{vms}{'t0-db'}{state}, 'running', 'still recorded running');
    $f->{ce}{rc}{'vm-save'} = 0;
    $wl->run('suspend', 't0', vm => 't0-db');
    $f->{ce}{rc}{'vm-restore'} = 3;
    $e = eval { $wl->run('resume', 't0', vm => 't0-db'); 1 } ? undef : $@;
    is($e && $e->kind, 'refused', 'vm-restore exit 3: refused');
    is(rec($f)->{vms}{'t0-db'}{state}, 'suspended', 'still recorded suspended');
}

done_testing;
