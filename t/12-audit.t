#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib/perl";
use JSON::PP;
use HPS::Onboard;

my $by_id = <<'EOT';
total 0
lrwxrwxrwx 1 root root  9 Nov  9 10:00 ata-FAKE_SSD_1000G_AAA1 -> ../../sda
lrwxrwxrwx 1 root root 10 Nov  9 10:00 ata-FAKE_SSD_1000G_AAA1-part1 -> ../../sda1
lrwxrwxrwx 1 root root  9 Nov  9 10:00 wwn-0x5000000000000001 -> ../../sda
lrwxrwxrwx 1 root root  9 Nov  9 10:00 ata-FAKE_SSD_1000G_BBB2 -> ../../sdb
lrwxrwxrwx 1 root root  9 Nov  9 10:00 scsi-3600000000000000c -> ../../sdc
EOT

sub audit {
    my (%o) = @_;
    return {
        schema => 'hps-audit/1',
        collected_at => '2026-11-09T10:00:00Z',
        dmi => { sys_vendor => 'FAKEVENDOR', product_name => 'FakeServer Gen9', product_serial => 'SER12345' },
        cpu => { lscpu => [
            { field => 'CPU(s):',       data => '48' },
            { field => 'Model name:',   data => 'Fake Xeon E5-0000 v4' },
            { field => 'Socket(s):',    data => '2' },
        ] },
        memory => { MemTotal => 134217728 },
        pci => qq{00:00.0 "Host bridge" "Fake" "Root" -r01 "Fake" "Root"\n}
             . qq{03:00.0 "RAID bus controller" "FakeCo" "Smart Array Fake" -r01 "FakeCo" "SA"\n},
        storage_controllers => {
            scsi_hosts => [ { host => 'host0', driver => 'hpsa', hba_mode_enabled => $o{hba} } ],
            raid_mode_indicator => $o{raid_indicator} ? JSON::PP::true : JSON::PP::false,
        },
        block => { blockdevices => [
            { name => 'sda', type => 'disk', size => '931.5G', model => 'FAKE SSD 1000G' },
            { name => 'sdb', type => 'disk', size => '931.5G', model => 'FAKE SSD 1000G' },
            { name => 'sdc', type => 'disk', size => '136.7G', model => ($o{raid_indicator} ? 'LOGICAL VOLUME' : 'FAKE SAS 146G') },
            { name => 'sr0', type => 'rom',  size => '1024M',  model => 'DVD' },
        ] },
        disk_by_id => $by_id,
        blkid => qq{/dev/sda1: LABEL="tank" UUID="1" TYPE="zfs_member"\n/dev/sdc1: UUID="2" TYPE="ext4" LABEL="old"\n},
        zpool_import => qq{   pool: tank\n     id: 123\n  state: ONLINE\n config:\n\n\ttank        ONLINE\n\t  mirror-0  ONLINE\n\t    ata-FAKE_SSD_1000G_AAA1  ONLINE\n},
        net => { link => [
            { ifname => 'lo',   link_type => 'loopback', address => '00:00:00:00:00:00', operstate => 'UNKNOWN', flags => ['LOOPBACK'] },
            { ifname => 'eno1', link_type => 'ether',    address => '52:54:00:00:00:aa', operstate => 'UP',   flags => ['BROADCAST', 'LOWER_UP'] },
            { ifname => 'eno2', link_type => 'ether',    address => '52:54:00:00:00:bb', operstate => 'DOWN', flags => ['BROADCAST'] },
        ] },
    };
}

my $hba = HPS::Onboard::render_audit(audit(hba => 1));

like($hba, qr/Vendor:\s+FAKEVENDOR/,        'DMI vendor');
like($hba, qr/Product:\s+FakeServer Gen9/,  'DMI product');
like($hba, qr/Serial:\s+SER12345/,          'DMI serial');
like($hba, qr/Fake Xeon E5-0000 v4, sockets 2, logical CPUs 48/, 'CPU model and count');
like($hba, qr/Memory: 128\.0 GiB/,          'memory in GiB');
like($hba, qr/PCI: 03:00\.0 FakeCo Smart Array Fake \(RAID bus controller\)/, 'controller named from lspci');
like($hba, qr/host0 \(hpsa\): HBA mode\n/,  'HBA mode in words');
unlike($hba, qr/host0 \(hpsa\): RAID mode/, 'HBA mode is not reported as RAID');

my $raid = HPS::Onboard::render_audit(audit(hba => 0));
like($raid, qr/host0 \(hpsa\): RAID mode - NOT acceptable, see brief/, 'RAID mode in words');
like($raid, qr/Verdict: RAID mode detected/, 'RAID verdict');
unlike($raid, qr/host0 \(hpsa\): HBA mode/, 'RAID is not reported as HBA');

my $ind = HPS::Onboard::render_audit(audit(hba => 1, raid_indicator => 1));
like($ind, qr/LOGICAL VOLUME disk is present: controller in RAID mode - NOT acceptable/, 'raid indicator shown');
like($ind, qr/Verdict: RAID mode detected/, 'indicator alone gives the RAID verdict');
like($hba, qr/Verdict: no RAID-mode indicator/, 'clean HBA verdict');

like($hba, qr{/dev/disk/by-id/ata-FAKE_SSD_1000G_AAA1\n    size 931\.5G, model FAKE SSD 1000G\n}, 'disk by-id, size, model');
like($hba, qr{content: /dev/sda1 zfs_member label=tank}, 'blkid content on a disk');
like($hba, qr{content: zpool label: tank}, 'existing zpool label on a disk');
like($hba, qr{by-id/ata-FAKE_SSD_1000G_BBB2\n    size 931\.5G, model FAKE SSD 1000G\n    content: none seen}, 'clean disk says none seen');
like($hba, qr{by-id/scsi-3600000000000000c\n.*content: /dev/sdc1 ext4 label=old}s, 'other disk blkid content');
unlike($hba, qr{DVD}, 'non-disk devices are not listed');

like($hba, qr/eno1  52:54:00:00:00:aa  UP, link up/, 'NIC with link');
like($hba, qr/eno2  52:54:00:00:00:bb  DOWN\n/, 'NIC without link');
unlike($hba, qr/\blo\b/, 'loopback skipped');

# Gaps: an audit with missing parts still renders.
my $bare = HPS::Onboard::render_audit({ schema => 'hps-audit/1' });
like($bare, qr/Vendor:\s+unknown/, 'missing DMI says unknown');
like($bare, qr/No disks reported/, 'no disks');
like($bare, qr/No controller reported hba_mode_enabled/, 'no controller mode');
like($bare, qr/None reported/, 'no NICs');
is(HPS::Onboard::render_audit(undef), "No audit data.\n", 'undef audit');

# End to end: `hps-onboard show` renders a stored hps-audit/1 document, with
# booleans as decoded from JSON.
{
    require File::Temp; require File::Path; require HPS::Registry;
    my $base = File::Temp::tempdir(CLEANUP => 1);
    local $ENV{HPS_CONFIG_BASE}     = $base;
    local $ENV{HPS_SYSTEM_REGISTRY} = "$base/system.db";
    File::Path::make_path("$base/clusters/lab/cluster.db", "$base/clusters/lab/hosts");
    my $reg = HPS::Registry->new;
    $reg->system_set('ACTIVE_CLUSTER', 'lab');
    $reg->host_set('52:54:00:00:00:01', 'STATE', 'HELD');
    $reg->host_set('52:54:00:00:00:01', 'audit', decode_json(encode_json(audit(hba => 0))));
    my @cmd = ($^X, "-I$RealBin/../lib/perl", "$RealBin/../bin/hps-onboard", 'show', '52:54:00:00:00:01');
    my $out = qx(@cmd 2>&1);
    is($? >> 8, 0, 'show exits 0');
    like($out, qr/RAID mode - NOT acceptable/, 'show renders the audit for a human');
    like($out, qr/Vendor:\s+FAKEVENDOR/, 'show includes DMI');
}

done_testing;
