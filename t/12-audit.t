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
like($hba, qr/Verdict: HBA mode\n    evidence: hba_mode_enabled=1 on host0/, 'explicit-attribute HBA verdict names its evidence');

like($hba, qr{/dev/disk/by-id/ata-FAKE_SSD_1000G_AAA1\n    size 931\.5G, model FAKE SSD 1000G\n}, 'disk by-id, size, model');
like($hba, qr{content: /dev/sda1 zfs_member label=tank}, 'blkid content on a disk');
like($hba, qr{content: zpool label: tank}, 'existing zpool label on a disk');
like($hba, qr{by-id/ata-FAKE_SSD_1000G_BBB2\n    size 931\.5G, model FAKE SSD 1000G\n    content: none seen}, 'clean disk says none seen');
like($hba, qr{by-id/scsi-3600000000000000c\n.*content: /dev/sdc1 ext4 label=old}s, 'other disk blkid content');
unlike($hba, qr{DVD}, 'non-disk devices are not listed');

like($hba, qr/eno1  52:54:00:00:00:aa  UP, link up/, 'NIC with link');
like($hba, qr/eno2  52:54:00:00:00:bb  DOWN\n/, 'NIC without link');
unlike($hba, qr/\blo\b/, 'loopback skipped');

# HBA inferred: no hba_mode_enabled attribute (the DL360 case), hpsa bound, raw
# disks with native models, no LOGICAL VOLUME.
sub inferred {
    my (%o) = @_;
    my $a = audit(hba => undef);
    $a->{storage_controllers}{scsi_hosts} = [ { host => 'host0', driver => 'hpsa' }, { host => 'host1', driver => 'ahci' } ];
    $a->{storage_controllers}{pci_drivers} = { hpsa => ['0000:03:00.0', 'bind', 'module', 'new_id', 'uevent', 'unbind'], smartpqi => undef };
    delete $a->{storage_controllers}{pci_drivers} if $o{no_driver};
    $a->{storage_controllers}{scsi_hosts} = [ { host => 'host1', driver => 'ahci' } ] if $o{no_driver};
    $a->{block}{blockdevices}[2]{model} = 'LOGICAL VOLUME' if $o{lv};
    $a->{storage_controllers}{raid_mode_indicator} = JSON::PP::true if $o{lv};
    return $a;
}
my $inf = HPS::Onboard::render_audit(inferred());
like($inf, qr/Verdict: HBA mode\n    evidence: driver hpsa bound to 0000:03:00\.0; no LOGICAL VOLUME disk; native disk model\(s\): FAKE SSD 1000G, FAKE SAS 146G \(inferred/, 'HBA inferred from driver binding and native models');
like($inf, qr/host0 \(hpsa\): mode not reported/, 'host without attribute is still listed');
is(HPS::Onboard::controller_verdict(inferred())->{verdict}, 'HBA', 'inferred verdict');
is(HPS::Onboard::controller_verdict(inferred(lv => 1))->{verdict}, 'RAID', 'LOGICAL VOLUME gives RAID, not HBA');
is(HPS::Onboard::controller_verdict(inferred(no_driver => 1))->{verdict}, 'UNKNOWN', 'no Smart Array driver and no attribute is unknown');
like(HPS::Onboard::render_audit(inferred(no_driver => 1)), qr/Verdict: unknown/, 'unknown rendered');
my $conflict = inferred(lv => 1);
$conflict->{storage_controllers}{scsi_hosts}[0]{hba_mode_enabled} = 1;
my $cv = HPS::Onboard::controller_verdict($conflict);
is($cv->{verdict}, 'RAID', 'a LOGICAL VOLUME overrides hba_mode_enabled=1');
like(join('|', @{ $cv->{evidence} }), qr/conflicting evidence/, 'conflict is stated');

# Drives the OS cannot see: last 12 hpsa device lines from dmesg.
{
    my $a = inferred();
    $a->{dmesg} = ( [ '[0.1] unrelated line', map { "[1.$_] hpsa 0000:03:00.0: scsi 0:0:$_:0: masked Direct-Access HP EG0300FCVBF" } 1 .. 15 ] );
    my $r = HPS::Onboard::render_audit($a);
    like($r, qr/Drives the OS cannot see \(last 12 hpsa kernel messages/, 'hidden-drive hint shown');
    like($r, qr/scsi 0:0:15:0: masked/, 'newest line shown');
    like($r, qr/scsi 0:0:4:0: masked/, 'twelfth-newest line shown');
    unlike($r, qr/scsi 0:0:3:0: masked/, 'older lines dropped');
    unlike($r, qr/unrelated line/, 'non-hpsa lines ignored');
    unlike(HPS::Onboard::render_audit(inferred()), qr/Drives the OS cannot see/, 'no hint without hpsa lines');
}

# Gaps: an audit with missing parts still renders.
my $bare = HPS::Onboard::render_audit({ schema => 'hps-audit/1' });
like($bare, qr/Vendor:\s+unknown/, 'missing DMI says unknown');
like($bare, qr/No disks reported/, 'no disks');
like($bare, qr/No controller reported hba_mode_enabled/, 'no controller mode');
like($bare, qr/Verdict: unknown/, 'no evidence is unknown, not clean');
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
