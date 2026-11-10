#!/usr/bin/env perl
# CS-3.6: the workload-destroy approval action and hps-approve workload-destroy.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;

$StorageFixture::NOW = time;
my $f   = StorageFixture::setup();
my $mac = $StorageFixture::MAC;
sub err_of { my ($c) = @_; eval { $c->(); 1 } and return undef; return $@ }

ok((grep { $_ eq 'workload-destroy' } HPS::Approval::actions()), 'workload-destroy is an action');
my $doc = StorageFixture::approve($f, 'workload-destroy', pool => 't0');
my $v = $f->{ap}->verify($doc, $f->{ks}->cluster_secret('approval'));
is($v->{pool}, 't0', 'the pool member carries the workload name');
is_deeply($v->{disks}, [], 'no disks');
is($f->{ap}->get($mac, 'workload-destroy', 't0'), $doc, 'stored under approval_workload-destroy_t0');
is(HPS::Approval::registry_key('workload-destroy', 't0'), 'approval_workload-destroy_t0', 'registry key');
for my $case (
    [ { disks => ['ata-X'] }, 'disks' ], [ { wipe => 1 }, 'wipe' ], [ { pool => 'a b' }, 'bad name' ],
) {
    my $e = err_of(sub { StorageFixture::approve($f, 'workload-destroy', pool => 't0', %{ $case->[0] }) });
    is(ref $e && $e->kind, 'usage', "refused: $case->[1]");
}

# hps-approve
my $tmp = tempdir(CLEANUP => 1);
local $ENV{HPS_CONFIG_BASE}     = $f->{base};
local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
local $ENV{SUDO_USER}           = 'tester';
sub cli {
    my @cmd = ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-approve", @_);
    my $out = qx(@cmd 2>&1);
    return ($? >> 8, $out);
}
my ($rc, $out) = cli('workload-destroy', $mac, '--workload', 'odoo-test', '--expires', '600');
is($rc, 0, 'hps-approve workload-destroy exits 0') or diag $out;
like($out, qr/Approved workload-destroy for host $mac\n  Pool:    odoo-test/, 'prints the approval');
ok($f->{ap}->get($mac, 'workload-destroy', 'odoo-test'), 'stored (no cluster-name rule for a workload)');
($rc) = cli('workload-destroy', $mac);
is($rc, 2, 'no --workload: usage');
($rc) = cli('workload-destroy', $mac, '--workload', 'x', '--pool', 'y');
is($rc, 2, '--pool with workload-destroy: usage');
($rc) = cli('pool-destroy', $mac, '--pool', 'lab', '--workload', 'x');
is($rc, 2, '--workload with another action: usage');
($rc) = cli('workload-destroy', '525400000099', '--workload', 'x');
is($rc, 4, 'unknown host: not found');
($rc, $out) = cli('revoke', $mac, 'workload-destroy', 'odoo-test');
is($rc, 0, 'revoke works for the action');

done_testing;
