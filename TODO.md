
# To Do list

List of requirements and ideas not yet implemented

## Storage nodes - O/S Installation (A/B method)

- Create built image, then deploy to host, ready for A/B updates
- Deployed via PXE

Outline:

- Base partitioning scheme (one-time)
  - PXE-boot the new node into a minimal installer (initrd or rescue).
  - Partition the system disk(s) with:
      - EFI/boot partition.
      - Two root partitions (e.g. /dev/sda2 and /dev/sda3) sized to hold the OS image (A/B scheme).
      - Any additional data/storage partitions/ZFS pools.
  - Install GRUB/EFI loader once.
- Seed initial OS image
  - Mount root partition “A” at /mnt/newroot.
  - Deploy base OS image from provisioning node (tarball, rsync, zfs recv, or raw dd).
  - Install bootloader into /mnt/newroot.
  - Configure /etc/fstab for A/B root partitions.
  - Set boot entry → root “A”.
- Reboot into node
  - Node boots cleanly into base image.
  - At first boot, inject hostname, cluster membership, IP config (via cloud-init NoCloud, systemd-firstboot, or HPS CGI).
  - Register with HPS provisioning node.
- Subsequent updates
  - Use same process as for existing nodes:
      - Deploy image into the inactive root partition.
      - Update bootloader.
      - Reboot with rollback safety.

## Storage nodes - O/S updates (A/B method)

- Instead of kickstart, create images and deploy to new hardware
- manage incremental updates through package manager
- deploy new O/S every 2 months (or on demand)

Outline:

- Prepare new system image
  - Build root filesystem (Kickstart/Autoinstall, debootstrap, or chroot build).
  - Export as tar.gz, raw image, or ZFS snapshot.
- Provision target host
  - Ensure host has two root partitions/datasets (A/B scheme).
  - Identify which one is active (currently mounted as /).
  - Select the inactive partition/dataset for new deployment.
- Deploy image
  - Mount the inactive partition at /mnt/newroot.
  - Extract/sync image into /mnt/newroot (tar, rsync, or zfs recv).
  - Bind-mount /dev, /proc, /sys into /mnt/newroot and chroot to install bootloader (grub2).
- Update bootloader config
  - Add new boot entry pointing to /mnt/newroot.
  - Optionally make it default once (so rollback is automatic if it fails).
  - Preserve old entry as rollback target.
- Switch active root
  - Mark new partition as default boot target (grub-set-default, zpool set bootfs=, etc.).
- Reboot into new system
  - Downtime = reboot only.
  - Host comes up on fresh image.
- Verify and cleanup
  - Health check storage services.
  - If OK → mark new root permanent.
  - If not → reboot back into old partition (rollback).



## ZFS

- add the multi disk 
- add cli to chose storage config

## syslog

- Add syslog daemon to hps, send all messages to syslog
- add buffering on sending hosts
- Create standardised syslog tag structure, so messages can be managed accordingly
  - manage messages that are not tagged
- don't store local logs on machines
- add dhcp option to set syslog server

## time

- add time service to IPS

## DNS

- Add dns hosts via dnsmasq to IPS
- to file ${HPS_SERVICE_CONFIG_DIR}/dns_hosts

## create node by duplication

- zvol image duplication
- duplicate config file
- set key variables
- Create new host by duplicating zvol
- for thin compute nodes
- Implement function, available in ipxe and cli

## Security

- only send my config to my MAC address, decline to anyone else
- only send my cluster ifo to members of my cluster
- reject all queries from unknown MAC, with one exception
  - only allow initial config options to systems that we have dhcp booted

## Function: cgi_auto_fail

- if browser, send html (currently text)
- if cli, send json (currnelty text)
- if ipxe, send pxe (done)
- if unknown, send text (done)



