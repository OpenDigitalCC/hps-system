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
| `class` (workload, top level) | optional, a whole number 1-4, default 3: the workload's class (1 core, 2 customer-facing, 3 ordinary, 4 batch and test), which decides what `drain` does with it. See "Workload classes" |
| `flavour`, `egress` (top level) | optional: the kind of workload and the egress hosts it declares; see "Egress hosts". A declaration grants nothing |
| `access` | optional; `ssh_keys` a list of public key lines, `console` a JSON boolean |
| `memory_mib` | 256-262144 |
| `vcpus` | 1-64 |
| `priority` (per VM) | 1-5; 1 starts first and stops last. Default 1 for a storage provider (a `boot: network` VM with disks of its own: a nested SCH or IPS builds its pool on them), else 3. At one priority providers start first and stop last. See "Stop order on a node" |
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

### The proxy reaches services as well as login shells

The lab segment has no route out but the egress proxy (`lab/egress-proxy.pl`).
A flavour's seed, rendered with `--proxy URL` by the hps-workloads skill, hands
that proxy to everything that can need it, not only to a login shell:

| Where | What the seed writes | Reached by |
| --- | --- | --- |
| `/etc/environment`, `/etc/profile.d/hps-proxy.sh` | `http_proxy`, `https_proxy`, `no_proxy` and the upper-case names | ssh sessions (login or not) and login shells |
| `/etc/systemd/system.conf.d/hps-proxy.conf` | `[Manager] DefaultEnvironment=` with the same six variables | every system service and the jobs it starts (a ctrl-exec agent, a build) |
| `/etc/systemd/user.conf.d/hps-proxy.conf` | the same, for the user manager | rootless services of a user (rootless podman) |
| `/etc/gitconfig` | `[http] proxy = URL` (the file `git config --system http.proxy` writes; written directly, so it holds whether git is installed now or later) | `git fetch` and `git clone` over https from any process |
| `podman.service.d/hps-proxy.conf`, `docker.service.d/hps-proxy.conf` under `/etc/systemd/system/` | `[Service] Environment=` with the same variables; only in the container host flavours (`podman-host`, `odoo-test`) | podman's own service and a Docker daemon the project installs later (a drop-in for a unit that does not exist yet applies when it appears) |

The seed also runs `systemctl daemon-reexec` before it installs anything, so
the manager's `DefaultEnvironment` is in force for the first service that
starts. Without `--proxy` each of these files holds one comment line and the
guest stays offline. `video-edit` is not a container host and gets no podman or
Docker drop-in. A VM made from an older seed is changed by hand (or
re-created); a seed applies once, at the first boot.

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

### Finding workloads, images and addresses

```
hps-workload list [--project <P>] [--json]
hps-workload images [--json]
hps-workload status <name> --json          (per VM: addresses)
```

`list` shows every recorded workload (a `workload_<name>` key of the cluster
configuration; the `_destroyed` audit keys are not workloads): name, project
(from the stored definition; `-` and null when the definition is gone), state,
class, compute host(s), VM count, the first address and `created_at`.
`--project P` keeps one project's. `--json` is `{"workloads": [{name, project,
state, class, hosts, vms, addresses, created_at}]}` with every address as `{vm, net, mac, ip,
source}`.

An address is a DHCP lease: the IPS's dnsmasq leases file
(`/var/lib/misc/dnsmasq.leases`, or `HPS_DNSMASQ_LEASES`; lines `expiry mac ip
name client-id`) matched by the MAC of the VM's NIC (the recorded MACs, in NIC
order, with the layout network of each NIC's bridge). An expired lease is none.
`status --json` gives each VM `addresses: [{net, mac, ip, source:
"dhcp-lease"}]`, the empty list when no NIC holds a lease (a VM on a network
the IPS does not serve, or one that has not asked yet); an address is never
inferred from anything else. The text `status` prints one `address` line per
lease.

`images` lists the catalogue the IPS holds: each `hps-resources/images/<name>.qcow2`
with its size in bytes, modification time and the sha256 of `<name>.sha256`
(null, and `no checksum` in the text, when that file is missing or malformed;
such an image is not in the catalogue for `define` or `create`). `define`
refuses (3), also with `--dry-run`, a VM whose `image` is not in the catalogue,
and the message names `hps-workload images` and the images it holds.

The zvol of a local leg is `<pool>/enc/vm/<workload>-<vm>-<disk>` (guest disks
live under `<pool>/enc/vm`, where `leg-resolve` looks; `storage-zvol-create` makes
that dataset when absent); the mirror is
`<vm>-<disk>` (`/dev/md/<vm>-<disk>`). The portal of a remote leg is its own
`portal`, else the portal of the export recorded on that host (`storage_exports`),
else that host's registry `IP`.

### Egress hosts: allowed per workload, never by the definition

The lab egress proxy (`lab/egress-proxy.pl`) lets everyone reach its default
list and nothing else. A host that one kind of workload needs, and that is
not to be open to every machine, is allowed for that workload's address only
(owner 2026-11-13 and 2026-11-17: Docker Hub's blob CDN
`production.cloudfront.docker.com` for the docker and podman flavours, per
workload, not on the default list).

A definition declares what it needs, and the declaration grants nothing:

```json
{"name": "demo-pods-20261117", "project": "demo", "flavour": "podman-host",
 "egress": ["production.cloudfront.docker.com"], "access": {...}, "vms": [...]}
```

| Field | Rule |
| --- | --- |
| `flavour` | optional, `^[a-z][a-z0-9-]{0,31}$`: the kind of workload (the skill's renderer sets it to the flavour's name) |
| `egress` | optional, a list of at most 16 lower-case host names of two labels or more (no wildcard, no port, no address, no upper case); a repeat is dropped |

`hps-workload egress [--project <P>] [--json]` lists the recorded workloads
whose definition declares `egress`: name, project, flavour, state, the hosts
and the addresses (the DHCP leases of their NICs, see "Finding workloads,
images and addresses"). It reads and changes nothing. `--json` is
`{"egress": [{name, project, flavour, state, egress, addresses}]}`.

The proxy is on the dev host, not on the IPS, so the allowance is made there,
from that output, by `lab/egress-allow`:

```
lab/egress-allow --out /srv/projects/hps/lab/egress-allow.list
```

It runs `scripts/lab-op hps-workload egress --json` (or reads `--input FILE`)
and writes one `IP=host,host` line per workload address. It accepts a host only
when `lab/egress-approved`, the owner's plain list (`<flavour> <host>` per line;
it starts with the one CDN host for `podman-host` and `odoo-test`), has a line
for that flavour and that host. Anything else is refused: the message names the
workload, the host, the flavour and that file, the exit is 3, and the allowances
that are approved are still written. A definition that declares a host the
owner has not approved for its flavour therefore gets nothing, and a
definition cannot add a line to the list. A workload with no address yet is
noted and skipped; run the tool again once it has one.

The proxy takes the file as `--allow-for-file FILE` and reads it at every
connection, so an allowance follows a workload without a restart of the proxy:
run `lab/egress-allow --out FILE` after a create, a destroy or a change of
address. `--allow-for IP=hosts` on the command line still works and is added.

### Running a script and copying an image: `hps-vm`

The hps-workloads skill's `bin/hps-vm` (on ai-dev, beside `hps-ssh`, which it
calls for the ssh) takes two steps a project otherwise writes for itself, so
that one permission rule on one binary covers every project:

```
hps-vm run <project> <vm> <script> [--as <user>]
hps-vm load-image <project> <vm> <image:tag>
```

`run` feeds the local file to `bash -s` on the VM (`sudo -u <user> -H bash -s`
with `--as`). `load-image` streams `docker save` (else `podman save`) of the
image on ai-dev into the VM's `docker load` (root, through sudo) when the VM has
docker, else its `podman load` (rootless). Project, VM, user and image are
checked against strict patterns before anything runs, and the remote commands are
fixed text: nothing a caller passes reaches a shell. It adds verbs only; `hps-ssh`
is as it was.

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
    recorded in `done` are skipped. The image write is recorded the moment
    `vm-image-write` returns. `create --resume --image-written` is an operator
    assertion that the image on the root disk is complete (the create was cut
    off after `vm-image-write` wrote it but before the step was recorded, and a
    plain resume is refused: `/dev/md/<vm>-root has data in its first sector`):
    the resume skips `vm-image-write`, records it as done with
    `image_written_by: operator` on the VM, and says what it skipped (a `note:`
    line; `--dry-run` shows it too). Refused when no image write is pending, and
    for a VM whose disk this create never made. The record also keeps each
    iSCSI leg (`vms.<vm>.disks.<disk>.remote`: `host`, `iqn`, and `dataset`, the
    zvol the storage host exports for that iqn); `create` does not make those
    zvols (the operator does, with `hps-storage <host> zvol-create` and `export`),
    so the record is what `destroy` removes. The leg resolution itself happens on the node
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
:   Reverse priority (consumers before providers at one priority): `vm-stop`, then `mirror-stop`. Records `stopped` and `stopped_at`. A VM that is itself a cluster node (the builder) is then stopped, not down: `hps-monitor` does not call it while its record says `stopped` or `suspended` (docs/MONITORING.md). `vm-stop` waits for the guest's own shutdown and never forces (a paused guest cannot shut down, so `vm-stop` refuses it with 3 and names `resume-paused` and `--force`; with `--force` it is destroyed at once); `stop --force` passes `vm-stop --force` (the graceful wait, then `virsh destroy`) for a guest that cannot shut down, such as one whose root filesystem went read-only.

`suspend [--vm <vm>]`
:   Saves each VM's memory to a file and stops it, so a planned host reboot does not end a long job (see "Suspend and resume"). Per VM, consumers first like `stop`: `vm-save <vm> --state /<pool>/enc/state/<vm>.save`. Nothing else stops. Records `suspended` with `state_file`, `saved_at` and `size_bytes`. A suspended VM refuses `suspend`, `start` and `stop` (3), each pointing to `resume`.

`resume [--vm <vm>]`
:   Per VM in start order: the VXLAN links and `mirror-assemble` (a rebooted host lost both), `vm-status` and, when the host lost libvirt's definition, `vm-define` from the definition and the record (as `start` does, with the same refusal when the definition has changed), then `vm-restore <vm> --state <file>`, which removes the state file. Records `running`. A VM that is not suspended refuses (3). For a guest that is paused in memory (a disk I/O error), not suspended to a file, the verb is `resume-paused`.

`resume-paused [--vm <vm>] [--any-reason]`
:   Resumes a guest the hypervisor paused on a disk I/O error (`vm_disk_error_policy` `stop`, the default; `docs/STORAGE-FAULTS.md`). It is not `resume`: `resume` restores a guest that `suspend` saved to a state file and stopped (`vm-restore`, the guest is not running); `resume-paused` un-freezes a guest that is still in memory on its compute host (`vm-resume`, `virsh resume`). Per VM in start order, `vm-status` and then `vm-resume <vm>` for each VM that is paused (with `--vm`, only `vm-resume` for that VM, and its refusal is the answer). `vm-resume` checks every disk of the guest first (a mirror assembled with a leg in sync, a zvol pool ONLINE) and refuses (3) naming what is wrong, and refuses a guest paused by an operator unless `--any-reason`. A VM that is not paused is left alone and noted (`note: VM <vm> is running, not paused: not resumed`). Changes no record. A suspended VM and a draining host are refused (3). The healer does the same by itself for a `guest-paused` issue (`docs/ISSUES.md`), never for an operator's pause, a VM recorded `stopped` or `suspended` or a draining host.

`destroy`
:   Allowed in every recorded state (who may run it is ctrl-exec's decision, ADR 0007). From an unfinished create (`creating`) only what the create attempted (its `done` steps and the one running when it stopped, `attempting`) is stopped, undefined or destroyed; the other steps are skipped with a `note:` line. Reverse priority: `vm-stop` (a VM that is not
    defined is tolerated), `vm-undefine`, `mirror-stop`; then
    `storage-zvol-destroy` of every local leg (through `HPS::Storage`); then, for
    every iSCSI leg of every disk, on its storage host: `iscsi-unexport <iqn>` and
    `storage-zvol-destroy <dataset>` (from `vms.<vm>.disks.<disk>.remote`; a record
    from before that existed uses the zvol the host exports for the leg's iqn).
    A leg whose host is not in the registry (an external NAS) is left alone, with
    a `note:`. **A storage host that is down**: that leg is recorded as pending in
    the record (`destroy_pending`), `destroy` prints `destroy INCOMPLETE` with the
    leg and the reason and exits 1, and the record stays (the workload is
    'partly destroyed': only `destroy` and `status` are accepted) until a later
    `destroy` removes just the pending legs and completes; `--forget` given the
    first time is kept for then. `--dry-run` lists every call, the leg removals
    included. The
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
    (destroy and create to apply it). Each VM also carries its latest
    utilisation, read (read-only, once per compute host) from the host's newest
    `hps-metrics last` `vms` perfdata (`docs/MONITORING.md`, "Per guest"):
    `--json` gives per VM `"utilisation": {"cpu_pct", "rss_mib", "mem_mib",
    "vcpus", "rd_bps", "wr_bps", "rx_bps", "tx_bps", "sampled_at"}` (`cpu_pct`
    of one vCPU, memory in MiB with one decimal, rates in bytes per second,
    `sampled_at` the check's time, ISO UTC), or `"utilisation": null` with
    `"utilisation_reason"` (the host has no monitor sample in the newest
    window, no `vms` check, or does not list the VM, e.g. it is stopped). The
    text output has one `utilisation` line per VM. The other fields are
    unchanged. A guest's history is `hps-metrics series <host> --guest <vm>`.

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

## Suspend and resume

`hps-workload suspend <name> [--vm <vm>]` writes a running guest's memory and device state to a file on its compute host (`virsh save --running`) and stops it; `hps-workload resume <name> [--vm <vm>]` loads it back (`virsh restore`), and the guest carries on where it left off: a CPU job that was mid-computation continues, with open TCP connections timing out as they would in any pause. The use is a planned reboot of the compute host (an image update, maintenance) under a job that must not start over.

- **Where the state is.** The compute host's pool, dataset `<pool>/enc/state`, file `/<pool>/enc/state/<vm>.save`. `vm-save` creates the dataset on first use under `<pool>/enc`, so it inherits the pool's encryption (the saved memory is encrypted at rest) and is only readable while the pool's key is loaded. A pool is made with `mountpoint=none`, so `vm-save` gives the dataset `mountpoint=/<pool>/enc/state` and `recordsize=1M` (one large sequential file; compression, atime and sync are inherited from the pool) and mounts it; an existing dataset that is not mounted gets the mountpoint set. `vm-save` refuses (3), before touching the guest, when the pool is not imported, `<pool>/enc` does not exist or its key is not loaded (the message names the dataset and says to bring the pool up with `hps-storage <host> up`). The pool is the host's `storage_pool` identity, the same one the local disks use. A host with no pool of its own refuses `suspend` (3) with a message saying what to set. The state survives a reboot of the host (it is on the pool); it does not survive the loss of the pool.
- **Size and time.** The file is about the guest's memory. The dataset needs at least that much free (more than the memory is wise: the device state and the guest's growth add to it); `vm-save` reads the free space of the mounted dataset and refuses (3) with both figures when it is short, and the guest keeps running. `vm-restore` with no state file says whether the dataset is missing, not mounted (pool not imported or key not loaded after a reboot) or mounted and empty of that file. A 40 GB guest takes about 10 minutes to save and about 10 minutes to restore on the lab pool; the guest is stopped for all of it. `vm-save` refuses (3) when the state dataset has less free space than the guest's memory, naming both figures. Run `suspend --dry-run` and check `zfs list <pool>/enc/state` first for a large guest.
- **Mirrors stay assembled.** `suspend` stops nothing but the guest: a mirror stays assembled while the host is up, and its legs are not touched. The disks must not change while the guest is saved, or the restored memory disagrees with them. After a host reboot the md device is gone; `resume` assembles it again before restoring.
- **A reboot of the host.** `suspend`, reboot, then `resume`. The definition the host lost is defined again from the record (the recorded MACs), exactly as `start` does after a reboot.
- **While suspended.** `status` shows the VM as `suspended` with the state file, when it was saved and its size (`state_file`, `saved_at`, `size_bytes` in `status --json`; the node state is `shut off`). `start` and `stop` refuse and point to `resume`.
- **`destroy` of a suspended workload** removes the state file too (`vm-save <vm> --state <file> --discard`), after the VM is stopped and undefined and before the zvols go.

## Workload classes

A definition may carry a top-level `class`: the workload's class, a whole
number 1 to 4, default 3. The class decides what happens to the workload when
its compute host must go down (`drain`, below). It is another field than a
VM's `priority`, which orders start and stop inside one workload.

| Class | Meaning | `drain` does |
| --- | --- | --- |
| 1 | Core: IPS, DNS, syslog, dispatcher, edge firewalls | suspends it (live migration is not built) |
| 2 | Customer-facing services | suspends it (live migration is not built) |
| 3 | Ordinary workloads (default) | suspends it |
| 4 | Batch and test | stops it cleanly |

`define` and `create` refuse (3) any other value, a string or a fraction
included, and the message names the classes. `create` writes the class into
the record (`class`); `list` shows it in the `CLASS` column and `status` in
its first line, and both carry `class` in `--json`. A record made before the
key existed has none: it reads as 3 and is not rewritten by a read. A recorded
value that is not 1 to 4 shows as `?` in `list`, and `drain` refuses until it
is set.

```
hps-workload set-class <name> <1-4> [--dry-run] [--json]
```

`set-class` changes the class after `define` or `create`: in the stored
definition (rewritten as canonical JSON, so a later `create` keeps it) and in
the record of a created workload. Either may be absent, not both (4). It makes
no node call and the guests are not touched. It is logged as one event line (kind `workload`, subject the workload, state
`done`, notice): `set-class <name>: class 3 -> 2 by <operator> (definition,
record)`.

## Drain and undrain

```
hps-workload drain   <host> [--include-nodes] [--dry-run] [--json]
hps-workload undrain <host> [--dry-run] [--json]
```

`drain` empties a compute host before a planned reboot; `undrain` brings its
guests back afterwards. `<host>` is a MAC or a registry hostname.

**What drain does.** It marks the host not placeable, then handles each guest
the workload records say is running there, lowest class first: class 4 is
stopped (`stop`, never forced), class 3 is suspended (`suspend`), class 1 and 2
are suspended as well and each prints `class N: would be live-migrated when
migration exists; suspending`. Inside a class the order is by workload name,
and inside a workload its stop order. Guests that are stopped, suspended or
only defined are listed as `left as it is` and not touched. The actions are the
`stop` and `suspend` of this page, one VM at a time, so their node calls,
refusals and records are the same.

**The mark.** Host key `drain`. While it is there `create`, `start` and
`resume` refuse (3) that host: `compute host <host> is draining (host key
drain) ... Run hps-workload undrain <host>`. `stop`, `suspend`, `status`,
`console` and `destroy` are not placement and still work. There is no
scheduler: a definition names its compute host, so a draining host is refused,
never skipped.

**Node VMs.** A guest that is itself a cluster node or infrastructure is never
suspended: a VM one of whose recorded MACs is a registered host (a nested
node, the IPS's own host), or a `boot: network` VM. While one runs on the host
`drain` refuses (3), lists them and changes nothing. Stop them yourself, or
give `--include-nodes`: they are then stopped cleanly after every other guest,
whatever their class.

**A guest that cannot be handled.** When a `suspend` or `stop` fails (no room
for the state file, a node refusal, a definition that no longer loads) the
guest is reported and left running, and the rest are still handled. `drain`
then exits 5 and says the host is NOT ready for reboot, with what still runs.
Put the cause right and run `drain` again: it handles only what still runs.

**Records that cannot be read.** `drain` reads every workload record of the
cluster. One that cannot be read, has no `vms`, a VM with no host or an unknown
state, a running VM on a host the registry does not know, or a class that is
not 1 to 4 is a refusal (3) naming it, and nothing is changed: an unreadable
record is never taken as "nothing running".

**`--dry-run`** prints the plan and changes nothing: per guest its class,
action, memory and the estimated size of the state file (the guest's memory;
`vm-save` needs that much free on `<pool>/enc/state`).

**What undrain does.** It reverses exactly what `drain` did, from the record in
the host key: it resumes what `drain` suspended and starts what `drain`
stopped, nodes first (they were stopped last), then class 1 to 4. A guest that
was stopped or suspended before the drain, and one `drain` left running, are
not in the record and are not touched. A guest that is no longer as `drain`
left it (destroyed meanwhile, or in another state) is skipped with a note.
When every guest is back the key is removed and the host is placeable again. A
guest that cannot be brought back stays in the record, the mark stays, and
`undrain` exits 5; run it again. `undrain` of a host that is not drained says
so and exits 0.

| Outcome (`outcome` in `--json`) | Exit | Meaning |
| --- | --- | --- |
| `drained` | 0 | Every running guest handled; the host is marked and ready for reboot |
| `guests-left` | 5 | Some guests still run (`still_running`); marked, NOT ready for reboot |
| `nothing-to-do` | 0 | No guest was running; the host is marked and ready for reboot |
| `refused` | 3 | A node VM without `--include-nodes`, or a record that cannot be read; nothing changed |
| `undrained` | 0 | Everything `drain` did is reversed; the mark is cleared |
| `not-drained` | 0 | `undrain` of a host with no mark; nothing changed |
| `incomplete` | 5 | `undrain` could not bring back some guests (`failed`); the record keeps them |
| `plan` | 0 | `--dry-run` with something to do (`nothing-to-do`, 0, with nothing) |

`--json` also gives `host`, `mac`, `key` (`drain`), `guests` (per guest:
`workload`, `vm`, `class`, `action`, `node`, `memory_mib`,
`state_file_bytes_estimate`, `note`, `result`, `error`), `idle` and
`ready_for_reboot`. A host the registry does not know is not found (4).

**The record.** Host key `drain`: `{"state": "draining|drained|guests-left|undrain-incomplete",
"started_at": "...", "finished_at": "...", "by": "operator", "guests":
[{"workload": "...", "vm": "...", "class": 3, "action": "suspend", "node": 0,
"seq": 1, "result": "done", "at": "..."}]}`. `result` is `attempting` (written
before the node call), `done`, or `left` (the action failed, with `error`). An
entry still `attempting` belongs to a drain that died mid-call; the next
`drain` or `undrain` settles it from the workload record.

**Events.** Every drain and undrain, and each guest action, is one event line
(`docs/LOGGING.md`, `hps-log events`). What happens to the host is kind `node`
with the host as subject; what happens to one guest is kind `workload` with the
workload as subject. The text after the marker fields is:
`drain <host>: host marked not placeable (host key drain) by <operator>; N
guest(s) to handle` (notice, `started`), `drain <host>: suspend of
<workload>/<vm> (class 3) ok` (info, `done`), `drain <host>: ... failed; the
guest is left running: <reason>` (warning, `failed`), `drain <host>: N guest(s)
handled; ready for reboot` (notice, `done`), `drain <host>: NOT ready for
reboot, ...` (warning, `failed`: shows in `hps-log attention` until the
`undrain` that follows), `drain <host> refused: ...` (notice, `refused`),
`undrain <host>: resume of <workload>/<vm> (class 3) ok` (info, `done`),
`undrain <host>: mark cleared (host key drain removed); the host is placeable
again` (notice, `done`). The terminal output carries the text alone.

**Limits.** Live migration is not built: a class 1 or 2 guest is off for the
length of the reboot. A suspended guest resumes on the same host only (its
state file is on that host's pool). `drain` acts on what the records say, not
on what the node reports: a guest running outside the records is not seen.

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
script `host-resources`, read-only). It then prints, computed on the IPS from the
workload records placed on that host (running or not), one line:

```
COMMITTED vcpus=<n> mem_mib=<n> guests=<n> free_mem_mib=<n> running_guests=<n> running_mem_mib=<n>
```

the sums of the recorded `--vcpus` and `--memory` of every defined guest on
the host, and `guest_mem_max_mib` (the `RESERVE` line) less the committed
memory (`-` when the node reported none; negative when over-committed). A VM
sized to `free_mem_mib` is accepted by `vm-start` when the others are not
started beyond their own sizes; `running_mem_mib` is the part held by guests the
records say are running.

### The write caps come from discovery

Owner ruling 2026-11-13 (IPS-34 items 18 and 18a): the caps are never fixed
numbers, "so we don't set the live systems too low". Each storage host
measures what its pool can take (`hps-storage create`, or `hps-storage <host>
measure` on a host that has a pool; `docs/CLUSTER-CONFIG.md` "I/O budget",
host keys `storage_pool_write_mbps` and the others in `docs/REGISTRY-KEYS.md`),
and two cluster keys hold fractions of that figure:

- **The image write of a create** (`vm-image-write`) is paced to
  `image_write_fraction` (default 0.5) of the lowest `storage_pool_write_mbps`
  among the hosts of the boot disk's legs. The IPS works the figure out
  (the VM's compute host does not know its storage hosts' figures) and passes
  it as `vm-image-write --mbps-max N`; the run log says `image write of <vm>
  paced to N MiB/s: <fraction> x <figure> of <host>`. A disk none of whose
  leg hosts has a measurement is written unpaced, and the log says so
  (`image write of <vm> is not paced: ...`).
- **A tenant disk's `mbps_max`**: when `hps-workload define` finds a disk with
  no `mbps_max` it writes one into the stored definition, `tenant_write_fraction`
  (default 0.25) of the same lowest figure, whole MiB/s, at least 1, and a
  text `mbps_max_derived` naming the source (fraction, figure, host, date of
  the measurement). `define` (and `--dry-run`) prints the figure and its source
  per disk; `show-definition` shows both in the stored JSON. An `mbps_max` in
  the definition always wins and is never changed. A definition that holds an
  `mbps_max_derived` (it was derived earlier) is derived again at the next
  `define --replace`; when no leg host has a measurement any more the earlier
  figure is kept, not dropped. Do not write `mbps_max_derived` yourself: it
  is refused without an `mbps_max`.

A disk's `mbps_max` is part of the `vm-define` arguments `create` records, so
the derived figure is what a create uses; a definition defined before any
measurement exists has no cap until it is replaced with `define --replace`
(after a destroy) once the hosts are measured. `iops_max` is not derived.

`hps-node resources <host>` prints the host's figures as an `IOBUDGET` line;
`hps-storage <host> status` prints them in full.


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
{"state": "created", "class": 3, "created_at": "...", "by": "operator",
 "vms": {"$VM": {"host": "$NODE", "state": "defined",
                 "disks": {"root": {"md": "/dev/md/$VM-root", "legs": ["local:...", "iscsi:..."]}},
                 "last_owner": "$NODE", "started_at": "...",
                 "seed_sha256": "<hex, only for a VM with a seed>"}}}
```

After `destroy`, cluster key `workload_<name>_destroyed` is
`{"at": "...", "by": "operator", "forgotten": false}`; the next `create` removes it.
Host key `drain` ("Drain and undrain"): present while the host is drained.
All registry keys, with their types: `docs/REGISTRY-KEYS.md`.

A `boot: network` VM has `"disks": {}` and `"macs": ["$MAC", ...]`, the MACs
`vm-define` reported (`VM $VM defined mac=$MAC`, one per NIC), which are the
identity the IPS sees when the VM netboots. A `boot: disk` VM gets `macs` from
`vm-status` at its first `start` (or its first re-define). Every VM created
since the re-define landed also has `"define": [...]`, the `vm-define`
arguments `create` used, against which a re-define checks the definition.

States. VM: `creating`, `defined`, `running`, `stopped`, `suspended` (with `state_file`, `saved_at`, `size_bytes`). Workload: `creating`
(an unfinished create; carries `done`, the finished step keys), `created`,
`running`, `stopped`, `suspended`, or `partial` when the VMs differ. `start` and `stop` refuse (3) a workload still `creating` (finish it with `create --resume`, or remove it with `destroy`); a workload with no record
is not found (4).

## Authorisation

Authorisation is ctrl-exec's alone (ADR 0007, owner ruling 2026-11-11): who may
run `hps-workload` is decided there. An operator reaches it through the
`ips-admin` allowlist and the operator API's auth hook (`docs/OPERATOR.md`), or
runs it as root on the IPS.

## A guest paused by a disk error

`vm_disk_error_policy` `stop` (the default) makes libvirt pause a guest whose disk I/O fails, instead of giving it EIO that would remount its filesystem read-only. A paused guest is down until something resumes it. `hps-monitor` shows it (`check_vms` is WARNING, `paused=<n>`), the register opens a `guest-paused` issue per guest and the healer resumes it with the node script `vm-resume` once its disks are healthy (`docs/ISSUES.md`). By hand: `hps-workload resume-paused <name> [--vm <vm>] [--any-reason]`. `hps-workload status` shows `node paused (ioerror)` and `pause_reason` in `--json`. Stopping a paused guest: `vm-stop` refuses without `--force`; resume it first for a clean stop. Event lines: kind `workload`, subject `<workload>/<vm>`, states `paused` and `resumed` (`docs/LOGGING.md`).

## Exit codes and logging

`0` ok, `1` failed (a node call failed), `2` usage, `3` refused (definition,
policy, node refusal, existing workload), `4` not found (definition, record, VM,
host). `drain` and `undrain` add `5` guests left (still running after `drain`,
not brought back by `undrain`). `drain` of a host with no running guest exits `0`:
the host is marked and ready, and `--json` `outcome` says `nothing-to-do`.
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
`drain` and `undrain` have not run against a host: their guest actions are the
`stop`, `suspend`, `start` and `resume` above.
