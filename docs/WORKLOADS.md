# Workloads

A workload is a named set of VMs whose disks are mirrors of two legs: a local
zvol on the compute node and a remote iSCSI LUN (or two remote LUNs on a
compute-only node). `hps-workload` (Perl, `HPS::Workload`) drives the node
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
| `priority` | 1-5, default 3; 1 starts first and stops last |
| `image` | `^[a-z0-9][a-z0-9._-]{0,63}$`; `hps-resources/images/<image>.qcow2` and `<image>.sha256` must exist on the IPS (checked by `create`; `image-fetch` on the node checks the sum); absent when `boot` is `network` |
| `boot` | optional, `disk` (default) or `network`. `network`: the VM netboots from the first NIC like a metal node (a nested HPS node, CS-3.12a); `image` is refused, `disks` may be empty or absent, so `compute_host` is required; `create` runs `net-bridge-ensure` and `vm-define --boot network` only (no zvol, image, mirror or image write) and `start`, `stop`, `status` and `destroy` are unchanged |
| `disks[].size` | `^[1-9][0-9]*[MGT]$` |
| `disks` | 1 to 8 per VM, names unique within the VM; none needed with `boot: network`. Each disk gets its own zvol (and mirror when it has two legs); the first disk is the boot disk of a `boot: disk` VM and the only one `vm-image-write` fills, the others are left empty for the guest to use (a storage VM builds its own pool on them) |
| `legs` | 1 or 2; `{host,pool}` is a local zvol, `{host,iqn[,portal]}` a remote LUN already exported by the storage side; at most one local leg per disk; one leg only if it is local (the disk is then the zvol itself, no mirror) |
| `nets` | non-empty; every entry is a name in the cluster key `network_layout`, or an object `{"net": "<name>", "pvid": 1-4094, "tagged": [1-4094, ...], "model": "virtio\|e1000e\|rtl8139"}` (only `net` is required). One NIC per entry. `pvid` and `tagged` apply only to a fabric net (layout `kind: fabric`), whose NIC must have a `pvid`; `tagged` VLANs are distinct and not the pvid. Passed to `vm-define` as `--vlan-pvid`, `--vlan-tagged`, `--nic-model` after the `--net`. A vxlan net (layout `kind: vxlan`, `docs/CLUSTER-CONFIG.md`) is named like any other (`"nets": ["client"]`); its NIC sits on the layout bridge (`--net br-client`); its compute host must be a transit host (TYPE `TCH`, NixOS, with a transit address) |
| `hardware` | optional object: `disk_bus` (`virtio` default, `scsi`, `sata`; not `virtio` needs a disk) and `smbios` (`vendor` and `product` required, `serial` optional; each letters, digits, space, `.`, `_`, `-`, first character alphanumeric, at most 63). Passed to `vm-define` as `--disk-bus` and `--smbios` |
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
    `--vlan-pvid` and `--vlan-tagged`, then `--disk-bus` and `--smbios`). Refuses (3) if the workload
    already exists. `--resume` continues a `creating` workload: steps already
    recorded in `done` are skipped. The leg resolution itself happens on the node
    (`mirror-create` calls `leg-resolve`).

`start`
:   VMs in priority order (1 first): `net-vxlan-ensure` for each vxlan net of
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
:   Reverse priority: `vm-stop`, then `mirror-stop`. Records `stopped`.

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
    the report is still printed.

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

`--vm` selects one VM (start, stop, status). `--allow-any-pool-name` (create,
destroy) passes through to `HPS::Storage`: pools are named after the cluster.

## Registry

Cluster key `workload_<name>`:

```json
{"state": "created", "created_at": "...", "by": "operator",
 "vms": {"$VM": {"host": "$NODE", "state": "defined",
                 "disks": {"root": {"md": "/dev/md/$VM-root", "legs": ["local:...", "iscsi:..."]}},
                 "last_owner": "$NODE", "started_at": "..."}}}
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
