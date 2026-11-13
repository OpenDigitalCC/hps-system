#!/usr/bin/env perl
# hps-node resources prints an IOBUDGET line from the host's registry figures.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib/perl", "$Bin/lib";
use StorageFixture;
use HPS::Node;

my $C = 'COMMITTED vcpus=0 mem_mib=0 guests=0 free_mem_mib=- running_guests=0 running_mem_mib=0';
my $mac = $StorageFixture::MAC;
my $f = StorageFixture::setup();
my $n = sub { HPS::Node->new(host => 'sch-001', registry => $f->{reg}, storage => $f->{mk}->(), runner => $f->{ce}, logger => sub { }) };

# nothing measured
my $r = $n->()->resources;
is($r->{stdout}, "out of host-resources\n$C\nIOBUDGET not measured (hps-storage <host> measure)\n", 'not measured: the line says how to measure');
is(scalar(() = $r->{stdout} =~ /^IOBUDGET/mg), 1, 'exactly one IOBUDGET line');

# measured
$f->{reg}->host_set($mac, $_->[0], $_->[1]) for
    [ storage_read_mbps => 520 ], [ storage_write_mbps => 480 ], [ storage_fsync_ms => '0.41' ],
    [ storage_fsync_max_ms => '1.90' ], [ storage_pool_write_mbps => 330 ], [ storage_measured_at => '2026-11-13T09:00:00Z' ];
$r = $n->()->resources;
is($r->{stdout}, "out of host-resources\n$C\nIOBUDGET read_mibs=520 write_mibs=480 pool_write_mibs=330 fsync_ms=0.41 fsync_max_ms=1.90 measured_at=2026-11-13T09:00:00Z\n",
    'measured: the figures, one line, after the node output');

# a figure missing is a dash
$f->{reg}->host_unset($mac, 'storage_write_mbps');
$f->{reg}->host_unset($mac, 'storage_fsync_ms');
$r = $n->()->resources;
like($r->{stdout}, qr/IOBUDGET read_mibs=520 write_mibs=- pool_write_mibs=330 fsync_ms=- fsync_max_ms=1\.90 /, 'a figure never measured is a dash');

# the node output without a trailing newline still gets its own line
my $g = StorageFixture::setup(ce => { out => { 'host-resources' => 'no newline' } });
$r = HPS::Node->new(host => 'sch-001', registry => $g->{reg}, storage => $g->{mk}->(), runner => $g->{ce}, logger => sub { })->resources;
is($r->{stdout}, "no newline\n$C\nIOBUDGET not measured (hps-storage <host> measure)\n", 'node output ended with a newline');

# a failing node call: the exit status stays the node's, the line is still there
my $h = StorageFixture::setup(ce => { rc => { 'host-resources' => 1 } });
$r = HPS::Node->new(host => 'sch-001', registry => $h->{reg}, storage => $h->{mk}->(), runner => $h->{ce}, logger => sub { })->resources;
is($r->{rc}, 1, 'rc is the node\'s');
like($r->{stdout}, qr/^IOBUDGET not measured/m, 'the registry line is shown regardless');

done_testing;
