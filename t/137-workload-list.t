#!/usr/bin/env perl
# hps-workload list: every workload_<name> record with its project, state,
# hosts, VM count, first address and created_at; --project filters.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Workload::List;

my $f = StorageFixture::setup_workload();
my $reg = $f->{reg};
my $dir = tempdir(CLEANUP => 1);
open(my $lf, '>', "$dir/leases") or die;
print {$lf} "4000000000 52:54:00:aa:00:01 10.0.0.21 alpha-vm *\n";
close $lf;
local $ENV{HPS_DNSMASQ_LEASES} = "$dir/leases";

sub vm { my ($host, $state, $mem, $cpu, @macs) = @_;
    return { host => $host, state => $state, macs => [@macs], disks => {},
        define => [ 'x', '--memory', $mem, '--vcpus', $cpu, '--net', 'br-mgmt' ] } }
$reg->cluster_set('lab', 'workload_alpha', { state => 'running', created_at => '2026-11-12 05:51:36 UTC', by => 'op',
    vms => { 'alpha-vm' => vm('sch-001', 'running', 2048, 2, '52:54:00:aa:00:01') } });
$reg->cluster_set('lab', 'workload_beta', { state => 'partial', created_at => '2026-11-13 08:00:00 UTC', by => 'op',
    vms => { 'beta-1' => vm('sch-001', 'stopped', 1024, 1, '52:54:00:bb:00:01'), 'beta-2' => vm('sch-002', 'running', 1024, 1) } });
$reg->cluster_set('lab', 'workload_gone_destroyed', { at => 'x', by => 'op' });
$reg->cluster_set('lab', 'workload_alpha_destroyed', { at => 'x', by => 'op' });
StorageFixture::write_def($f, { %{ StorageFixture::base_def() }, name => 'alpha', project => 'projA' });
StorageFixture::write_def($f, { %{ StorageFixture::base_def() }, name => 'beta', project => 'projB' });

my $wl = $f->{wl}->();
my $rows = HPS::Workload::List::list($wl);
is_deeply([ map { $_->{name} } @$rows ], [qw(alpha beta)], 'records only, sorted; the _destroyed audit keys are not workloads');
my ($a, $b) = @$rows;
is($a->{project}, 'projA', 'project from the definition');
is($a->{state}, 'running', 'state');
is_deeply($a->{hosts}, ['sch-001'], 'host');
is($a->{vms}, 1, 'VM count');
is($a->{created_at}, '2026-11-12 05:51:36 UTC', 'created_at');
is_deeply($a->{addresses}, [ { vm => 'alpha-vm', net => 'mgmt', mac => '52:54:00:aa:00:01', ip => '10.0.0.21', source => 'dhcp-lease' } ],
    'address from the lease, net named from the layout');
is_deeply($b->{hosts}, [qw(sch-001 sch-002)], 'two compute hosts');
is($b->{vms}, 2, 'two VMs');
is_deeply($b->{addresses}, [], 'no lease: an empty list, nothing invented');

is_deeply([ map { $_->{name} } @{ HPS::Workload::List::list($wl, project => 'projB') } ], ['beta'], '--project filters');
is_deeply(HPS::Workload::List::list($wl, project => 'nobody'), [], 'no match: empty');

unlink "$f->{reg}->workload_dir('lab')/beta.json" if 0;
my $text = HPS::Workload::List::render_list($rows);
like($text, qr/^NAME\s+PROJECT\s+STATE\s+CLASS\s+HOST\s+VMS\s+ADDRESS\s+CREATED$/m, 'text header');
like($text, qr/^alpha\s+projA\s+running\s+3\s+sch-001\s+1\s+10\.0\.0\.21\s+2026-11-12 05:51:36 UTC$/m, 'alpha row');
like($text, qr/^beta\s+projB\s+partial\s+3\s+sch-001,sch-002\s+2\s+-\s+2026-11-13/m, 'beta row, no address is a dash');
is(HPS::Workload::List::render_list([]), "no workloads\n", 'empty');

# a record whose definition is gone: project null, still listed
unlink StorageFixture::write_def($f, { %{ StorageFixture::base_def() }, name => 'beta', project => 'projB' });
$rows = HPS::Workload::List::list($f->{wl}->());
is($rows->[1]{project}, undef, 'definition gone: project null');
like(HPS::Workload::List::render_list($rows), qr/^beta\s+-\s+partial\s+3\s/m, 'and a dash in the table');
is(scalar @{ HPS::Workload::List::list($f->{wl}->(), project => 'projB') }, 0, 'not matched by --project either');

# the CLI
{
    local $ENV{HPS_CONFIG_BASE}     = $f->{base};
    local $ENV{HPS_SYSTEM_REGISTRY} = "$f->{base}/system.db";
    local $ENV{HPS_RESOURCES}       = $f->{base};
    local $ENV{SUDO_USER}           = 'tester';
    my $run = sub { my $q = join ' ', map { "'$_'" } ($^X, "-I$Bin/../lib/perl", "$Bin/../bin/hps-workload", @_); return scalar qx($q 2>&1) };
    my $j = decode_json($run->('list', '--json', '--project', 'projA'));
    is_deeply([ map { $_->{name} } @{ $j->{workloads} } ], ['alpha'], 'cli list --json --project');
    is($j->{workloads}[0]{addresses}[0]{ip}, '10.0.0.21', 'cli: the address');
    like($run->('list'), qr/^alpha\s+projA/m, 'cli list text');
    my $i = decode_json($run->('images', '--json'));
    is_deeply([ map { $_->{name} } @{ $i->{images} } ], ['debian-13-generic-amd64'], 'cli images --json');
    like($run->('images'), qr/^debian-13-generic-amd64\s+\d+\s+\S+Z\s+(ab){32}$/m, 'cli images text');
    like($run->('list', 'x'), qr/takes no arguments/, 'cli: list takes no name');
}

done_testing;
