# VM lifecycle node scripts

The scripts the IPS calls (through ctrl-exec, profile `node`) to put a guest on a
compute node, run it and take it away again. One script per action; each logs
every command as `+ <command>` on stderr and prints one result line last on
stdout. Everything runs as root on `$NODE`. Names: `$VM` is
`^[a-z0-9][a-z0-9-]{0,31}$`; `$POOL` is the node's ZFS pool.

Not unit-tested against real libvirt or QEMU: the tests use shimmed `virsh`,
`qemu-img`, `curl` and `sha256sum` (none are on the development host). The
first real run is the lab runsheet.

## Order

For a new guest the IPS calls:

1. `image-fetch` – the base qcow2 into the images dataset of `$POOL` (once per image).
2. `mirror-create` (CS-3.2) – the guest's disk mirror, `/dev/md/<name>`.
3. `vm-image-write` – base image onto the fresh mirror.
4. `vm-seed-write` – only for a VM with a `seed`: the cloud-init NoCloud seed onto the root partition of that disk.
5. `vm-define` – the libvirt domain.
6. `vm-start`.

Taking it away: `vm-stop`, then `vm-undefine`. Data (zvols, mirrors, images) is
removed by the IPS's `hps-workload destroy`, never by these
scripts. `vm-status`, `vm-console-log` and `vm-confinement-report` are read-only
and can run at any time.

## Scripts

| Script | Does | Exit codes |
| --- | --- | --- |
| `image-fetch <name> --from http://<ips>/<path> --sha256 <hex> --dest <dir>` | curl (http only, no redirects) to `<dir>/<name>.qcow2.part`, checks sha256, renames. File present with the right hash: no download. Last line `IMAGE <name> <sha256> <path>` | 0 ok, 2 usage, 3 refused (scheme/host/URL shape, bad name or hash, sha256 mismatch), 1 command failed |
| `vm-define <vm> --memory <MiB> --vcpus <n> --disk <dev> [--disk <dev>...] --net <bridge> [--mac <mac>] [--net ...]... --image <qcow2> [--serial-log <path>] [--replace]` | Renders the domain XML (q35, OVMF, one raw disk per `--disk` (1 to 8, each path once; targets `vda`, `vdb`, ... in the order given, see `--disk-bus`), virtio NIC per bridge, serial console to a log, no graphics) and `virsh define`s it. Same definition again: no change. A different one: refused unless `--replace` (guest must be shut off). Never reads or copies `--image` (recorded in the metadata only). Last line `VM <vm> defined`. `--boot network` (CS-3.12a) instead: OVMF netboots from the first NIC (`<boot dev='network'/>`, then the disk if any), `--disk` and `--image` are optional (a guest may have no disk), `--mac` (lower-case unicast) fixes the MAC of the `--net` before it (else libvirt generates one) and the last lines are one `VM <vm> defined mac=<mac>` per NIC | 0, 2, 3 refused (bad argument, different definition, running with `--replace`), 1 |
| `vm-image-write <vm> --disk <dev> --image <qcow2> [--force]` | `qemu-img convert -f qcow2 -O raw` onto the one disk named (a VM with several disks: the first, the boot disk; the others are never touched), only if its first 512 bytes are zero (or `--force`) and the guest is not running. Logs the image sha256. Last line `IMAGE <vm> <sha256> written` | 0, 2, 3 refused (data in first sector, guest in use, bad argument), 1 |
| `vm-seed-write <vm> --disk <dev> [--partition 1]` | stdin (`input = raw`): `{"user_data": "...", "network_config": "...", "meta_data": "..."}`, `user_data` required. Finds the partition read-only (`partx -g`, no kernel change), checks it is ext4 (`blkid -p` at its offset), mounts it through a loop device at that offset (`mount -o loop,offset,sizelimit,nodev,nosuid,noexec`) on a private directory under `/run/hps`, writes `/var/lib/cloud/seed/nocloud/user-data`, `meta-data` (default `instance-id: <vm>`, `local-hostname: <vm>`) and `network-config` (only when given; an old one is removed), mode 0600 root, and unmounts. Refuses a symlink anywhere on that path and a partition with no `/etc`. Second run: the same files again. cloud-init reads the seed on the guest's first boot only, so a changed seed needs a fresh disk (destroy and create). Last line `SEED <vm> written user-data=<bytes> meta-data=<bytes> network-config=<bytes\|->` | 0, 2, 3 refused (guest not shut off, no such partition, not ext4, not a root filesystem, symlink, bad input or argument), 1 |
| `vm-start <vm> [--priority <1-5>] [--provides-storage]` | `virsh start`, waits up to 30 s for running, then applies the fabric-port VLANs recorded by `vm-define` (below). Running already: nothing to start, VLANs re-applied. Then records the stop order (`<priority> <0\|1>`, default `3 0`) in `/run/hps/guests/<vm>` for `hps-shutdown-storage` (`docs/WORKLOADS.md` "Stop order on a node"). Last line `VM <vm> running` | 0, 2, 3 (paused or other odd state), 4 not defined, 1 not running in time |
| `vm-stop <vm> [--timeout 60] [--force]` | `virsh shutdown`, waits. `virsh destroy` only with `--force` after the timeout. Last line `VM <vm> shut off` | 0, 2, 4 not defined, 1 still running |
| `vm-disk-resize <vm> <target\|/dev/zvol/<pool>/enc/[vm/]<name>>` | After `storage-zvol-grow`: the disk (found in `virsh domblklist` by its target or its source) is set to its source device's size (`blockdev --getsize64`) with `virsh blockresize`, so a running guest sees the new size. A shut off guest needs nothing (it sees the size at start). Never larger than the device, so never a shrink of the zvol. Last line `VM-DISK <vm> <target> source=<device> bytes=<n> resized=<yes\|no>` | 0, 2, 3 (no such disk, not a device), 4 not defined, 1 |
| `vm-disk-hotplug <vm> detach\|attach <target>` | Failure drills (the "pulled drive"): `detach` saves the running guest's `<disk>` element for that target (source, driver, serial) under `/run/hps/hotplug/` and unplugs it live; `attach` plugs back exactly that saved element. Live only: the persistent definition is unchanged, so a restart also brings the disk back. The boot disk is refused. |
| `vm-status [<vm>]` | Read-only: `virsh list --all`, `dominfo`, `domblklist`. Last line per guest `VM <vm> <state>`, or `no VMs` | 0, 2, 4 |
| `vm-undefine <vm>` | `virsh undefine --nvram` of a shut-off guest. Not defined: no-op. Does not touch disks (however many), mirrors or images. Last line `VM <vm> undefined` | 0, 2, 3 (not shut off), 1 |
| `vm-console-log <vm> [--lines 200] [--qemu]` | Read-only tail of `/var/log/libvirt/qemu/<vm>-serial.log`; `--qemu` tails `<vm>.log`, the QEMU process log (where "process exited while connecting to monitor" explains itself) | 0, 2, 4 no log |
| `vm-confinement-report [<vm>]` | Read-only confinement checks; see `CONFINEMENT.md`. Last line `CONFINEMENT model=... qemu_user=... seccomp=... apparmor_kernel=... label=...` | 0, 2 |

## Repeating a call

Every script can be run twice with the same arguments and the second run changes
nothing: `image-fetch`, `vm-define`, `vm-start`, `vm-stop` and `vm-undefine`
succeed with a no-op; `vm-image-write` refuses (3) because the disk is no longer
fresh; `vm-seed-write` writes the same seed files again.

## A VM on the provisioning segment (CS-3.12a)

A VM node is the same thing as a metal node: it DHCPs from the IPS, netboots
the audit image and is onboarded, assigned and pinned. For the VM to reach both
the IPS and its own host, the host's boot NIC must be a bridge member (macvtap
cannot carry guest to host traffic). Host key `boot_bridge=<br-name>`
(`^br-[a-z0-9-]{1,12}$`) goes on the kernel command line as `hps.bridge=<name>`;
`hps-net` then writes `08-hps-boot-bridge.netdev` (the bridge, with the boot
NIC's MAC), `11-hps-boot-member.network` (the NIC, `Bridge=`) and moves
`10-hps-boot.network` (DHCP) to the bridge. Without the key nothing changes. The
layout entry `{"cidr": ..., "bridge": "<br-name>", "purpose": "provisioning",
"uplink": "boot"}` names the bridge for workloads; `net-bridge-ensure` checks it
and leaves it alone. `iscsi-login-test <portal-ip> <iqn>` is the node-side proof
(log in, read 1 MiB, log out, delete the node record; last line
`ISCSI <iqn> <device> <bytes> OK`).

### Emulated switch ports and emulated hardware (scale test)

`vm-define` takes more options. Per-NIC ones follow the `--net` they belong to,
once each, like `--mac`:

| option | meaning |
| --- | --- |
| `--nic-model virtio\|e1000e\|rtl8139` | the NIC model (default `virtio`) |
| `--vlan-pvid <1-4094>` | the NIC's native (untagged) VLAN on a VLAN-aware bridge |
| `--vlan-tagged <v[,v...]>` | its tagged VLANs (distinct, 1-4094, not the pvid) |
| `--disk-bus virtio\|scsi\|sata` | VM level, the bus of every `--disk` (default `virtio`, targets `vda`, `vdb`, ...); `scsi` adds one virtio-scsi controller (targets `sda`, `sdb`, ...); `sata` uses the q35 AHCI controller, one port per disk (`sda`, `sdb`, ...) |
| disk serial | every `--disk` gets `<serial>` `<vm>-d<N>` (N = 1-based position in the `--disk` order, so the first disk is `<vm>-d1`), at most 20 characters (the virtio-blk and ATA limit): a longer one keeps its last 20, so the disk number survives. Two disks of one VM with the same serial are refused (3). Single-disk VMs have one too. This is what lets a guest name a disk (and a storage VM its pool and wipes) by `/dev/disk/by-id` instead of `sdX`/`vdX`. How the guest sees it: virtio, `/dev/disk/by-id/virtio-<serial>` (confirmed: udev `60-persistent-storage.rules`, `virtio-$ATTRS{serial}`); sata, `/dev/disk/by-id/ata-<model>_<serial>` (the form `ata-$ID_SERIAL` is confirmed in the same rules; that `ata_id` builds ID_SERIAL as QEMU's model, `QEMU_HARDDISK`, plus the serial is unverified); scsi, `/dev/disk/by-id/scsi-<id>` with the serial in it, for example `scsi-0QEMU_QEMU_HARDDISK_<serial>` or `scsi-SQEMU_QEMU_HARDDISK_<serial>` (unverified, depends on `scsi_id`). Check with `ls -l /dev/disk/by-id` in the guest before relying on a form |
| `--smbios vendor=<v>,product=<p>[,serial=<s>]` | VM level; the guest's SMBIOS system manufacturer, product and serial (`<sysinfo type='smbios'>` and `<smbios mode='sysinfo'/>`). Values: letters, digits, space, `.`, `_`, `-`, first character alphanumeric, at most 63 |

A fabric bridge is a network layout entry with `kind: fabric` (see
`docs/CLUSTER-CONFIG.md`): `net-bridge-ensure` builds it as a bridge with
`vlan_filtering 1`, no member NIC, no address and MTU 9000 (or the entry's
`mtu`), and takes the bridge's own port out of VLAN 1. A tap port on it passes
nothing until it has a VLAN, so `vm-define` refuses (3) a NIC on a bridge that
has `vlan_filtering 1` (read with `ip -d link show dev <bridge>`) and no
`--vlan-pvid`. libvirt configures no VLANs on the tap of a Linux bridge, so
`vm-define` only records them in the domain metadata
(`<hps:nic index='<n>' pvid='<p>' tagged='<a,b>'/>`, part of the definition hash,
so a changed VLAN is a different definition) and `vm-start`, after the guest
runs, reads each NIC's tap (`<target dev=>` in `virsh dumpxml`, the NIC at that
index) and runs, per NIC with VLAN metadata:

    bridge vlan del dev <tap> vid 1          (only while the port is in VLAN 1)
    bridge vlan add dev <tap> vid <pvid> pvid untagged
    bridge vlan add dev <tap> vid <v>        (per tagged VLAN)

A guest with no VLAN options runs no `bridge` command. `bridge` is in iproute2,
which is already on the ctrl-exec script path. A failing `bridge` command makes
`vm-start` exit 1 with the guest left running.

## Assumptions to confirm in the lab

* OVMF firmware: `/run/libvirt/nix-ovmf/edk2-x86_64-code.fd` and
  `edk2-i386-vars.fd` (the files the nixpkgs 26.05 libvirtd module links);
  `HPS_OVMF_CODE` and `HPS_OVMF_VARS` override them.
* The guest's QEMU user (`qemu-libvirtd`) can write the serial log under
  `/var/log/libvirt/qemu/` (libvirt's DAC driver relabels it).
* OVMF's network boot (virtio-net PXE) finds the IPS through the bridge, and
  `systemd-networkd` builds the bridge with the NIC's MAC before the DHCP
  client starts; neither is verified here.
* `virsh`, `qemu-img` and `curl` are on the ctrl-exec script path of the node.
