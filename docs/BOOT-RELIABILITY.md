---
title: "Boot Reliability"
subtitle: "Why a node can miss its one PXE pass, and the three layers that stop it staying down"
brand: plain
---

# About this page

A node that is started while the IPS cannot answer gets one DHCP/PXE pass,
fails it, and stays down. On metal that is a firmware boot menu. For a VM it is
the OVMF firmware shell: PXE and HTTP boot entries each "failed to load", then
`EFI Internal Shell`, `Shell>`, and no further DHCP request ever reaches the IPS
(IPS-40, lab 2026-11-15: the CNH VM `s3-ips` was started 20 seconds after the
lab IPS container came up, and sat in the shell for 28 minutes while its
workload record said `running`).

Three layers deal with it. Each is useful alone.

```datatable
columns: Layer | What | Where it runs | Built
widths: 1.5cm | 7cm | 3.5cm | 3cm
bold: 1
---
3 | Do not start into a deaf IPS: `hps-workload start` of a network-boot VM, and `hps-bmc on` and `pxe-once`, wait for the boot services and refuse if they do not answer | IPS | Yes
2 | Notice and recover: a netboot VM or BMC-powered node of this IPS with no iPXE init within a window is reset a bounded number of times, then an issue is opened. Off until an operator enables it per cluster | IPS | Yes (ships off)
1 | Never give up at the firmware: a VM boots an iPXE that retries for ever; on metal the BIOS network retry setting | Node image and BIOS | Design only (below)
```

# Layer 3: the readiness gate

## What is checked

`HPS::BootReady` asks four read-only questions of this IPS.

```datatable
columns: Check | Passes when | Fails when
widths: 2.2cm | 6.4cm | 6.4cm
bold: 1
---
dnsmasq | a `dnsmasq` process exists | none does
dhcp | UDP port 67 is bound on the provisioning address (cluster key `network_dhcp_ip`) or the wildcard | nothing listens there
tftp | UDP port 69 is bound, and `snponly.efi` (UEFI) and `undionly.kpxe` (BIOS) are present and non-empty in the TFTP root (`<config base>/tftp`) | nothing listens, or a first-stage file is missing or empty
http | `boot_manager.sh?cmd=cluster_variable` answers 200 with a body (the same read-only probe `hps-ips-check` uses; `cmd=init` is never probed because it registers the caller) | no answer, another status, or an empty body
```

A check that cannot be looked at (the process table or `/proc/net/udp` cannot be
read, the provisioning address is not in the registry) is `unknown`, never
`pass`. The verdict is `not_ready` when any check failed, else `unknown` when any
could not be looked at, else `ready`.

## The command line

`hps-ips-check --boot-ready [--wait SECONDS] [--json]` (or `bin/hps-boot-ready`
itself) prints one line per check and the verdict. `--wait` keeps checking for up
to that many seconds (0 to 600) until everything answers; the default is one
check.

```datatable
columns: Exit | Meaning
widths: 2cm | 13cm
bold: 1
---
0 | ready: every check passed
1 | not ready: at least one check failed
3 | cannot tell: nothing failed, but at least one check could not be looked at
2 | usage
```

## The gate

`hps-workload start <name>` first checks whether the workload has a VM that
boots from the network (`"boot": "network"`, only the VM named with `--vm` when
given) and from this IPS: it has a NIC on a network of `network_layout` whose
purpose is `provisioning`. A VM whose NICs are all on other networks (the fabric
net of a nested cluster, purpose `emulated-switch`) netboots from its own IPS, is
not gated and does not make the start wait. A VM whose network purpose cannot be
told is gated: waiting is harmless. If a VM is gated it waits, up to `boot_ready_wait_seconds`, for the verdict
`ready`, then:

- ready: the start goes ahead.
- not ready after the wait: `hps-workload` exits 3 and prints
  `start <name> refused: this IPS's boot services do not answer after N s (dhcp:
  ...; http: ...)`. Nothing is sent to a node and the record is unchanged.
- cannot tell: the start goes ahead with a warning on standard error that says
  what could not be checked. The gate guards against a known failure; a check
  that cannot run must not block a start.

`hps-bmc on` and `hps-bmc pxe-once` do the same and exit 3. `--no-boot-wait`
skips the gate on all three. `--dry-run`, `stop`, the other verbs and a workload
with only disk-boot VMs are never gated. A workload job queued through
`hps-jobs` (`workload-start`) runs `hps-workload start` and so is gated too.

## Key

```datatable
columns: Cluster key | Default | Range | Meaning
widths: 4.5cm | 1.7cm | 2.3cm | 6.5cm
bold: 1
---
`boot_ready_wait_seconds` | 60 | 0 to 600 | How long the gate waits for the boot services; 0 checks once. A bad value is warned about and 60 used.
```

# Layer 2: boot-stalled detection and recovery

## What it watches

For each VM of a workload that boots from the network **from this IPS** (see
Scope below), recorded `running`, and for each metal node the IPS powered on or reset through its BMC (host key
`bmc_power_on_at`, written by `hps-bmc on` and `reset`, removed by `off` and
`force-off`): started at T, and no iPXE init recorded after T. The IPS records
every iPXE init as the host key `last_boot_at`. A VM's start time is the
`started_at` stamp of its workload record, and its MACs are the record's `macs`.
An init up to 60 seconds before the stamp still counts, because the stamp is
written when `vm-start` returns, a little after the guest began to boot.

The state is `boot-stalled` when the start is older than the window and no init
followed. `hps-workload status` shows, for a running network-boot VM that has
not reached iPXE, the line `no netboot seen since start (N s)`, from the first
second, so that `running` is not the whole story. If the value cannot be read the
line says `netboot state unreadable (...)`.

## Scope: only a node this IPS can expect to see boot

The rule is positive evidence, never the absence of a boot. The watch acts on a
node only when this IPS can expect to see it boot, and every other node is out
of scope: never reset, never an issue, no `no netboot seen` note.

```datatable
columns: Node | In scope when | Otherwise
widths: 3cm | 7cm | 5cm
bold: 1
---
VM | It boots from the network, has a NIC on a network of `network_layout` whose `purpose` is `provisioning` (the L2 this IPS serves DHCP and TFTP on), and the workload record holds the MAC of that NIC (assigned by this IPS when it defined the VM; a host that netboots with it is registered under it) | Every NIC is on a network of another known purpose: out of scope. A network or MAC that cannot be told: `cannot tell`, below
Metal node | This IPS powered it on or reset it through its BMC (host key `bmc_power_on_at`); the host is registered here | Not watched
```

A nested cluster's VM is a network-boot workload of the outer cluster, but its
only NIC is on a network of purpose `emulated-switch` (the fabric net, `fab`): it
netboots from its own inner cluster's IPS, so this IPS never records its
`last_boot_at` and never will. Judging it by that absence is the fault that
reset healthy VMs on the lab (History, below).

Cannot tell
: A VM whose scope cannot be determined (the definition cannot be loaded,
  `network_layout` cannot be read, a network has no purpose, the record has no
  MAC or a different number of MACs than NICs) is reported: an event line (state
  `unreadable`) and an issue of kind `boot-watch-blind`, which resolves when the
  scope can be told. It is never reset.

An out-of-scope VM that carries `boot_watch` state, or open `boot-stalled` or
`boot-watch-blind` issues (the layout was changed, or an older version of the
watch wrote them), is cleaned up: see Clean-up.

## Baseline: a node already running is not judged

The watch remembers when it was enabled: the start of the `hps-issue-watch`
process, or the scan that saw `boot_stall_window_seconds` change from 0 to a
window. A node whose start is older than that was already running when the watch
first saw it: it is baselined, not judged, however long it has been without a
netboot. Only a node started after the watch was enabled can be judged stalled,
by whoever started it (`hps-workload start`, the watch's own reset, an
operator's restart).

This covers the node this IPS has never recorded a boot for (no `last_boot_at`
ever): it is judged only when it was started after the watch was enabled in the
current episode. An episode the watch itself began (its `boot_watch` state with
the rule-set marker, for the same start) is resumed after a restart of the
process, not abandoned. Setting the key to 0 and back starts a new baseline.

## One reset per scan, and the settings are read every time

```datatable
columns: Rule | Why
widths: 6cm | 9cm
bold: 1
---
The settings are read from the registry at the start of every scan and again before every item that may act | Setting `boot_stall_window_seconds` to 0 stops a scan in progress at its next item, not at the end of the pass (a reset can take a minute)
At most one reset (VM or metal) per scan, then the scan returns to the `hps-issue-watch` loop | The other watcher work runs between resets, and a changed key or a recovered node is seen before the next reset, one scan (15 s) on
```

## The breaker

If more than `boot_stall_max_nodes` (default 1) distinct nodes are newly judged
stalled in the same scan, none of them is reset and none is given up on. The
watch opens one issue of kind `boot-watch-many` and logs one standing line
(`boot`, subject `watch`, state `tripped`): "many nodes look stalled at once:
more likely a fault in the watch or the boot service than in the nodes". Many
nodes failing together point at the IPS, the network or the watch, and a reset
loop over all of them would make it worse. The issue resolves, with a `cleared`
line, in the first scan that has no more than the limit. A node that gave up in
an earlier scan (its issue stands) does not count again. With the limit raised
(`boot_stall_max_nodes` 3) two stalled nodes are reset one per scan.

## Clean-up: nothing outlives its cause

```datatable
columns: Leftover | When | What happens
widths: 5cm | 4cm | 6cm
bold: 1
---
`boot_watch` state without the rule-set marker (`rules: 2`) | Any scan with the watch on | Removed, never resumed: the episode was not begun by these rules. The node is then judged afresh (and baselined if it was already running). The line `state=cleared` is logged
`boot_watch` state, `boot-stalled` and `boot-watch-blind` issues of a node now out of scope | Any scan with the watch on | Removed and resolved; a `cleared` line
A workload-level `boot-watch-blind` issue (record or definition unreadable) after it is readable again | Any scan | Resolved; an `ok` line
All `boot_watch` state, and every open `boot-stalled`, `boot-watch-blind` and `boot-watch-many` issue | The watch is off (`boot_stall_window_seconds` 0): at once, then every 5 minutes | Removed and resolved, each with a `cleared` line
```

The `cleared` line is a clearing state (`docs/LOGGING.md`): it ends a standing
`boot-stalled`, `gave-up`, `unreadable`, `reset-failed` or `tripped` line for the
same subject, so `hps-log attention` cannot show a boot problem for a node or a
watch that no longer exists, while `hps-ips-check --boot-ready` passes.


## Where it lives, and why

It is a tick of `hps-issue-watch`, the same root loop that already runs the issue
healer (`HPS::IssueHeal`), as `HPS::BootWatch`, scanning at most once every 15
seconds. The healer's loop was chosen over the monitor and the jobs runner
because it already holds what recovery needs (the issue register, the runner,
a root process that writes the workload record) and already has the pattern of
a state check that resolves an issue (`om3-hb`). `hps-monitor` only reads and
logs; `hps-jobs` runs requested jobs, it does not watch. A reset can take a
minute or two (the graceful wait of `vm-stop`), during which the issue watcher
does not poll; it reads the log files from where it stopped, so no line is lost.
`hps-issue-watch loop --no-heal` turns the whole watch off.

## What it does

```datatable
columns: Situation | Action
widths: 5cm | 10cm
bold: 1
---
Within the window of the start, or of the last reset | Nothing.
Past the window, resets left, boot services answering | Reset (one node per scan, then the scan returns to the loop). A VM: `stop --force` then `start` (the path `hps-workload` uses, so the record and `started_at` follow). Metal: a BMC `reset`, else `on`. One try is counted.
Past the window, boot services not answering | Defer. No reset and no try is spent: resetting into a deaf IPS only repeats the failure. Said in the log every 5 minutes.
Past the window, resets used up (or `boot_stall_max_resets` is 0, or metal reset is off) | Give up: open the issue `boot-stalled`, once. It names the workload and VM (or the node), the tries and the console command. It becomes urgent after an hour unresolved.
A reset that itself fails | Give up at once, naming what failed.
An init is recorded after the start | Booted. The `boot-stalled` issue resolves (by the healer, with the evidence), and the watch state is cleared.
```

The state the watch keeps is `vms.<vm>.boot_watch` in the workload record (host
key `boot_watch` for metal): `tries`, `last_try_at`, `expect` (the start stamp
after the last reset), `gave_up` and `stalled` (a boot-stalled line was logged for this start, so that a later boot is logged as booted). A start that is not the watch's own (an
operator's stop and start) shows a different stamp and begins a new episode with
no tries counted.

## Never reset

- A VM whose recorded state is not `running`: stopped on purpose, in a stopped
  workload, suspended, creating, failed.
- A VM or node whose start time is missing or unreadable, whose MACs are not
  recorded, or whose `last_boot_at` is not an epoch (or lies in the future).
  That is its own reported case: an issue of kind `boot-watch-blind` names the
  node and what could not be read, and resolves when it can be read again. It is
  never "fine" and never a reset.
- A workload record that cannot be parsed, or one whose definition file cannot
  be loaded (so it is not known whether its VMs boot from the network): the same
  `boot-watch-blind` issue.
- A VM whose compute host carries the host key `drain` (`hps-workload drain`
  stopped its guests on purpose; a reset would fight the drain and its start
  would be refused). If that key cannot be read the VM is reported as
  `boot-watch-blind`, not reset.
- A disk-boot VM.
- A VM that is out of scope (it boots from another IPS), one whose scope cannot be told,
  and one that was already running when the watch was enabled (Baseline).
- Any node while the watch is off, while more nodes than `boot_stall_max_nodes` look
  stalled, or after another node was reset in the same scan.
- Metal, unless `boot_stall_metal_reset` is true: the stall is detected and the
  issue opened, but the node is left alone. See the owner decisions below.

A metal node is watched only after `hps-bmc on` or `reset` succeeded. A later
`hps-bmc status` does not hide the power-on time (it is its own key). A node
powered on by hand, or by a power device that `hps-bmc` did not drive, is not
watched.

## Keys

```datatable
columns: Cluster key | Default | Range | Meaning
widths: 4.8cm | 1.7cm | 2.3cm | 6.2cm
bold: 1
---
`boot_stall_window_seconds` | 0 (off) | 0, or 30 to 86400 | Seconds after the start with no iPXE init before the node is boot-stalled, and the pause between resets. 0 turns the watch off, and is the default. Read at the start of every scan and before every action.
`boot_stall_max_nodes` | 1 | 1 to 100 | The breaker: more nodes than this newly judged stalled in one scan and none is reset; one issue says so.
`boot_stall_max_resets` | 3 | 0 to 20 | Resets before the IPS gives up and opens the issue. 0 only reports.
`boot_stall_metal_reset` | false | true or false | Let the IPS power-cycle a boot-stalled metal node through its BMC. VMs are always reset.
```

A bad value is warned about (in the log, once an hour) and the default used; for the
window the default is 0, so a bad value switches the watch off rather than guessing a window.

## Log lines

The watch writes event lines (`HPS::Event`, `docs/LOGGING.md`): kind `boot`,
subject `<workload>/<vm>` or the host, through one function
(`HPS::BootWatch::_event`) and syslog (tag `hps`). States: `boot-stalled`,
`reset`, `reset-failed`, `gave-up`, `booted`, `cleared`, `tripped`, `unreadable`, `failed`,
`bad-setting`. `boot-stalled`, `gave-up`, `unreadable`, `reset-failed` and `tripped` are
standing, `booted` and `cleared` clear them, and `reset` is a point. `hps-log attention`
shows a stalled node while the boot services do not answer, after a failed
reset and once the watch has given up, and drops it when the `booted` line
comes; a successful `reset` line (a notice) closes the stall until the next
window. Priority `notice` for `reset` and `booted`, `warning`
for the rest. `gave-up` is a warning: the `boot-stalled` issue it opens becomes
urgent after an hour, and the issue register's own line then says so. A standing
line is repeated every 50 minutes while it holds. The readiness gate's refusals
(`hps-workload start`, `hps-bmc on` and `pxe-once`) are notice lines, state
`refused`, kind `workload` (subject the workload) and `power` (subject the host).

## Enabling the watch

The watch ships off (`boot_stall_window_seconds` is 0): a reset is the most
disruptive thing the IPS does by itself, and it is enabled per cluster, on
purpose, after a trial on one disposable VM.

1. `hps-ips-check --boot-ready` exits 0 (the boot services answer).
2. Create a disposable workload with one network-boot VM on the provisioning
   network (a `network_layout` entry of purpose `provisioning`), and leave the
   cluster's other workloads alone. Do not start the VM yet.
3. `hps-cluster-config set boot_stall_window_seconds 180`. The next scan (15 s)
   enables the watch and records the moment: whatever runs now is baselined.
   `boot_stall_max_resets` 3 and `boot_stall_max_nodes` 1 are right for a trial.
4. Start the VM with the boot services stopped (`supervisorctl stop dnsmasq`,
   `hps-workload start <name> --no-boot-wait`), wait one window, and see
   `state=boot-stalled ... boot services do not answer` in `hps-log events --grep
   boot`; start dnsmasq: the next scan resets the VM once, it netboots, and
   `state=booted` follows.
5. Check that nothing else was touched: `hps-workload status` of the other
   workloads (a nested cluster's VMs show no `no netboot seen` note), no
   `boot-stalled`, `boot-watch-blind` or `boot-watch-many` issue
   (`hps-issue list`), and `hps-log attention` shows no `boot` line.
6. Leave it on, or turn it off again with `hps-cluster-config set
   boot_stall_window_seconds 0`: the running scan stops at its next item, and
   the leftovers are cleared.

## History

2026-11-15, the first deploy of this layer on the lab (main 2f84242): the watch
judged every `boot: network` VM of the nested clusters (`s1-*`, `s3-*`, NIC on
the fabric net `fab`) with "no netboot seen 3200 s after the start" and reset
eight of them, because their iPXE init goes to their own cluster's IPS and the
lab IPS never records a `last_boot_at` for them. Setting the window to 0 did not
stop the running scan, which kept resetting for five minutes (about 60 s a VM)
until the process was stopped. Fixed by the scope rule (positive evidence that
this IPS boots the node), the baseline, the settings read before every action, one reset per scan,
the breaker, the clean-up, and shipping the watch off.


# Layer 1: never give up at the firmware

## VMs: design, not built

The failure is OVMF's own: `<boot dev='network'/>` makes it try the PXE and HTTP
boot entries it builds from the NIC once and fall through to the EFI shell. A
VM that can never reach the shell needs a first boot target that does not return.

The design that fits libvirt and the existing build:

1. Build an iPXE EFI binary with an embedded script that retries for ever:

   ```
   #!ipxe
   :retry
   autoboot || goto wait
   :wait
   sleep 10
   goto retry
   ```

   (`autoboot` runs DHCP and chains to the filename the IPS hands an iPXE client,
   `boot_manager.sh?cmd=init`; the IPS's dnsmasq already does this for a client
   that identifies as iPXE.) This is a second output of the existing `flake.nix`
   iPXE build, which today has no embedded script (`docs/IPXE.md`).
2. Pack it as `\EFI\BOOT\BOOTX64.EFI` in a small read-only FAT disk image, built
   in the Nix tree and published with the pin next to `snponly.efi`
   (`<pin>/ipxe/`), so that it follows the same hash check and `hps-pins verify`.
3. `vm-define --boot network --netboot-loader <image>` attaches it as a read-only
   virtio disk with `<boot order='1'/>` and keeps the NIC as `<boot order='2'/>`.
   OVMF boots the image, iPXE loops for ever, and the shell is never reached. The
   image path joins the spec hash, so a definition without it keeps today's
   behaviour and hash. The compute host needs the image: it comes with the node
   image, or `image-fetch` brings it from the IPS.
4. The workload definition (or a cluster key) opts a VM in, default off.

Why it is not built here. Three of the pieces cannot be checked on this host: the
iPXE embedded-script build and the FAT image need a Nix build (this host has no
`nix`, and the gate cannot parse `.nix`); whether OVMF with the q35 profile of the
compute nodes boots a disk image ahead of the NIC as `boot order` says needs a
guest on the lab; and the publishing and fetching of one more file touches
`nix/build.sh`, `supervisor_select_pin_ipxe` and the node image together. A
change that cannot be run before it is merged, in four places, on the boot path
of every network-boot VM, is not clean enough to include unseen. Layers 2 and 3
cover the lab's failure: a VM that misses its pass is reset by the IPS, and a
start into a deaf IPS is refused.

To build it later: the lab test is `vm-define` a throwaway VM with the image,
stop the lab IPS's dnsmasq, start the VM, watch the console log stay in iPXE's
retry loop, start dnsmasq, and see the VM pair without a reset.

## Metal: the BIOS or UEFI network retry setting

A metal node does one network pass per boot attempt, and what happens after a
failure is a firmware setting. Set it to retry the network boot, or the boot
order, indefinitely, so that a node powered on before the IPS is ready comes up
by itself once the IPS answers. Record the setting per hardware model in the
onboarding notes when it is checked on the machine.

```datatable
columns: Hardware | Setting to look for | Checked
widths: 3.5cm | 8cm | 3.5cm
bold: 1
---
HPE ProLiant DL360 Gen9 (lab) | UEFI boot options: a boot order policy of "Retry Boot Order Indefinitely" (rather than attempt once); the network boot first | No: the owner to confirm the menu path and name on the machine
Dell PowerEdge | BIOS boot settings: "Boot Sequence Retry" enabled | No: to confirm per model
Other | The firmware's equivalent of "retry the boot order" or "boot retry"; failing that, a network boot first and a BMC reset by layer 2 | Not applicable
```

The names are what the vendors use for these options; none has been checked in
this lab, so the "Checked" column says so. With layer 2 on, a node that falls to
a menu is power-cycled by the IPS (when `boot_stall_metal_reset` is true), which
does not replace the firmware setting.

# Owner decisions

Metal power-cycling
: `boot_stall_metal_reset` defaults to false: the IPS detects a stalled metal
  node and opens the issue, but does not power-cycle hardware by itself. Set it
  to true to let the IPS reset a node through its BMC, after trying it on one
  node.

Enabling the watch
: Whether `boot_stall_window_seconds` is turned on in a cluster is the owner's
  call, after the trial above. The default stays 0 until then. The window
  (180 s suggested) and the breaker (`boot_stall_max_nodes`, 1) are the
  owner's to tune.

Gate when the check cannot run
: A verdict of `unknown` lets `hps-workload start` and `hps-bmc` go ahead with a
  warning. The alternative is to refuse, which would block starts on an IPS whose
  own check is broken.

Layer 1 for VMs
: Whether to build the retrying iPXE loader described above, and to publish it
  with the pin.

# Lab checks

On the lab IPS, in order:

1. `hps-ips-check --boot-ready`: exit 0 with the four lines `PASS`. Stop dnsmasq
   (`supervisorctl stop dnsmasq`) and it exits 1 naming `dnsmasq`; start it and
   it returns to 0.
2. With dnsmasq stopped, `hps-workload start <workload with a netboot VM>` exits 3
   after the wait; `--no-boot-wait` starts it. Restore dnsmasq.
3. Start a netboot VM and check that `hps-workload status` shows `no netboot seen
   since start (N s)` until it pairs.
4. With the watch enabled (Enabling the watch), stop dnsmasq, start the VM with `--no-boot-wait`, and leave it. After the
   window the log shows `state=boot-stalled`, then `state=boot-stalled ... boot
   services do not answer` (deferred). Start dnsmasq: the next scan resets the
   VM, it netboots, and the issue never opens.
5. A VM that cannot reach the IPS even with the services up (its NIC on a wrong
   bridge, for example) is reset `boot_stall_max_resets` times, one window apart,
   and then a `boot-stalled` issue opens, naming the VM and the console command.
   While the services are down no reset is made and no try is spent, so no issue
   opens: the IPS is the fault, and `hps-ips-check --boot-ready` says so.
6. A VM stopped with `hps-workload stop` is not reset while it is stopped.
7. A VM on the fabric net of a nested cluster is never reset, gated or noted,
   with the watch on; a VM already running when the window key changes from 0
   is not reset however long it has been without a netboot.
