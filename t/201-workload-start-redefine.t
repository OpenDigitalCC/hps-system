#!/usr/bin/env perl
# start after the compute host rebooted: the node runs from RAM, so libvirt's VM
# definitions are gone while the zvols and legs survive. start checks each VM
# with vm-status; one that is not defined (exit 4) is re-defined with create's
# vm-define arguments and the recorded MACs (no zvol create, no image write),
# then started. A definition edited since create refuses the re-define.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

my $DB = 'lab/enc/vm/t0-t0-db-root';
my @DB_MACS = ('52:54:00:aa:00:01', '52:54:00:aa:00:02');

sub err_of { my ($code) = @_; eval { $code->(); 1 } and return undef; return $@ }
sub rec { my ($f) = @_; return $f->{reg}->cluster_get_json('lab', 'workload_t0') }
sub set_rec { my ($f, $cb) = @_; my $r = rec($f); $cb->($r); $f->{reg}->cluster_set('lab', 'workload_t0', $r); return }
sub calls { my ($f) = @_; return [ map { [ $_->{script}, @{ $_->{args} } ] } $f->{ce}->calls ] }

# A created and running workload whose t0-db has recorded MACs.
sub created {
    my $f = StorageFixture::setup_workload();
    my $wl = $f->{wl}->();
    $wl->run('create', 't0');
    set_rec($f, sub { $_[0]{vms}{'t0-db'}{macs} = [@DB_MACS] });
    $f->{ce}{calls} = [];
    return ($f, $wl);
}

#--- create keeps the vm-define arguments in the record
{
    my ($f) = created();
    is_deeply(rec($f)->{vms}{'t0-db'}{define},
        [ 't0-db', '--memory', '4096', '--vcpus', '4', '--disk', '/dev/md/t0-db-root', '--net', 'br-mgmt', '--net', 'br-db',
          '--image', '/lab/enc/images/debian-13-generic-amd64.qcow2' ],
        'create records the vm-define arguments it used');
}

#--- a VM the host no longer has: re-defined with the recorded MACs, then started
{
    my ($f, $wl) = created();
    my $create_args = rec($f)->{vms}{'t0-db'}{define};
    $f->{ce}{rc}{'vm-status'} = 4;
    my $r = $wl->run('start', 't0', vm => 't0-db');
    ok($r->{ok}, 'start ok');
    is_deeply(calls($f), [
        [ 'mirror-assemble', 't0-db-root', '--leg', "local:$DB", '--leg', 'iscsi:192.0.2.50:iqn.2026-01.lab.nas:hpslab-t0-db' ],
        [ 'vm-status', 't0-db' ],
        [ 'vm-define', 't0-db', '--memory', 4096, '--vcpus', 4, '--disk', '/dev/md/t0-db-root',
          '--net', 'br-mgmt', '--mac', $DB_MACS[0], '--net', 'br-db', '--mac', $DB_MACS[1],
          '--image', '/lab/enc/images/debian-13-generic-amd64.qcow2' ],
        [ 'vm-start', 't0-db', '--priority', 1 ] ],
        'mirror assembled, VM found missing, re-defined with the recorded MACs, started') or diag explain calls($f);
    my ($def) = grep { $_->{script} eq 'vm-define' } $f->{ce}->calls;
    is_deeply([ grep { $_ ne '--mac' && !/^52:54/ } @{ $def->{args} } ], $create_args, "the re-define is create's vm-define plus --mac");
    ok(!grep({ $_->{script} =~ /zvol-create|image-fetch|vm-image-write|mirror-create/ } $f->{ce}->calls),
        'no zvol create, image fetch, image write or mirror create');
    is(rec($f)->{vms}{'t0-db'}{state}, 'running', 'registry: running');
    is_deeply(rec($f)->{vms}{'t0-db'}{macs}, \@DB_MACS, 'registry: the MACs are unchanged');
    my @steps = map { [ $_->{script}, $_->{skipped} ? 1 : 0 ] } @{ $r->{steps} };
    is_deeply(\@steps, [ [ 'mirror-assemble', 0 ], [ 'vm-status', 0 ], [ 'vm-define', 0 ], [ 'vm-start', 0 ] ],
        'the re-define is a step of the run');
    ok((grep { /re-defining it from the definition and the record/ } @{ $f->{log} }), 'the re-define is logged');
}

#--- no MACs recorded (a disk-boot VM created before MACs were kept): libvirt's new
#    ones are read back and recorded
{
    my ($f, $wl) = created();
    $f->{ce}{rc}{'vm-status'} = [ 4, 0 ];
    $f->{ce}{out}{'vm-status'} = "NIC t0-app 0 vnet3 br-mgmt 52:54:00:cc:00:07 vlans=-\nVM t0-app shut off\n";
    $wl->run('start', 't0', vm => 't0-app');
    is_deeply([ map { $_->[0] } @{ calls($f) } ], [ 'mirror-assemble', 'vm-status', 'vm-define', 'vm-status', 'vm-start' ],
        'missing, re-defined, read back, started');
    my ($def) = grep { $_->{script} eq 'vm-define' } $f->{ce}->calls;
    ok(!grep({ $_ eq '--mac' } @{ $def->{args} }), 'no --mac when none is recorded');
    is_deeply(rec($f)->{vms}{'t0-app'}{macs}, ['52:54:00:cc:00:07'], 'the new MAC is recorded for the next re-define');
}

#--- a VM still defined is started as before; its MACs are recorded when missing
{
    my ($f, $wl) = created();
    $f->{ce}{out}{'vm-status'} = "NIC t0-app 0 vnet0 br-mgmt 52:54:00:bb:00:01 vlans=-\nVM t0-app shut off\n";
    $wl->run('start', 't0', vm => 't0-app');
    is_deeply([ map { $_->[0] } @{ calls($f) } ], [ 'mirror-assemble', 'vm-status', 'vm-start' ], 'defined: no re-define');
    is_deeply(rec($f)->{vms}{'t0-app'}{macs}, ['52:54:00:bb:00:01'], "vm-status's MACs recorded");
    $f->{ce}{calls} = [];
    $wl->run('start', 't0', vm => 't0-db');
    is_deeply(rec($f)->{vms}{'t0-db'}{macs}, \@DB_MACS, 'recorded MACs are never overwritten by vm-status');
}

#--- the definition was edited since create: the re-define is refused, a defined VM still starts
{
    my ($f, $wl) = created();
    my $d = $f->{def};
    $d->{vms}[1]{memory_mib} = 8192;
    StorageFixture::write_def($f, $d);
    $f->{ce}{rc}{'vm-status'} = 4;
    my $e = err_of(sub { $wl->run('start', 't0', vm => 't0-db') });
    is($e && $e->kind, 'refused', 'edited definition, VM missing: refused');
    like($e->message, qr/VM t0-db is not defined on its compute host and cannot be re-defined: its vm-define arguments differ from the ones create used.*--memory 4096.*--memory 8192/,
        'says why, with both argument lists');
    like($e->message, qr/Put back the definition it was created with, or destroy and create the workload/, 'says what to do');
    ok(!grep({ $_->{script} =~ /vm-define|vm-start/ } $f->{ce}->calls), 'nothing defined or started');
    $f->{ce}{calls} = [];
    delete $f->{ce}{rc}{'vm-status'};
    ok($wl->run('start', 't0', vm => 't0-db')->{ok}, 'edited definition, VM defined: started as before');
}

#--- a record made before create kept its arguments: host, disks, legs, MAC count still compared
{
    my ($f, $wl) = created();
    set_rec($f, sub { delete $_[0]{vms}{'t0-db'}{define} });
    my $d = $f->{def};
    $d->{vms}[1]{disks}[0]{legs}[1]{portal} = '192.0.2.99';
    StorageFixture::write_def($f, $d);
    $f->{ce}{rc}{'vm-status'} = 4;
    my $e = err_of(sub { $wl->run('start', 't0', vm => 't0-db') });
    like($e && $e->message, qr/disk 'root': the record has legs .*192\.0\.2\.50.*, the definition .*192\.0\.2\.99/, 'a changed leg: refused');
    $d->{vms}[1]{disks}[0]{legs}[1]{portal} = '192.0.2.50';
    $d->{vms}[1]{nets} = ['mgmt'];
    StorageFixture::write_def($f, $d);
    $e = err_of(sub { $wl->run('start', 't0', vm => 't0-db') });
    like($e && $e->message, qr/the record has 2 MAC\(s\), the definition 1 NIC\(s\)/, 'a NIC removed: refused');
    $d->{vms}[1]{nets} = [ 'mgmt', 'db' ];
    StorageFixture::write_def($f, $d);
    ok($wl->run('start', 't0', vm => 't0-db')->{ok}, 'definition put back: re-defined and started');
}

#--- dry run lists the conditional re-define
{
    my ($f, $wl) = created();
    my $r = $wl->run('start', 't0', vm => 't0-db', dry_run => 1);
    my @p = @{ $r->{plan} };
    is_deeply([ map { $_->{script} } @p ], [ 'mirror-assemble', 'vm-status', 'vm-define', 'vm-start' ], 'dry run: the re-define is listed');
    like($p[2]{only}, qr/only if vm-status reports t0-db not defined.*with the recorded MACs/, 'dry run: when it runs');
    ok(grep({ $_ eq '--mac' } @{ $p[2]{args} }), 'dry run: with --mac');
    is(scalar $f->{ce}->calls, 0, 'dry run sends nothing');
    my $d = $f->{def};
    $d->{vms}[1]{vcpus} = 8;
    StorageFixture::write_def($f, $d);
    $r = $wl->run('start', 't0', vm => 't0-db', dry_run => 1);
    like($r->{plan}[2]{only}, qr/refused then: its vm-define arguments differ/, 'dry run: an impossible re-define says so');
}

#--- the CLI shows it in --dry-run
{
    my ($f) = created();
    local $ENV{HPS_CONFIG_BASE}        = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY}    = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES}          = $f->{base};
    local $ENV{HPS_WORKLOAD_NO_SYSLOG} = 1;
    my $out = qx($^X -I$Bin/../lib/perl $Bin/../bin/hps-workload start t0 --vm t0-db --dry-run 2>&1);
    is($? >> 8, 0, 'cli start --dry-run: 0');
    like($out, qr/3\. \[\S+\] vm-define t0-db .*--mac 52:54:00:aa:00:01.*\n\s+only if vm-status reports t0-db not defined/,
        'cli dry run prints the re-define and when it runs');
}

done_testing;
