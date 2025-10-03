
# To Do list

List of requirements and ideas not yet implemented

## Provision iSCSI on SCH for thin servers


Thin Node - boot disk deploy: order of events

At SCH creation time:

- ✅ HPS Node functions loaded
- HPS Node function wrapper created
- ✅ zpool created automatically and name stored in SCH host config
- 🔄 SCH runs functions to create these scripts so om can run them later:
  - node_create_zvol taking in the zpool name and 
  - node_create_lio_script to create local lio script, and puts in /srv/scripts
- Hand to om

om apps / local scripts to create:

- update_scripts
- node_storage_manager



At diskless server creation time

- ❌ If no disks defined in host config ISCSI_ROOT_0 or ISCSI_ROOT_1, HPS sends message via om to all of class storage node requesting disk provision offers.
  - SCH will respond if it can service the request 
    - script required
    - If no responses, config aborts with warning
  - IQN is then built based on SCH response iscsi target address/port, zpool (IQN_HOST), plus client name and volume name (IQN_VOL).
  - request sent to SCH with IQN_HOST IQN_VOL to do the provision and make ready (via lio script)
    - either create a new empty volume
    - or this may be a clone of an existing volume
  - when confirmed, IQN_HOST:IQN_VOL written to the host config ISCSI_ROOT_0 or ISCSI_ROOT_1 on the client
  - Then volumes mounted to md raid for booting / instralling, or possibly to send a pre-built image
- At install time
  - HPS Node functions loaded
  - Configure as TCN, CCN, DR node etc
  - configure additional disks with md if required, then add LVM, provision by sending request to HPS, getting back commands to configure storage
  
At diskless runtime

- Expanding storage - automated
  - HPS Node functions loaded
  - From Diskless, Send om message to expand the zvol for each disk in a mirror
  - get commands to rescan the md PV with pvresize, then lvextend --resizefs for the volume



### OpenSVC / om

#### instead of scripts, call functions:

oot@dev2n1:~/dev/om3# om restarts config show --section task#envfunc
[task#envfunc]
command = . /tmp/functions.sh && envfunc

root@dev2n1:~/dev/om3# cat /tmp/functions.sh
envfunc() {
    /usr/bin/env
}
root@dev2n1:~/dev/om3# om restarts run --rid task#envfunc

#### Create a task with om to report on free disk i stead of app

Call with:  om restarts run --rid task#env --node=\*
will respond with:
OBJECT    NODE    SID                                   
restarts  dev2n1  847b0b13-0e1b-4237-bc0b-90330ccf0dd5  
restarts  dev2n3  a878ea67-3636-488e-aec6-15177fd9fbc0  
restarts  dev2n2  8eb2f65b-752b-4e61-a1e2-a7f31c7f9879  

and also can catch stdout etc matching on the SID

root@dev2n1:~/dev/om3# om restarts config show --section task#env
[task#env]
command = /usr/bin/env

Create function to make the opensvc app that runs lio:

om svc create -s iscsi-manager --wait
om svc set -s iscsi-manager \
  --kw app#iscsi_manager.type=forking \
  --kw app#iscsi_manager.start="/srv/scripts/lio start" \
  --kw app#iscsi_manager.stop="/srv/scripts/lio stop" \
  --kw app#iscsi_manager.check="/srv/scripts/lio check"


om svc provision -s iscsi-manager --wait

Automate SCH joining the HPS OpenSVC cluster



Implementation of IQN is not fully compliant with the RFC 3720/3721 IQN naming standard (iqn.yyyy-mm.naming-authority:unique-nameiqn.yyyy-mm.naming-authority:unique-name) as a reverse domain name is not used (unless the cluster happens to be a reverse domain name).

The main compliance issue is that the naming authority part must be a reversed DNS name, not just a cluster or arbitrary name. The unique name section after the colon can contain host and volume names as in the example.

This is because it is unlikely that the cluster relates to any particular domain name.

The chosen structure will be unique within the HPS and these exports are not intended to be used on the public network.

The format chosen is:
iqn.<yyyy-mm>.<cluster-name>:<host-name>.<volume-name>

For example: iqn.2025-09.test-1:sch-001.vda


## Refactoring of scripts and libraries

### Function naming

- HPS functions: available to the HPS operations
- Node functions: available on the nodes

Node functions can use the http api to access the HPS, and call HPS functions. 
HPS functions have full access to all parts of HPS

### Script renaming: boot_manager

boot manager should be renamed to hps-api as it now provides a wide range of functions available via ipxe and Node functions.

### hps-api

- output formatted as json, text, html, pxe etc depending on how it is called
- Add json api in addition to query string for better structure

### Function: cgi_auto_fail

- if browser, send html (currently text)
- if cli, send json (currnelty text)
- if ipxe, send pxe (done)
- if unknown, send text (done)



## Feature development


### Generic file reader / writer

- use lock files
- check r/w capability
- standardise warnings through hps_log

### host config

add host_config unset

### clustter  config

add cluster_config unset

### Storage nodes - O/S Installation (A/B method)

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

### Storage nodes - O/S updates (A/B method)

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



### ZFS

- add the multi disk 
- add cli to chose storage config




## New functions

- Verify storage can host more than one cluster
  - will it need separate networks?

### IPS Replicate

- Replicate to each storage node
- Replicate to DRH
- Must exist 2 times plus DRH
- Auto sync data (resoirces, config)
- Config relayed to replicants?
- OpenSVC to stop/start container when required with IPS address

### Cluster network config

- Set the following - default to IPS:
  - DNS_LOCAL_SERVER
  - SMTP_LOCAL_SERVER
  - NTP_LOCAL_SERVER
  - SYSLOG_LOCAL_SERVER
- And set options for upstreams
  - DNS_UPSTREAM_SERVER
  - SMTP_UPSTREAM_SERVER
  - NTP_UPSTREAM_SERVER
  - SYSLOG_UPSTREAM_SERVER

- DEFAULT_ROUTE

### Cluster isolation

Enable ability to write to external location, yet limit what comes in

Firewall - part of the cluster? Containerised? On IPS?

- ALLOW_CLUSTER_EXTERNAL_DNS
- ALLOW_CLUSTER_EXTERNAL_SMTP
- ALLOW_CLUSTER_EXTERNAL_ROUTING


### Network visualisation

- Visualise the network config via web page and pdf print

### Monitoring

- Implement platform monitoring at IPS
- Availability, performance

### syslog

- Add syslog daemon to hps, send all messages to syslog
- add buffering on sending hosts
- Create standardised syslog tag structure, so messages can be managed accordingly
  - manage messages that are not tagged
- don't store local logs on machines
- add dhcp option to set syslog server

### time

- add time service to IPS

### SMTP relay

- exim on IPS

### create node by duplication/clone

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
- Don't allow sensitive config elements to be provided via the api



