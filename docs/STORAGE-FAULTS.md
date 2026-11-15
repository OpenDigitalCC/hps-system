---
title: "Storage faults under guests"
subtitle: "Keeping a stalled iSCSI target from becoming guest EIO"
brand: plain
---

# The incident

On 15 November 2026 the dev host's project disk failed. It is an iSCSI LUN served by a small NAS (Linux LIO target on ZFS, 8 GB RAM).

- The target's `iscsi_trx` thread hit order-4 page-allocation failures: memory fragmented by slab and ARC left no contiguous 64 KiB.
- It failed WRITE commands of about 1 MB, the ones that need the largest contiguous buffers.
- The VM host's disk error policy reported the failures to the guest as EIO.
- The guest's ext4 aborted its journal and remounted read-only.
- It came in three bursts over three days, so it is a pattern and not an accident.

HPS has the same shape of data path: storage hosts (SCH) export ZFS zvols over iSCSI (LIO), compute hosts (TCH) log in and build an md mirror across two SCHs per guest disk, and the guests are libvirt/QEMU VMs. An earlier lab finding is the same family: a slow NIC dropped an iSCSI DataOut during an image write, and a pool stall once timed out both legs of the probe mirrors, leaving guest roots read-only.

# The four levers

Today's values are from the main checkout at `dc20b32`. File and line references are in the survey below.

```datatable
columns: Lever | Today | Proposed | Why | Risk
widths: 2.6cm | 3.2cm | 3.2cm | 3.6cm | 3.6cm
bold: 1
text: 4*2 5*2
---
1 Command size on the initiator | Nothing sets `max_sectors_kb`; the kernel default (up to 1 MB per command) applies | `iscsi_max_sectors_kb` = 256, applied by `leg-resolve` once the device exists | A 256 KB command needs a 256 KB contiguous buffer on the target, not 1 MB; fragmentation then fails fewer allocations | More, smaller commands: some throughput cost on large sequential writes (to measure). Applies only to legs resolved after the new script runs
2 Replacement timeout | `replacement_timeout=15`, `noop_out` 5 s and 5 s, `login_timeout` 15 s (owner ruling 2026-11-12) | Unchanged at 15. New key `iscsi_replacement_timeout` (5-600, default 15) so the lab can measure other values | A longer timeout would ride through a short common stall, but it conflicts with the ruling and with md failing a dead leg quickly | A value above 15 delays leg failure and blocks guests for that long. Not changed without the measurements below
3 Guest error policy | No `error_policy` or `rerror_policy`: libvirt's default reports the error to the guest | `vm_disk_error_policy` = `stop`: `vm-define` writes both attributes as `stop` | A paused guest keeps its filesystem; a guest that saw EIO is read-only until it reboots | A paused guest is down until something resumes it, and `vm-stop` on a paused guest needs `--force`. Needs the detection and resume path below
4 Target memory | ARC capped at 25 % of RAM (at least 1024 MiB) on SCH. `vm.min_free_kbytes` is not set | `storage_min_free_pct` = 2: `vm.min_free_kbytes` raised to 2 % of RAM, between 128 and 2048 MiB, never lowered | A higher watermark makes reclaim and compaction start earlier, so contiguous free memory exists when `iscsi_trx` asks | Memory held back from the ZFS ARC and page cache (164 MiB on an 8 GiB host). Does not guarantee order-4 blocks; compaction settings are untested
```

# Survey: what HPS does today

File and line numbers are those of `main` at `dc20b32`, before this change.

```datatable
columns: Lever | Today | Where
widths: 3cm | X | 5.5cm
bold: 1
---
1 Command size | Absent. No `max_sectors_kb`, no udev rule, no sysctl for it anywhere in `node-manager/`, `nix/` or `scripts/` | grep finds nothing
2 Replacement timeout | 15 s, with `noop_out_interval` 5, `noop_out_timeout` 5, `login_timeout` 15. Written to the node record before each login, and set as the iscsid.conf default | `node-manager/nixos-26/scripts/leg-resolve:41-46` and `:106`; `nix/modules/profiles/compute.nix:162-167`; ruling in `CHANGELOG.md:464-470`, measured gaps in `.nonfunctional-report.md:350`
2 md failfast | `--failfast` on create, assemble (sysfs `failfast` on each member) and `--re-add --failfast` on rejoin | `scripts/tests/test_p3_240_iscsi_failfast.bats:92-168`
3 Guest error policy | Absent. The disk element is `<driver name='qemu' type='raw' cache='none' io='native'/>` | `node-manager/nixos-26/scripts/vm-define:451`
3 Guest paused | `vm-start` refuses a paused guest (3). `vm-stop` runs `virsh shutdown` and waits, so a paused guest times out unless `--force`. No script resumes a guest | `vm-start:16`, `vm-stop:98-111`
4 ARC cap | Role SCH: `zfs_arc_max` = `zfs_arc_max_pct` (default 25 %) of RAM, at least 1024 MiB, at boot; shown as `arc_max_mib` in the `RESERVE` line of `hps-node resources` | `node-manager/nixos-26/scripts/host-reserve-apply:226-240`; key in `lib/perl/HPS/ClusterConfig.pm:201`
4 `vm.min_free_kbytes` | Absent. No sysctl is set in any Nix module | grep of `nix/` finds nothing
Monitor: mirror leg | The mdadm monitor's PROGRAM logs `HPS-ISSUE open kind=mirror-leg`; `hps-issue-watch` opens an issue and the healer runs `mirror-rejoin` | `node-manager/nixos-26/boot/hps-md-event.sh`; `docs/ISSUES.md` "Healing"
Monitor: iSCSI session | Raw-line rules open `storage-path` after three `iscsid ... connect failed` in 300 s and resolve on recovery | `lib/hps-issue-rules.conf`, `docs/ISSUES.md` "Shipped"
Monitor: paused guest | None. `check_vms` samples `--list-running`, so a paused guest drops out of the `vms` figures without a word | `node-manager/nixos-26/plugins/check_vms:6`
```

# What this change does

Four cluster keys, each with the proposed default, read where the work is done.

```datatable
columns: Key | Default | Read by | Effect
widths: 3.8cm | 1.6cm | 3.6cm | X
bold: 1
---
`vm_disk_error_policy` | stop | `HPS::Workload` (passes `--disk-error-policy report` only when the key is `report`) and `vm-define` (default `stop`) | `error_policy` and `rerror_policy` on every disk
`iscsi_max_sectors_kb` | 256 | `leg-resolve` | Lowers `queue/max_sectors_kb` of the leg's device after login; never raises it; clamps to `max_hw_sectors_kb`; 0 keeps the kernel's value
`iscsi_replacement_timeout` | 15 | `leg-resolve` | Value written as `replacement_timeout` to the node record
`storage_min_free_pct` | 2 | `host-reserve-apply` (role SCH, at boot) | Raises `vm.min_free_kbytes`; never lowers it; 0 leaves it
```

Every key but the first is read by the node script itself from the IPS over the boot channel, as `host-reserve-apply` already reads its keys. The first goes through the controller because `hps-workload` records the `vm-define` arguments of each create and compares them when it redefines a guest: passing an argument only for the non-default value leaves existing records untouched.

All three node scripts change, so none of this takes effect until the node image is rebuilt and a node boots it. `vm-define` and `leg-resolve` act when next run; `host-reserve-apply` acts at the node's next boot.

Existing guests keep their definition. `vm-define` leaves the policy out of the spec hash while it is `stop`, so a guest defined before the change is reported as already defined and is not refused. It says so in its log and applies the policy when the guest is shut off and redefined with `--replace`.

# Replacement timeout and md leg failure

The two settings act in sequence on one leg. When the connection to a target dies, the NOP-Out ping notices after about 10 s (`noop_out_interval` 5 plus `noop_out_timeout` 5). The replacement timer then queues I/O for `replacement_timeout` seconds while iscsid tries to log in again. At the end of it the queued I/O fails up to md. The lab measured 13 to 17 s from loss to a failed leg and guest gaps of 16 to 22 s with 15 s.

With two legs md should drop the dead one quickly and carry on with the other; that is why 15 s was chosen over open-iscsi's 120 s. The dangerous case is a stall common to both legs, such as a shared switch or NIC, or two targets slowed by the same load. Both timers expire together, and md then behaves as follows (to confirm on the lab, not assumed):

- md fails the first leg whose write fails and marks the array degraded;
- md never fails its last working member, so the write that fails on the last leg returns an error to the guest as EIO;
- with the old policy that EIO is what remounted the guest read-only; with `stop` the guest is paused instead and `virsh resume` retries the request;
- the first leg is then out of the mirror and is brought back by the existing mirror-leg healer from the bitmap.

So the guest policy, and not a longer timeout, is what protects against the common stall. A longer timeout would turn a 20 s stall into 20 s of blocked I/O with no EIO and no degraded mirror, but it also turns a dead target into a 60 s or 120 s hang, which the owner ruled out on 2026-11-12 ("apps can handle outage, not a blocking delay"). The proposal is to keep 15 s and 5/5 until the measurements below show a better value.

Numbers proposed: `replacement_timeout` 15 (unchanged), `noop_out` 5/5 (unchanged), candidates to measure 30 and 60. Nothing here is a claim about what the numbers should be.

## What must be measured on the lab

Nothing below has been run. The lab is the DL360 cluster; a bounded stall is made on a storage host's storage interface (a firewall drop of port 3260 or a `tc` delay, removed after N seconds), never by stopping the target service.

```datatable
columns: Measurement | How | Question it answers
widths: 4cm | X | 4.5cm
bold: 1
---
Common stall matrix | A guest with a two-SCH mirror writing continuously. Stall both SCHs together for 10, 20, 40, 90 s. Repeat with `replacement_timeout` 15, 30, 60 | For each cell: legs failed, EIO seen by the guest, guest paused, writes lost, time to a clean mirror
Single stall | The same, stalling one SCH | Does one slow target cost a leg and a resync for a stall of 20 s that would have recovered?
Policy check | `error_policy=stop` against a forced EIO (a dm-error layer under a test md leg, or both legs dropped past the timeout) | Is the guest paused, does `virsh resume` continue, does ext4 survive?
Command size | 1 MiB writes with `max_sectors_kb` 1024, 256, 128 against a zvol on an SCH with a small RAM budget | Throughput cost of the smaller command; whether order-4 failures in the target's `dmesg` stop
Target memory | Same load with `min_free_kbytes` at the kernel value and at 2 % of RAM; record `/proc/buddyinfo` and `page allocation failure` counts in `dmesg` | Does the watermark keep order-4 blocks free under ZFS load?
Resume path | Pause a guest, run the resume step | Does it come back with the application intact, and how long after the storage returns?
```

# A paused guest: detect, report, resume

Today nothing notices a paused guest and nothing resumes one. The proposal reuses the monitor and the issue register and adds no new daemon. None of it is implemented in this change, because it touches the monitor's line formats (being changed on another branch) and needs a node script that is not allowlisted yet.

Detect
: `check_vms` samples with `--list-running`, which leaves paused guests out. Add a second `virsh` call for paused guests (`domstate --reason` per guest, or `list --state-paused`), and report `paused=<n>` and the names. State WARNING when any guest is paused for an I/O error, CRITICAL when it has been paused longer than a limit. The check stays one `virsh` call away from its 8 s budget, so the paused query has to share it.

Report
: A `from=ips` rule in `lib/hps-issue-rules.conf`, in the pattern of the `zfs-pool` rules, opens an issue of kind `guest-paused` keyed by host and guest from the `vms` check line, and resolves it when the line no longer names the guest. Severity warning, urgent after a limit.

Resume
: A new node script `vm-resume <vm>` (allowlisted in `nix/modules/hps-ctrl-exec.nix`) that resumes only a guest whose reason is an I/O error, and only when `mirror-status` of its disks is not absent. The healer in `lib/perl/HPS/IssueHeal.pm` runs it after the mirror-leg heal has finished and `mirror-status` is clean or resyncing, then checks `domstate`. A guest that pauses again is a failed attempt and follows the healer's existing backoff to `needs-human`.

Operator
: `hps-issues list` shows the issue; `vm-resume` through `hps-run` is the manual step. `hps-workload stop` of a paused guest needs `vm-stop --force`; the stop order should resume first, or force after the timeout.

# Out of scope

- Raising `replacement_timeout` or any `iscsiadm` timer from 15 s without the measurements above.
- A udev rule that sets `max_sectors_kb` on every iSCSI disk, as a second line behind `leg-resolve` for devices that appear outside it (needs a `.nix` change).
- `vm.watermark_scale_factor`, `vm.compaction_proactiveness` and `vm.min_free_kbytes` on compute nodes: untested, and the failure was on the target.
- The target's own settings on non-HPS NAS hardware, such as the dev host's project NAS: the lever applies to HPS storage hosts only.
- The paused-guest check, rule and `vm-resume` script above.
- Tuning ZFS (`zfs_arc_max_pct`, `zfs_dirty_data_max`, `volblocksize`) beyond the existing cap.
- Any change to a running node: all of this takes effect at image build and boot.
