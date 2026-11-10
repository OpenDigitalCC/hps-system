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
| `disks` | exactly one per VM (`vm-define` keeps one `--disk`); none needed with `boot: network` |
| `legs` | 1 or 2; `{host,pool}` is a local zvol, `{host,iqn[,portal]}` a remote LUN already exported by the storage side; at most one local leg per disk; one leg only if it is local (the disk is then the zvol itself, no mirror) |
| `nets` | non-empty; every name must be in the cluster key `network_layout` |
| compute host | the host of the VM's local legs (all on one host), else `compute_host`; neither: refused |
| unknown fields | refused |

The zvol of a local leg is `<pool>/enc/vm/<workload>-<vm>-<disk>` (guest disks
live under `<pool>/enc/vm`, where `leg-resolve` looks; `storage-zvol-create` makes
that dataset when absent); the mirror is
`<vm>-<disk>` (`/dev/md/<vm>-<disk>`). The portal of a remote leg is its own
`portal`, else the portal of the export recorded on that host (`storage_exports`),
else that host's registry `IP`.

## Operations

`hps-workload create|start|stop|destroy|status <name> [--vm $VM] [--dry-run] [--json] [--resume] [--forget]`.
Each operation is an ordered list of node calls (`--dry-run` prints it, changes
nothing). A node call that exits non-zero ends the run at once.

`create`
:   Per VM, in definition order: `storage-zvol-create` (through
    `HPS::Storage`, on the compute host) for the local leg; `image-fetch`
    (once per image and host; `--from http://<network_dhcp_ip>/images/<image>.qcow2
    --sha256 <sum> --dest /$POOL/enc/images`); `mirror-create <vm>-<disk>` with
    the two leg specs (`local:<zvol>`, `iscsi:<portal>:<iqn>`); `vm-image-write`
    (base image onto the disk); `net-bridge-ensure` when the host's `nets` key
    lacks a network of the VM (the key is extended first, because the node reads
    it; it is put back if the call fails); `vm-define` (`--disk /dev/md/<name>`,
    one `--net <bridge>` per net from the layout). Refuses (3) if the workload
    already exists. `--resume` continues a `creating` workload: steps already
    recorded in `done` are skipped. The leg resolution itself happens on the node
    (`mirror-create` calls `leg-resolve`).

`start`
:   VMs in priority order (1 first): `mirror-assemble`, then `vm-start`. Records
    `running`, `last_owner` (the compute host) and `started_at`.

`stop`
:   Reverse priority: `vm-stop`, then `mirror-stop`. Records `stopped`.

`destroy`
:   Needs the approval below. Allowed in every recorded state. From an unfinished create (`creating`) only what the create attempted (its `done` steps and the one running when it stopped, `attempting`) is stopped, undefined or destroyed; the other steps are skipped with a `note:` line. Reverse priority: `vm-stop` (a VM that is not
    defined is tolerated), `vm-undefine`, `mirror-stop`; then
    `storage-zvol-destroy` of every local leg (through `HPS::Storage`). The
    registry record `workload_<name>` is removed last, only when every call
    succeeded, and replaced by `workload_<name>_destroyed` (`at`, `by`,
    `approved_by`, `forgotten`) for audit; the next `create` removes that
    audit record. The workload approval is then spent (revoked).
    **The definition `workloads/<name>.json` is kept**: destroy removes the
    instance, not the operator's intent, so `create` runs again from the same
    file.

`destroy --forget`
:   As `destroy`, and the definition file is removed too (the audit record
    says `forgotten`). Same approval, same exit codes; `--forget` is refused
    (usage, 2) on every other operation.

`status`
:   Per VM `vm-status` and per mirror `mirror-status`; reports the recorded and
    the node-reported state. A failing node call makes the exit status 1 but
    the report is still printed.

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
`{"at": "...", "by": "operator", "approved_by": "...", "forgotten": false}`; the next `create` removes it.
All registry keys, with their types: `docs/REGISTRY-KEYS.md`.

A `boot: network` VM has `"disks": {}` and `"macs": ["$MAC", ...]`, the MACs
`vm-define` reported (`VM $VM defined mac=$MAC`, one per NIC), which are the
identity the IPS sees when the VM netboots.

States. VM: `creating`, `defined`, `running`, `stopped`. Workload: `creating`
(an unfinished create; carries `done`, the finished step keys), `created`,
`running`, `stopped`, or `partial` when the VMs differ. `start` and `stop` refuse (3) a workload still `creating` (finish it with `create --resume`, or remove it with `destroy`); a workload with no record
is not found (4).

## Approval

`destroy` needs a human approval, bound to the workload name and to the compute
host of the first VM:

```
hps-approve workload-destroy $MAC --workload <name> [--expires SECONDS]
```

Action `workload-destroy` (`HPS::Approval`): `pool` is the workload name, no
disks, wipe 0, default expiry one hour. One approval is enough for the whole
workload: after verifying it, the driver issues a `zvol-destroy` approval for
each local-leg zvol (same host, same `issued_by`, valid ten minutes at most and
never past the workload approval), `HPS::Storage` consumes it, and the driver
revokes it straight after, also when the destroy fails. A missing, expired,
tampered or foreign approval is a refusal before any node call.

## Exit codes and logging

`0` ok, `1` failed (a node call failed), `2` usage, `3` refused (definition,
approval, node refusal, existing workload), `4` not found (definition, record, VM).
Every node call, its exit status and every refusal is logged to stderr and, via
`logger -t hps -p local0.<level>`, to syslog (`HPS_WORKLOAD_NO_SYSLOG=1` turns
syslog off). No log line carries a key, secret or signature.

## Jobs

The root job runner (`hps-jobs`, ADR 0006) accepts `workload-create <name>
[--resume]`, `workload-start|stop|status <name> [--vm $VM]` and
`workload-destroy <name> [--forget]`; `workload-status` runs `hps-workload status <name> --json`.
Environment: `HPS_WORKLOAD_CMD` (default `bin/hps-workload`), `HPS_RUN_CMD`
(`hps-run.sh`), `HPS_RESOURCES` (default `$HPS_BASE/hps-resources`).

## Not verified here

Nothing in this page has run against libvirt, mdadm, ZFS or ctrl-exec; tests use
a recording runner or a shim `hps-run`. The first real run is the lab runsheet.
