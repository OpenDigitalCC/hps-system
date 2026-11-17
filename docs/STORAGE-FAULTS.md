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
3 Guest error policy | No `error_policy` or `rerror_policy`: libvirt's default reports the error to the guest | `vm_disk_error_policy` = `stop`: `vm-define` writes both attributes as `stop` | A paused guest keeps its filesystem; a guest that saw EIO is read-only until it reboots | A paused guest is down until something resumes it. The detection and resume path below is built: `check_vms` reports it, a `guest-paused` issue follows, the healer runs `vm-resume`. `vm-stop` on a paused guest refuses without `--force`
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
3 Guest paused | `vm-start` refused a paused guest (3, unchanged). `vm-stop` ran `virsh shutdown` and waited, so a paused guest timed out unless `--force`. No script resumed a guest. Now: `vm-resume`, and `vm-stop` refuses a paused guest without `--force` | `vm-start:16`, `vm-stop`, `vm-resume`
4 ARC cap | Role SCH: `zfs_arc_max` = `zfs_arc_max_pct` (default 25 %) of RAM, at least 1024 MiB, at boot; shown as `arc_max_mib` in the `RESERVE` line of `hps-node resources` | `node-manager/nixos-26/scripts/host-reserve-apply:226-240`; key in `lib/perl/HPS/ClusterConfig.pm:201`
4 `vm.min_free_kbytes` | Absent. No sysctl is set in any Nix module | grep of `nix/` finds nothing
Monitor: mirror leg | The mdadm monitor's PROGRAM logs `HPS-ISSUE open kind=mirror-leg`; `hps-issue-watch` opens an issue and the healer runs `mirror-rejoin` | `node-manager/nixos-26/boot/hps-md-event.sh`; `docs/ISSUES.md` "Healing"
Monitor: iSCSI session | Raw-line rules open `storage-path` after three `iscsid ... connect failed` in 300 s and resolve on recovery | `lib/hps-issue-rules.conf`, `docs/ISSUES.md` "Shipped"
Monitor: paused guest | None. `check_vms` sampled `--list-running`, so a paused guest dropped out of the `vms` figures without a word. Now it also lists paused guests (below) | `node-manager/nixos-26/plugins/check_vms`
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

Owner ruling 2026-11-15: a guest pauses on a disk I/O error (`vm_disk_error_policy` `stop`, the default) and is resumed, instead of being handed the error. This is that resume, as built. It reuses the monitor and the issue register and adds no daemon. The node side needs a node image build and takes effect at a node's next boot; the IPS side works at once and treats a node that has not got it as "cannot tell", never as "none paused".

## Detect

`check_vms` (node plugin) asks `virsh domstats` once for the running and the paused guests, with `--state`, in the one call that carries its 8 s budget. A guest in the paused state (`state.state=3`) leaves the running figures and the saved sample, and is reported with its reason (`state.reason`, named as `virsh domstate --reason` words, lower case and joined: `ioerror`, `user`, `migrating`, `saving`, `dumping`, `watchdog`, `fromsnapshot`, `shuttingdown`, `creatingsnapshot`, `crashed`, `startingup`, `postcopy`, `postcopyfailed`, `unknown`, or `code<N>` for a code that list does not know).

```datatable
columns: Figure | Meaning
widths: 4.5cm | X
bold: 1
---
`paused=<n>` | The paused guests, printed on every run of this version, 0 included. A node on an older image prints no such figure: that is "cannot tell", and the IPS never reads it as "none paused"
`<vm>_paused_<reason>=1` | One per paused guest, with the reason in the label
Text | `, 1 paused: web (ioerror)` after the running count
`vms`, `<vm>_cpu_pct` and the rest | Unchanged, for running guests only
```

Choice: a guest paused by an I/O error makes the check WARNING (exit 1), because it is an outage nothing else shows; a guest paused for any other reason (an operator's `virsh suspend`, a migration) is reported and the check stays OK. A pause that is not an I/O error is therefore not an issue. There is no CRITICAL after a time limit: the issue turns urgent through the healer's own escalation (below), which is the same "unresolved for long" signal the other kinds use. `vm-status` prints a line `PAUSED <vm> reason=<token>` before the `VM <vm> paused` line of a paused guest (the `VM` line is unchanged), and `hps-workload status` shows `node paused (ioerror)`.

## Report

The monitor logs `check=vms state=WARNING` with the perfdata. A `from=ips` rule in `lib/hps-issue-rules.conf` with the new option `each=1` (the rule acts on every match in the line, the host captured at its start carrying on to the next) opens one issue of kind `guest-paused` per guest named by a `<vm>_paused_ioerror=1` label, keyed by host and guest, severity warning, with the reason as a field; the healer adds the workload name once it finds the guest in a workload record. A marker `HPS-ISSUE open kind=guest-paused host=<h> guest=<g>` works too (keyed the same). No rule resolves it: a line that no longer names the guest is also the line of a node without the figure, so absence proves nothing. The healer resolves by state.

Event lines (`docs/LOGGING.md`): kind `workload`, subject `<workload>/<vm>` (or `<host>/<vm>` when no workload has the guest), state `paused` (standing, warning, urgent once the issue is) repeated every 50 minutes while the issue is unresolved, and `resumed` (clearing, notice) when it resolves, or `stopped` when the guest is found shut off or gone. `unreadable` (standing) says that the state needed to decide could not be read. `hps-log attention` shows the guest while it is paused and drops it when the `resumed` line comes.

## Resume

Node script `vm-resume <vm> [--any-reason]`, allowlisted in `nix/modules/hps-ctrl-exec.nix`.

```datatable
columns: Situation | Result
widths: 6cm | X
bold: 1
---
Not defined | exit 4
Not paused (running, shut off, ...) | exit 3, `REFUSED not-paused`
Paused for a reason other than an I/O error (an operator's pause) | exit 3, `REFUSED operator-paused`, unless `--any-reason`
Paused by an I/O error, a mirror the kernel calls `broken` (`array_state`) | exit 3, `REFUSED broken-mirror <reason>`, even when `mdadm --detail` says clean with both legs back; the way out is `vm-reassemble` (next sections)
Paused by an I/O error, a disk not healthy | exit 3, `REFUSED disk <reason>`: a mirror (`/dev/md/<name>`) not assembled, failed or inactive, or with no leg in sync (`Active Devices` below 1); a zvol whose pool is not ONLINE; a disk that is neither, or no disk to check at all. A degraded mirror with one leg in sync is healthy enough
Guest state or disk list cannot be read | exit 1, nothing resumed
Healthy | `virsh resume`; the guest must be running and still running after a short settle (`HPS_VM_SETTLE`, 2 s), else exit 1; last line `VM <vm> running`; exit 0
```

`--any-reason` skips the reason check only: a guest paused by an I/O error is still checked against its disks. `hps-workload resume-paused <name> [--vm <vm>] [--any-reason]` runs it from the IPS. It is not `hps-workload resume`, which restores a guest that was suspended to a state file (`vm-save`, `vm-restore`): `resume` brings a guest back from a file after a planned stop, `resume-paused` un-freezes a guest that is still in memory on its host. Without `--vm` it looks at each VM first (`vm-status`) and resumes only the paused ones; with `--vm` it calls `vm-resume` as asked and its refusal is the answer (exit 3).

The healer (`HPS::IssueHeal`, `HPS::GuestHeal`) does it by itself for an open `guest-paused` issue, the first try 30 s after it sees it:

```datatable
columns: What it finds | What it does
widths: 6cm | X
bold: 1
---
The host is unknown, or the issue names no guest | needs-human
The workload records the VM or the workload `stopped` or `suspended` | needs-human, no resume: a guest meant to be down is never resumed
A workload record that cannot be read (and none names the guest), or the drain mark of the host cannot be read | `unreadable`: reported, no try spent, looked at again in a minute; never a resume
The host carries the host key `drain` | waits (no try spent, looked at again in a minute)
`vm-status`: running | resolved, `resumed`
`vm-status`: shut off, or not defined | resolved, `stopped`
`vm-status`: paused with no reason line (an older node image), another state, or a reason other than `ioerror` | needs-human: an operator's pause is never resumed automatically
Paused by an I/O error, and a mirror-leg or storage-path issue of the host is still open or healing | waits for it, up to 10 minutes from the opening of the guest issue; then tries anyway, because the node's own disk check decides
Otherwise | `vm-resume`: exit 0 is `healing` and is checked again 30 s later: running resolves it (resolution action `vm-resume <vm>`), paused again is a failed attempt; exit 3 `disk` and any other failure are failed attempts with the backoff of the other kinds (60 s, 2 min, 5 min, 15 min); `operator-paused` is needs-human; exit 4 resolves it
`vm-resume` refused with `REFUSED broken-mirror` | `vm-reassemble <vm>` in the same attempt (next section): exit 0 is `healing`, checked 30 s later like a resume (resolution action `vm-reassemble <vm>`); exit 3 (a leg missing, nothing changed) is a failed attempt with the backoff and the missing leg in the result; any other exit means the guest may be off with its mirror stopped, so needs-human at once
After 6 failed attempts | needs-human and urgent, the last refusal in the trail
```

## A broken mirror: reassemble, then run

When both legs of a guest's md raid1 were lost, the guest pauses (`ioerror`) and, on kernel 6.18, the array is marked `broken` (`/sys/block/mdX/md/array_state`). It then fails every write until it is stopped and assembled again, even when `mdadm --detail` says `clean` with both legs back; a resume pauses the guest again at once. `vm-resume` therefore refuses it as `REFUSED broken-mirror`, and the owner's ruling is that the healer reassembles the mirror (2026-11-16).

Node script `vm-reassemble <vm>`, allowlisted like `vm-resume` (`nix/modules/hps-ctrl-exec.nix`, `node-manager/bundle/allowlist`); no argument but the guest, so the agent runs a preset action and no code comes from the IPS. It acts only when the guest is paused by an I/O error, a disk of it is `/dev/md/<name>` whose `array_state` reads `broken` (a mirror that is not broken is left alone), and both legs the sidecar `/run/hps/mirrors/<name>.json` records resolve through `leg-resolve` (the zvol is there, or the iSCSI session is logged in and the LUN present). Otherwise exit 3 with `REFUSED not-paused`, `not-ioerror`, `no-broken-mirror` or `legs` (naming each leg that is missing), and nothing is changed. Then, in this order: `vm-stop --force`, `mdadm --stop /dev/md/<name>` (not `mirror-stop`, which would log the legs out), `mirror-assemble <name> --leg .. --leg .. --drop-bbl` from the sidecar's legs, and `vm-start` with the priority the guest had. Last line `VM <vm> running`.

The guest is powered off and started, not resumed, and its memory is lost. QEMU holds the md device open for as long as its process exists, paused or not, so `mdadm --stop` cannot succeed before the guest is gone; the lab recovery by hand was the same sequence. The guest boots from its disk, as after a power cut.

`mirror-assemble --drop-bbl` tries the plain `mdadm --assemble` first. Only when that fails does it stop any half-assembled array and retry once with `--update=force-no-bbl`, which clears the bad-block log of each leg, and then it prints `BBL-DROPPED <name>` and a `WARNING` in the log. Lab 2026-11-16: after a double outage both legs had bad-block-log entries, the kernel refused the superblock (`not a valid v1.2 superblock`) and only that update assembled the array. The divergence check of `mirror-assemble` still runs first; the option is not `--force`, and a plain `start` never uses it.

To prove on a node (written without one; the lab evidence is the hand recovery only): with a probe guest on a two-leg mirror, take both legs away for longer than the 15 s timeout, bring them back, and confirm `cat /sys/block/mdX/md/array_state` reads `broken` and the guest is `paused (I/O error)`. Then `hps-workload resume-paused <name>` must exit 3 with `REFUSED broken-mirror`; run `ctrl-exec` `vm-reassemble <vm>` (or let the healer do it) and read `mdadm --stop` succeeding after `vm-stop --force`, `array_state` `clean` after the assemble, whether `BBL-DROPPED` appears, and `VM <vm> running`. A mirror with a leg not logged in must give `REFUSED legs` naming it. A keep-the-memory path (`virsh save` of the I/O-error-paused guest, stop and assemble, `virsh restore`, on a state pool as `vm-save` uses) is not built because a save of that state is not proven; try it by hand first.

## Operator

`hps-issues list` shows the issue; `hps-workload resume-paused <name>` is the manual step, and `hps-issues retry <id>` puts a needs-human issue back for the healer. `hps-workload stop` of a paused guest: `vm-stop` refuses it (exit 3) without `--force`, naming `resume-paused` and `--force`, because a shutdown request cannot be acted on by a frozen guest and forcing it silently would power it off; with `--force` it destroys the guest at once (no graceful wait). A stop with a clean shutdown is `resume-paused` first, then `stop`.

## What needs a node image

`check_vms`, `vm-resume`, `vm-status` (the `PAUSED` line), `vm-stop` (the refusal) and the allowlist in `nix/modules/hps-ctrl-exec.nix` are node-side: they take effect at a node's next boot of the new image. Until then the node prints no `paused` figure, so no issue opens; an issue filed by hand (`hps-issues open --kind guest-paused ...`) finds no reason line from `vm-status` and goes to needs-human rather than being resumed. The IPS side (`hps-issue-watch`, `hps-workload resume-paused`) works at once; `resume-paused` on a node without `vm-resume` fails (exit 1) with the node's refusal.

# A guest that will not start: where to look

`hps-workload report <name> [--vm <vm>]` answers, on one screen and read-only, the three questions an operator has about a guest that will not start, in this order.

Where its storage is
:   Per disk the mirror name, size, and per leg the storage host (name and address), pool, zvol and iSCSI target, and the compute host. They are printed from the IPS's records (the workload record, the definition and the host registry), so they are complete with the compute node and both storage nodes powered off. The mirror sidecar `/run/hps/mirrors/<name>.json` lives on the compute node's tmpfs and is gone with that node; the report does not need it. When the nodes answer, the live facts stand beside the recorded ones: zvol exists, target exported, session logged in, device state, mirror `array_state`. A node that does not answer reads `not reachable`.

Why it will not start
:   The last failed or refused operation with its line verbatim (`REFUSED legs ...` of `vm-reassemble`, `DIVERGED ...` of `mirror-assemble`, `FAILED ...`), where it was recorded, and the open HPS-ISSUEs naming the guest.

What the last errors were
:   The newest error lines with time and source: the events view, failed job records, issue trails, the IPS log and the compute host's syslog.

To assemble a mirror by hand, the report prints the commands with this guest's names: `hps-storage <host> up` for each storage host, then `mirror-assemble <mirror> --leg <spec> --leg <spec>` on the compute host, the same legs `hps-workload start` uses. The legs are the recorded ones, so storage is never lost with the sidecar. `mirror-assemble` refuses diverged legs (`DIVERGED`) and there is no override; read its refusal before anything else is tried. `--json` carries the same facts for the HPS browser (`docs/WORKLOADS.md`, `report`).

# Out of scope

- Raising `replacement_timeout` or any `iscsiadm` timer from 15 s without the measurements above.
- A udev rule that sets `max_sectors_kb` on every iSCSI disk, as a second line behind `leg-resolve` for devices that appear outside it (needs a `.nix` change).
- `vm.watermark_scale_factor`, `vm.compaction_proactiveness` and `vm.min_free_kbytes` on compute nodes: untested, and the failure was on the target.
- The target's own settings on non-HPS NAS hardware, such as the dev host's project NAS: the lever applies to HPS storage hosts only.
- Tuning ZFS (`zfs_arc_max_pct`, `zfs_dirty_data_max`, `volblocksize`) beyond the existing cap.
- Any change to a running node: all of this takes effect at image build and boot.
