# Workloads

A workload is a named set of VMs whose disks are mirrors of two legs: a local
zvol on the compute node and a remote iSCSI LUN (or two remote LUNs on a
compute-only node). The mirror is across storage hosts: each SCH holds one
leg on its own pool, and a pool of one disk is the normal SCH shape
(`hps-storage create` with one `--disk`; two to four disks make a local
mirror as well). `hps-workload` (Perl, `HPS::Workload`) drives the node
scripts of `VM-LIFECYCLE.md` and the mirror scripts through `scripts/hps-run.sh`,
and records the outcome in the cluster registry. Placeholders in this page:
`$NODE` (a host: MAC or registry HOSTNAME), `$VM`, `$POOL`, `$MAC`.

## Definition

One file per workload: `workloads/<name>.json` under the cluster's config
directory (`HPS::Registry::workload_dir`, `<config base>/clusters/<cluster>/workloads`).

```json
{"name": "t0", "project": "lab",
 "access": {"ssh_keys": ["ssh-ed25519 AAAA..."], "console": true},
 "vms": [{"name": "t0-app", "memory_mib": 2048, "vcpus": 2,
          "image": "debian-13-generic-amd64",
          "disks": [{"name": "root", "size": "20G",
                     "legs": [{"host": "$NODE", "pool": "$POOL"},
                              {"host": "$NAS", "iqn": "iqn.2026-01.example:hpslab-t0-root",
                               "portal": "192.0.2.50"}]}],
          "nets": ["mgmt"], "priority": 3}]}
```

Checked before any node call; a refusal exits 3 and names the field:

| Field | Rule |
| --- | --- |
| `name` (workload, VM, disk, net) | `^[a-z][a-z0-9-]{0,31}$`; the workload name equals the file name; VM names are unique |
| `project` | non-empty string |
| `access` | optional; `ssh_keys` a list of public key lines, `console` a JSON boolean |
| `memory_mib` | 256-262144 |
| `vcpus` | 1-64 |
| `priority` | 1-5; 1 starts first and stops last. Default 1 for a storage provider (a `boot: network` VM with disks of its own: a nested SCH or IPS builds its pool on them), else 3. At one priority providers start first and stop last. See "Stop order on a node" |
| `image` | `^[a-z0-9][a-z0-9._-]{0,63}$`; `hps-resources/images/<image>.qcow2` and `<image>.sha256` must exist on the IPS (checked by `create`; `image-fetch` on the node checks the sum); absent when `boot` is `network` |
| `boot` | optional, `disk` (default) or `network`. `network`: the VM netboots from the first NIC like a metal node (a nested HPS node, CS-3.12a); `image` is refused, `disks` may be empty or absent, so `compute_host` is required; `create` runs `net-bridge-ensure` and `vm-define --boot network` only (no zvol, image, mirror or image write) and `start`, `stop`, `status` and `destroy` are unchanged |
| `disks[].size` | `^[1-9][0-9]*[MGT]$` |
| `disks` | 1 to 8 per VM, names unique within the VM; none needed with `boot: network`. Each disk gets its own zvol (and mirror when it has two legs); the first disk is the boot disk of a `boot: disk` VM and the only one `vm-image-write` fills, the others are left empty for the guest to use (a storage VM builds its own pool on them) |
| `legs` | 1 or 2; `{host,pool}` is a local zvol, `{host,iqn[,portal]}` a remote LUN already exported by the storage side; at most one local leg per disk; one leg only if it is local (the disk is then the zvol itself, no mirror) |
| `nets` | non-empty; every entry is a name in the cluster key `network_layout`, or an object `{"net": "<name>", "pvid": 1-4094, "tagged": [1-4094, ...], "model": "virtio\|e1000e\|rtl8139"}` (only `net` is required). One NIC per entry. `pvid` and `tagged` apply only to a fabric net (layout `kind: fabric`), whose NIC must have a `pvid`; `tagged` VLANs are distinct and not the pvid. Passed to `vm-define` as `--vlan-pvid`, `--vlan-tagged`, `--nic-model` after the `--net`. A vxlan net (layout `kind: vxlan`, `docs/CLUSTER-CONFIG.md`) is named like any other (`"nets": ["client"]`); its NIC sits on the layout bridge (`--net br-client`); its compute host must be a transit host (TYPE `TCH`, NixOS, with a transit address) |
| `hardware` | optional object: `disk_bus` (`virtio` default, `scsi`, `sata`; not `virtio` needs a disk) and `smbios` (`vendor` and `product` required, `serial` optional; each letters, digits, space, `.`, `_`, `-`, first character alphanumeric, at most 63). Passed to `vm-define` as `--disk-bus` and `--smbios` |
| `seed` | optional, `boot: disk` only: a cloud-init NoCloud seed `{"user_data": "...", "network_config": "...", "meta_data": "..."}`. Every value a JSON string (a number, boolean, null, list or object is refused), no NUL; `user_data` required and non-empty, at most 64 KiB; `network_config` optional, at most 16 KiB; `meta_data` optional, at most 4 KiB (default, written on the node: `instance-id: <vm>`, `local-hostname: <vm>`). Sizes count UTF-8 bytes. See "A guest seed" |
| `cpu_weight` | optional, 1-10000: the VM's CPU weight against the other guests on its host when the CPUs are contended (libvirt `<cputune><shares>`, cgroup v2 `cpu.weight`). Default (vm-define): 100 per vCPU. See "Resource limits" |
| `cpu_max_pct` | optional, 1-100: each vCPU may use at most this percent of one host CPU (`<cputune>` period 100000 µs, quota). Default: no cap |
| `mem_hard_limit_mib` | optional, at least `memory_mib` + 128, at most 1048576: the most the VM's QEMU process may hold, guest RAM and QEMU's own (`<memtune><hard_limit>`); over it the kernel kills that guest, never a neighbour. Default (vm-define): `memory_mib` + 256 + `memory_mib`/16 |
| `io_weight` | optional, 10-1000: `<blkiotune><weight>`. Default: none. Best effort (see "Resource limits") |
| `disks[].iops_max`, `disks[].mbps_max` | optional, per disk: QEMU throttling of that disk (`<iotune>` `total_iops_sec`, `total_bytes_sec` = MiB/s × 1048576). `iops_max` 1-99999999, `mbps_max` 1-999999. Default: no throttle |
| compute host | the host of the VM's local legs (all on one host), else `compute_host`; neither: refused |
| unknown fields | refused |

### A VM on a vxlan network

With the layout entries `"transit": {"cidr": "10.11.2.0/24", "vlan": 112,
"bridge": "br-transit", "purpose": "transit"}` and `"client": {"kind":
"vxlan", "vni": 1100, "over": "transit", "bridge": "br-client", "purpose":
"workload"}`, a VM joins the client network with `"nets": ["client"]` and a
`compute_host` (or local leg host) that is a TCH. `create` and `start` run
`net-vxlan-ensure` on that host before the VM's `vm-define` / `vm-start`;
`hps-node net-up` (after every pairing) builds the same network on every TCH,
so VMs on different TCHs share one L2 segment. The guest's MTU is its own
(1500 by default, within the 8950 of the network).

### A guest seed (cloud-init NoCloud)

A `boot: disk` VM whose image carries cloud-init (the Debian generic cloud
image does) can be given its first-boot configuration in the definition:

```json
"seed": {"user_data": "#cloud-config\nwrite_files: ...",
         "network_config": "version: 2\nethernets: ..."}
```

`create` runs `vm-seed-write <vm> --disk <boot disk>` right after
`vm-image-write`, with the seed as the run's input (`input = raw` on the node:
stdin, never an argument, never logged; `--dry-run` shows only its sizes and
sha256). The node finds partition 1 of the freshly written disk read-only
(`partx -g`), checks it is ext4, mounts it through a loop device at its offset
and writes `/var/lib/cloud/seed/nocloud/user-data`, `meta-data` and
`network-config` (`docs/VM-LIFECYCLE.md`). The guest's cloud-init finds the
NoCloud seed there on its first boot. Its resume key is `seed:<vm>`: a
`create --resume` after a failure at or before it runs it (a second run
writes the same files). `create` records the seed's sha256 in the VM's record
(`seed_sha256`).

**A changed seed needs a re-create.** cloud-init applies a seed once, on the
guest's first boot (per instance-id), and the seed lives on the guest's disk,
so editing the definition changes nothing in a created workload. `status`
says so (`seed: changed since create`). To apply it: `hps-workload destroy
<name>`, `hps-workload define <name> --replace` (or edit the file), then
`create` and `start`; the disk is written fresh.

### Writing and reading a definition

```
hps-workload define <name> [--replace] [--dry-run] [--json]   < <name>.json
hps-workload show-definition <name>
```

`define` reads the JSON definition on stdin (at most 1 MiB) and checks it with
the same code `create` uses to load a definition (the table above, the
`network_layout` nets included, and the workload `name` equal to `<name>`).
It refuses (3) an existing definition unless `--replace`, and refuses
`--replace` while the workload exists (a registry record `workload_<name>`:
`creating`, `created`, `running`, `stopped` or `partial`; `destroy` removes
it). A symlink at the path is never replaced. The file is written as given
(a final newline added) through a temporary file in the same directory and a
rename: a new file is mode 0664 with the directory's group (the shared `hps`
group), a replaced one keeps its mode, owner and group. `--dry-run` checks
everything and writes nothing. Exit 0 ok, 2 usage (a bad name), 3 refused.
`show-definition` prints the stored file as it is (4 when there is none).
Through the operator API: `hps-workload-define` (`docs/OPERATOR.md`).

The zvol of a local leg is `<pool>/enc/vm/<workload>-<vm>-<disk>` (guest disks
live under `<pool>/enc/vm`, where `leg-resolve` looks; `storage-zvol-create` makes
that dataset when absent); the mirror is
`<vm>-<disk>` (`/dev/md/<vm>-<disk>`). The portal of a remote leg is its own
`portal`, else the portal of the export recorded on that host (`storage_exports`),
else that host's registry `IP`.

## Operations

`hps-workload create|start|stop|destroy|status <name> [--vm $VM] [--dry-run] [--json] [--resume] [--forget]`,
`hps-workload console <name> [--vm $VM] [--lines N] [--json]`,
`hps-workload grow-disk <name> <vm> <disk> <new size> [--dry-run] [--json]`
(and `define`, `show-definition` above, which make no node call).
Each operation is an ordered list of node calls (`--dry-run` prints it, changes
nothing). A node call that exits non-zero ends the run at once.

`create`
:   Per VM, in definition order: `storage-zvol-create` (through
    `HPS::Storage`, on the compute host) for the local leg; `image-fetch`
    (once per image and host; `--from http://<network_dhcp_ip>/images/<image>.qcow2
    --sha256 <sum> --dest /$POOL/enc/images`); `mirror-create <vm>-<disk>` with
    the two leg specs (`local:<zvol>`, `iscsi:<portal>:<iqn>`); `vm-image-write`
    (base image onto the first disk only); `net-bridge-ensure` when the host's `nets` key
    lacks a network of the VM (the key is extended first, because the node reads
    it; it is put back if the call fails; vxlan nets are never added to it);
    `net-vxlan-ensure <vni> <bridge> --local <ip> --peer <ip>... --mtu <mtu>`
    for each vxlan net of the VM, once per compute host and net (local and
    peers are the transit addresses, `HPS::Vxlan`; a compute host that is not a
    transit host refuses the plan, 3); `vm-define` (one `--disk <device>` per disk in definition order: `/dev/md/<name>` or `/dev/zvol/<dataset>`,
    one `--net <bridge>` per net from the layout, with that NIC's `--nic-model`,
    `--vlan-pvid` and `--vlan-tagged`, then `--disk-bus` and `--smbios`). A VM
    with a `seed` gets `vm-seed-write <vm> --disk <boot disk>` (the seed on
    stdin) right after its `vm-image-write`. Refuses (3) if the workload
    already exists. `--resume` continues a `creating` workload: steps already
    recorded in `done` are skipped. The leg resolution itself happens on the node
    (`mirror-create` calls `leg-resolve`).

`start`
:   VMs in priority order (1 first; at one priority the storage providers first): `net-vxlan-ensure` for each vxlan net of
    the VM (once per compute host and net; idempotent, and the node runs from
    RAM, so a reboot lost the link; the call also brings the peer list up to
    date), `mirror-assemble` (mirrored disks only; a
    VM on local legs only has none), `vm-status` (read-only), then `vm-start`.
    Records `running`, `last_owner` (the compute host) and `started_at`.
    A node runs from RAM, so after its reboot libvirt no longer has the VM's
    definition while the zvols and legs are still there. When `vm-status`
    exits 4 (not defined), `start` re-defines the VM before `vm-start`:
    `vm-define` with exactly the arguments `create` used (the same builder:
    disks, nets with their `--nic-model`, `--vlan-pvid`, `--vlan-tagged`,
    `--disk-bus`, `--smbios`, `--image`) and the recorded MACs, one `--mac`
    after each `--net`. No zvol create, image fetch, mirror create or image
    write. A VM with no recorded MACs (a `boot: disk` VM whose MACs were never
    read) gets new ones from libvirt; a second `vm-status` reads them back into
    the record. A defined VM is started as before, and its `vm-status` MACs are
    recorded when the record has none, so a later re-define keeps them.
    The re-define is refused (3), and nothing is defined or started, when the
    definition no longer matches the record: another compute host, other disk
    names, devices or leg specs, a MAC count that is not the NIC count, or
    (records whose `create` stored them, `define`) other `vm-define`
    arguments; the message names the difference. Put the definition back, or
    destroy and create the workload. The re-define and the second `vm-status`
    are plan steps marked `only if vm-status reports <vm> not defined`: they
    appear in `--dry-run` (with `refused then: <why>` when a re-define would
    be refused) and are shown `(skipped, not needed)` when the VM was defined.

`stop`
:   Reverse priority (consumers before providers at one priority): `vm-stop`, then `mirror-stop`. Records `stopped`. `vm-stop` waits for the guest's own shutdown and never forces; `stop --force` passes `vm-stop --force` (the graceful wait, then `virsh destroy`) for a guest that cannot shut down, such as one whose root filesystem went read-only.

`destroy`
:   Allowed in every recorded state (who may run it is ctrl-exec's decision, ADR 0007). From an unfinished create (`creating`) only what the create attempted (its `done` steps and the one running when it stopped, `attempting`) is stopped, undefined or destroyed; the other steps are skipped with a `note:` line. Reverse priority: `vm-stop` (a VM that is not
    defined is tolerated), `vm-undefine`, `mirror-stop`; then
    `storage-zvol-destroy` of every local leg (through `HPS::Storage`). The
    registry record `workload_<name>` is removed last, only when every call
    succeeded, and replaced by `workload_<name>_destroyed` (`at`, `by`,
    `forgotten`) for audit; the next `create` removes that audit record. The
    refusals of `HPS::Storage` and of the node scripts hold: an exported zvol,
    a guest that is not shut off, a zvol in use.
    **The definition `workloads/<name>.json` is kept**: destroy removes the
    instance, not the operator's intent, so `create` runs again from the same
    file.

`destroy --forget`
:   As `destroy`, and the definition file is removed too (the audit record
    says `forgotten`). Same exit codes; `--forget` is refused
    (usage, 2) on every other operation.

`status`
:   Per VM `vm-status` and per mirror `mirror-status`; reports the recorded and
    the node-reported state. A failing node call makes the exit status 1 but
    the report is still printed. For a VM with a seed (now or at create) a
    `seed:` line: `as written`, or `changed since create` / `none written`
    (destroy and create to apply it).

`console <name> [--vm $VM] [--lines N]`
:   Read-only: `vm-console-log <vm> [--lines N]` on each VM's compute host
    (start order), the tail of the guest's serial console log
    (`/var/log/libvirt/qemu/<vm>-serial.log`). `--lines` 1-10000 (default the
    node's 200). With `--vm` the log alone is printed, else each under a
    `== <vm> on <host>` heading; carriage returns, escape sequences and other
    control characters are removed (tab and newline stay). `--json`: `{vms:
    [{vm, host, rc, log, error}]}`. Works in every recorded state (also
    `creating`); no record is not found (4). Exit 0; 4 when the one VM asked
    for has no log (4 from the node); 1 when any VM's log could not be read
    (the others are still printed). The scale test's board reads the probe
    lines this way, through the operator API (`docs/OPERATOR.md`).

`grow-disk <name> <vm> <disk> <new size>`
:   Grows one disk of one VM while it runs. Two calls on the compute host:
    `storage-zvol-grow <pool>/enc/vm/<name>-<vm>-<disk> <new size>` (through
    `HPS::Storage`, the same as `hps-storage <host> zvol-grow`; the node only
    grows, a smaller size is refused, 3), then `vm-disk-resize <vm>
    /dev/zvol/<dataset>` (`virsh blockresize` to the zvol's new size; a shut
    off guest sees it at its next start). The size is the new size of the whole
    disk, like `64G`. Only a disk of one local leg: a mirrored disk is refused
    (3). The filesystem inside the guest is grown there (`cnh-disk-grow` on a
    container host, `docs/CONTAINER-HOST.md` "When the state disk fills").
    The definition keeps its old size; a `create` after a `destroy` makes the
    disk at that size again (the run says so in a `note:` line). Needs the
    workload created (4 when it has no record).

`--vm` selects one VM (start, stop, status, console). `--allow-any-pool-name` (create,
destroy) passes through to `HPS::Storage`: pools are named after the cluster.

## Resource limits

Owner, 2026-11-12: "can we set some limits inside the vm's so that they dont
interfere with the base and neighbours. these can be declared in the config.
vm host must be protected primarily so it has enough resource to manage the
raid, on storage so they can run the zfs, and on vm host so it can manage its
vm's." (Lab: a builder VM compiling a NixOS image drove the nested storage
VMs to LOAD CRITICAL and the DL360 to 7-9 % memory available.)

Two layers, both on by default:

1. **The host first** (every node, at boot; `docs/CLUSTER-CONFIG.md` "Host
   reserve"). `host-reserve-apply` keeps the first `host_reserve_cpus`
   logical CPUs and `host_reserve_mem_mib` of RAM for the host and, on a
   storage host (the node's registry `TYPE` contains `SCH`; the image's
   roles only when the host has no `TYPE`), caps the ZFS ARC at
   `zfs_arc_max_pct` of RAM. Every libvirt
   guest lives in `machine.slice`, which gets the other CPUs
   (`AllowedCPUs`), `CPUWeight=50` and `IOWeight=50` (the host's
   `system.slice` keeps 100) and `MemoryMax` = RAM - host reserve - ARC cap.
   md resync, ZFS, iscsid, libvirtd, ctrl-exec and rsyslog always have
   their CPUs and memory; the guests share the rest.
2. **Per VM** (the definition fields above). Every VM gets a CPU weight in
   proportion to its vCPUs and a memory hard limit a little above its RAM,
   so one guest cannot take the others' share. A noisy guest (an image
   builder, a batch job) is capped further by hand.

`vm-start` refuses (3) to start a guest whose memory, with the memory of the
guests already running on the host, is over `machine.slice`'s memory limit:
the slice's OOM killer would otherwise kill a running guest. The check is at
start, not at create, because a defined but stopped guest holds no memory;
the way to fit more guests is a smaller `host_reserve_mem_mib` or a bigger
host, never an override.

A builder, capped (half a host CPU per vCPU, a quarter of the default weight,
its disk at 200 MiB/s and 2000 IOPS):

```json
{"name": "bld-001", "memory_mib": 8192, "vcpus": 4, "image": "debian-13-generic-amd64",
 "nets": ["mgmt"], "priority": 5,
 "cpu_max_pct": 50, "cpu_weight": 100,
 "disks": [{"name": "work", "size": "200G", "legs": [{"host": "$NODE", "pool": "$POOL"}],
            "iops_max": 2000, "mbps_max": 200}]}
```

What each lever does, and what it does not:

- `cpu_max_pct` is a hard cap (CFS bandwidth): the guest never gets more,
  even on an idle host. `cpu_weight` only matters when the CPUs are
  contended. The host's reserved CPUs are outside the guests' cpuset either
  way.
- `mem_hard_limit_mib` too low kills the guest when QEMU grows (libvirt
  warns of this); the default leaves 256 MiB plus 1/16 of the RAM.
- `iops_max` / `mbps_max` are enforced by QEMU itself and work on any disk.
  `io_weight` and the slice's `IOWeight` are cgroup weights: the kernel
  applies them only on a device whose scheduler is BFQ or with io.cost
  configured, and the I/O of a zvol is issued by ZFS's own threads, not by
  the guest. Treat them as best effort; throttle with `iops_max` /
  `mbps_max`.
- A limit is part of the vm-define arguments `create` records: changing it
  on a created workload makes a later re-define refuse (the definition no
  longer matches the record). Destroy and create to change it.

`hps-node resources <host>` shows what a host applied and holds (node
script `host-resources`, read-only).

## Stop order on a node

A compute host stops its guests when it powers off or reboots, however that
was asked for (`hps-node <host> power-off` / `node-poweroff`, `systemctl
reboot`, the power button): `hps-shutdown-storage.service` runs
`hps-shutdown-storage`, which stops the guests one after the other before
the mirrors, the iSCSI exports and sessions, and the pools. The order:

1. priority 5 first, 1 last (the reverse of `start`);
2. at one priority, the storage consumers before the storage providers;
3. otherwise the order `virsh list` gives.

A storage provider is a VM that serves storage to other guests: a `boot:
network` VM with disks (a nested SCH, or a nested IPS). Everything else
consumes: a `boot: disk` VM whose disks are md mirrors over iSCSI legs, and a
diskless nested node (a nested TCH, whose storage is the nested SCHs').
Stopping a provider first takes the legs from under its consumers' mirrors
(2026-11-12: s1's SCH VMs stopped before its TCH VMs, and the probes' mirrors
lost both legs).

`start` passes the order to the node: `vm-start <vm> --priority <n>
[--provides-storage]`, which `vm-start` records in `/run/hps/guests/<vm>`
(`<priority> <0|1>`, tmpfs: the node runs from RAM) once the guest runs. A
guest started any other way has no record and counts as priority 3, a
consumer. A guest started before this change gets its record at its next
`start`.

The rule works within one compute host. Across hosts (a nested TCH on one
host using a nested SCH on another) the order of the hosts' own shutdowns is
the operator's: power the consumers' hosts off first.

## Losing a leg: an outage, not a stall

Owner ruling 2026-11-12: a storage host that does not answer for 15 seconds
is an outage of that leg. Guests (and the applications in them) handle a
failed or degraded disk; they do not handle I/O that blocks for minutes.
open-iscsi's default queues I/O for 120 s (`replacement_timeout`) before md
sees an error, so a lost leg stalled every guest on it for about two minutes.

Initiator timeouts
:   Before each leg login `leg-resolve` writes four values into the node
    record (`iscsiadm -m node -T <iqn> -p <portal> -o update -n <key> -v
    <value>`; the constants `ISCSI_TIMEOUTS` at the top of the script):
    `node.session.timeo.replacement_timeout=15`,
    `node.conn[0].timeo.noop_out_interval=5`,
    `node.conn[0].timeo.noop_out_timeout=5`,
    `node.conn[0].timeo.login_timeout=15`. A dead connection is noticed by
    the NOP-Out ping within about 10 s, and I/O fails up to md 15 s later.
    The compute profile appends the same four lines to `iscsid.conf`
    (`services.openiscsi.extraConfig`), so every record discovery creates
    starts with them. `iscsi-login-test` logs in through `leg-resolve` and
    gets the same values.

md failfast
:   `mirror-create` puts both legs in with `--failfast` (kept in the 1.2
    superblock); `mirror-assemble` sets it on every member after assembly
    through sysfs (`echo failfast > /sys/block/<mdX>/md/dev-<member>/state`;
    `mdadm --assemble` has no per-device flag), which also covers mirrors made
    before this change; `mirror-rejoin` re-adds with `--re-add --failfast`.
    With failfast md fails a leg on its first I/O error instead of retrying.
    md never fails the last working leg. `--write-mostly` on the remote leg is
    unchanged.

Logout on stop
:   `mirror-stop`, after `mdadm --stop` (or when the mirror is not assembled),
    logs out each `iscsi:` leg in the sidecar and deletes its node record
    (`--logout`, then `-o delete`; exit 21, nothing there, is fine). A local
    leg is untouched. A logout that fails keeps the sidecar and exits 1, so a
    second `mirror-stop` retries it. `mirror-detach-leg` logs out the leg it
    detached the same way; `mirror-rejoin` logs it in again through
    `leg-resolve`. Before this, a destroyed workload's initiator retried its
    targets forever (each storage host logged about 70 "iSCSI Login
    negotiation failed" / "Unable to locate Target IQN" lines).

Issue markers
:   The mdadm monitor's `PROGRAM` is `hps-md-event` (`/etc/hps/hps-md-event`
    on compute nodes; not a ctrl-exec script, only mdadm runs it). It writes
    one syslog line with tag `hps-issue`, which the node forwards to the IPS
    (`docs/LOGGING.md`):

        HPS-ISSUE open kind=mirror-leg host=<host> mirror=<name> component=<dev> event=<Event> [leg=<iqn>@<portal>]
        HPS-ISSUE resolve kind=mirror-leg host=<host> mirror=<name> event=<Event>

    `open` on `Fail`, `FailSpare` and `DegradedArray` (`component=-` when
    mdadm names no device, as for `DegradedArray`); `leg=` when the component
    is the disk of an iSCSI session (`iscsiadm -m session -P3`), left out
    otherwise. `resolve` on `RebuildFinished`, `RecoveryFinished` or
    `SpareActive` when `/sys/block/<mdX>/md/degraded` reads 0. `<host>` is
    the short hostname, `<name>` the mirror (`/dev/md/<name>`). Other events
    get no marker; mdadm logs them itself.

## Registry

Cluster key `workload_<name>`:

```json
{"state": "created", "created_at": "...", "by": "operator",
 "vms": {"$VM": {"host": "$NODE", "state": "defined",
                 "disks": {"root": {"md": "/dev/md/$VM-root", "legs": ["local:...", "iscsi:..."]}},
                 "last_owner": "$NODE", "started_at": "...",
                 "seed_sha256": "<hex, only for a VM with a seed>"}}}
```

After `destroy`, cluster key `workload_<name>_destroyed` is
`{"at": "...", "by": "operator", "forgotten": false}`; the next `create` removes it.
All registry keys, with their types: `docs/REGISTRY-KEYS.md`.

A `boot: network` VM has `"disks": {}` and `"macs": ["$MAC", ...]`, the MACs
`vm-define` reported (`VM $VM defined mac=$MAC`, one per NIC), which are the
identity the IPS sees when the VM netboots. A `boot: disk` VM gets `macs` from
`vm-status` at its first `start` (or its first re-define). Every VM created
since the re-define landed also has `"define": [...]`, the `vm-define`
arguments `create` used, against which a re-define checks the definition.

States. VM: `creating`, `defined`, `running`, `stopped`. Workload: `creating`
(an unfinished create; carries `done`, the finished step keys), `created`,
`running`, `stopped`, or `partial` when the VMs differ. `start` and `stop` refuse (3) a workload still `creating` (finish it with `create --resume`, or remove it with `destroy`); a workload with no record
is not found (4).

## Authorisation

Authorisation is ctrl-exec's alone (ADR 0007, owner ruling 2026-11-11): who may
run `hps-workload` is decided there. An operator reaches it through the
`ips-admin` allowlist and the operator API's auth hook (`docs/OPERATOR.md`), or
runs it as root on the IPS.

## Exit codes and logging

`0` ok, `1` failed (a node call failed), `2` usage, `3` refused (definition,
policy, node refusal, existing workload), `4` not found (definition, record, VM).
Every node call, its exit status and every refusal is logged to stderr and, via
`logger -t hps -p local0.<level>`, to syslog (`HPS_WORKLOAD_NO_SYSLOG=1` turns
syslog off). No log line carries a key, secret or signature.

## Jobs

The root job runner (`hps-jobs`, ADR 0006) accepts `workload-create <name>
[--resume]` and `workload-start|stop|status <name> [--vm $VM]`. Destroy is not a
job kind (owner ruling 2026-11-11, ADR 0007): run `hps-workload destroy` as root
on the IPS or through the operator API. `workload-status` runs `hps-workload status <name> --json`.
Environment: `HPS_WORKLOAD_CMD` (default `bin/hps-workload`), `HPS_RUN_CMD`
(`hps-run.sh`), `HPS_RESOURCES` (default `$HPS_BASE/hps-resources`).

## Not verified here

Nothing in this page has run against libvirt, mdadm, ZFS or ctrl-exec; tests use
a recording runner or a shim `hps-run`. The first real run is the lab runsheet.
