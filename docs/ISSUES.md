# Issue register

The IPS keeps a register of the problems it has seen that have to be
addressed: a lost mirror leg, a lost or returned ZFS pool disk, a storage path
or an OpenSVC heartbeat that fails. Each problem is an issue with a trail of
what happened to it. The IPS fixes what it can by itself and leaves the trail;
what it cannot fix stays open for a human. Nothing is deleted: a resolved issue
is history.

## What runs where

- On each node: whatever notices a problem logs a marker line to syslog,
  which reaches the IPS like every other line (docs/LOGGING.md). The mdadm
  monitor logs, with `logger -t hps-issue`:

      HPS-ISSUE open kind=mirror-leg host=<short host> mirror=<name> component=<dev or -> event=<Fail|FailSpare|DegradedArray> [leg=<iqn>@<ip>:3260]
      HPS-ISSUE resolve kind=mirror-leg host=<short host> mirror=<name> event=<RebuildFinished|RecoveryFinished|SpareActive>

  `DegradedArray` carries `component=-` (mdadm names none); `leg=` is
  optional and last; the resolve is only logged once the array is no longer
  degraded (in practice `RebuildFinished`). Markers come from mdadm events on
  assembled arrays only: a workload stop (the array stopped, then its iSCSI
  sessions logged out) logs none.

- Storage hosts run no ZED, so nothing on the node reports a pool disk: the
  IPS reads the kernel's `zio pool=<p> vdev=/dev/disk/by-id/<disk>-partN
  error=...` lines and hps-monitor's `zpool` check (rules below).

- On the IPS: `bin/hps-issue-watch`, supervisor program
  `program:hps-issue-watch` running `hps-issue-watch loop` as root. It follows
  every node's log files and the IPS's own `ips/hps/` file (hps-monitor's
  results), opens and resolves issues by the trigger rules, and heals
  mirror-leg and zfs-vdev issues. Its own lines go to syslog (tag `hps`) as
  `hps-issue: opened <id> <key>`, `hps-issue: resolved <id> by <...>` and
  `hps-issue: heal <id> <outcome>: <detail>`; supervisor's copy of its output
  is filed under `ips/hps-issue-watch/`.
- `bin/hps-issues`: list, show, and file, resolve or annotate an issue by
  hand. An ips-admin tool (docs/OPERATOR.md): every verb works through `hps-op`.

## The register

One JSON file per issue: `<config>/clusters/<cluster>/issues/<id>.json` (the
active cluster), written through a temporary file and a rename under an
exclusive `flock` on `issues/.lock`. The id is `<YYYYMMDD>-<seq>` (UTC day,
sequence from 001 each day).

| Field | Meaning |
| --- | --- |
| `id` | `20261112-001` |
| `key` | `<kind>:<value>:<value>...`, the values of the kind's key fields in order, e.g. `mirror-leg:tch-002:probe-tch-002-root` |
| `kind` | `mirror-leg`, `storage-path`, `zfs-vdev`, `zfs-pool`, `om3-hb`, or any kind a marker names |
| `severity` | `warning` or `urgent` |
| `state` | `open`, `healing`, `needs-human`, `resolved` |
| `opened_at`, `resolved_at` | ISO UTC; `resolved_at` is null until resolved |
| `summary` | one line (the kind and fields, or the operator's text) |
| `fields` | every field of the report (`host` as its short name): `mirror`, `component`, `event`, `leg`, ... |
| `seen`, `last_seen_at` | how often it was reported, and when last |
| `previous` | the id of the resolved issue of the same key, on a re-occurrence |
| `heal` | the healer's `attempts`, `next_at` (epoch), `last_at`, `last_result`, `last_action` (the last heal action that worked) |
| `resolution` | on a resolved issue: `{at, by, action, result}`, below |
| `urgent_at` | (rules with `urgent_after=S`) the epoch from which the issue, still unresolved, is made urgent |
| `trail` | append-only list of `{at, event, detail}` |

Trail events: `opened`, `reoccurred`, `seen`, `escalated`, `heal` (an attempt
and the node's result line), `check` (a status check), `healing`, `open` (back
to open after a failed heal), `needs-human`, `retry` (`retry by operator <who>`, or `storage <ip> back`, below), `note`, `resolved` (by the log
line, `mirror-status clean`, `zpool status: ...`, or the operator). An entry equal to the one
before it (same event and detail) counts up (`count`, `last_at`) instead of
adding a line; repeats of an open are kept for the first 5 and then only
counted in `seen`; past 300 entries the last entry counts what was not kept.

Every resolved issue carries a `resolution`: what fixed it and the evidence
that it is fixed, so a record reads issue, then resolution.

| Key | Meaning |
| --- | --- |
| `at` | when it resolved (the `resolved_at`) |
| `by` | `healer`, `operator <who>`, `log` (a node's line or marker) or `monitor` (an hps-monitor line, a `from=ips` rule) |
| `action` | what fixed it: the healer's last action that worked (`heal.last_action`), even when the resolve comes later from a check, a marker or the monitor; an operator's `--by` text; `-` when nothing was done |
| `result` | the evidence: the healer's check, the resolving line (tag and message), an operator's `--by` text |

Examples:

- healer, mirror-leg: action `mirror-rejoin probe-tch-001-root --leg iscsi:10.113.1.11:... (re-add from bitmap)`, result `mirror-status clean`;
- healer, zfs-vdev: action `zpool online s1 virtio-s1-sch-001-d3; zpool clear`, result `virtio-s1-sch-001-d3 ONLINE, resilver finished` (`..., no resilver running` when none was seen); the zfs-pool issue it resolves names the same action, result `pool s1 ONLINE (zfs-vdev <id> healed)`;
- log: action `-`, result `iscsid: iscsid: connection2:0 is operational after recovery (9 attempts)`;
- operator: by `operator <who>`, action and result the `--by` text.

The syslog line says both: `hps-issue: resolved <id> by <trail text>; issue:
<key>: <summary>; resolution by <by>: <action>; result: <result>`. Issues
resolved before resolutions were recorded have none (`-` in `list` and `show`).

Rules:

- an open for a key that has an unresolved issue adds to that issue (`seen`),
  never a new one; an urgent report makes it urgent;
- an open after the key's issue was resolved is a new issue with `previous`;
- resolve applies to an issue in any unresolved state (a human fixed it, or the
  node reports it fixed);
- nothing secret is stored: a summary, note or `--by` text that looks like a
  secret (the `hps-log` rule, HPS::Log `is_secret`) is refused, a log line that
  does is stored as `[redacted]`, and a field that does refuses the report.

## Triggers: lib/hps-issue-rules.conf

Plain text, read once when `hps-issue-watch` starts (restart it to apply a
change; `hps-issue-watch check-rules` checks the file). The marker is the
primary mechanism: any `HPS-ISSUE open|resolve kind=<kind> k=v ...` line works
for any kind. A `marker` rule declares the key fields and default severity of
a kind; a kind without one is keyed by host alone, severity warning; a marker's
own `severity=urgent|warning` wins. Raw-line rules catch what nodes do not
report themselves: a Perl regex on `<tag>: <message>`, its named captures plus
`host` are the fields. Options, between the key fields and the regex:

- `after=N/S` (open): opens only at the Nth match of a key within S seconds;
- `urgent_after=S` (open): a new issue records `urgent_at`; still unresolved S
  seconds after it opened, the watcher makes it urgent (once; checked every
  30 s);
- `settle=S` (resolve): the resolve waits S seconds, and an open of the same key
  in that time cancels it (for lines that end and begin again at once);
- `from=ips`: the rule reads the IPS's own `ips/hps/<date>.log` (hps-monitor's
  results), and only it. Node lines go through the other rules and the
  markers; the IPS's lines through the `from=ips` rules only, never a marker.

Only this cluster's hosts count: a line whose host (a captured `host`, else the
line's, short) is neither the IPS itself nor a host of the registry sending
from one of its own addresses (its `IP` or an address its audit recorded, as
`hps-log` reads them) opens and resolves nothing. An IPS can receive another
cluster's forwarded syslog (the lab IPS gets s1's: s1's IPS is the sender, and
s1's host names may even be names of this cluster). The first such line of a
host is logged (`hps-issue: ignoring lines of host ...`), then once an hour.

Shipped:

| Rule | Opens / resolves |
| --- | --- |
| `marker mirror-leg warning host,mirror` | the mdadm monitor's markers, keyed by host and mirror name |
| `iscsid: ... connect to <portal> failed`, 3 times in 300 s | open `storage-path` keyed by host (warning) |
| `iscsid: [iscsid: ]connectionN:M is operational after recovery`, `ConnectionN:M to [...] through [...] is operational now` | resolve `storage-path` of that host |
| `kernel: zio pool=<p> vdev=/dev/disk/by-id/<disk>[-partN] error=...` | open `zfs-vdev` keyed by host, pool and `vdev` (the by-id name as `zpool status` shows it: `-partN` taken off), warning; healed below |
| (`from=ips`) `hps-monitor: host=<h> check=zpool state=WARNING ... <pool>=DEGRADED` | open `zfs-pool` keyed by host and pool, warning |
| (`from=ips`) `... state=CRITICAL ... <pool>=FAULTED\|UNAVAIL\|OFFLINE\|REMOVED\|SUSPENDED` | open `zfs-pool`, urgent |
| (`from=ips`) `... check=zpool state=OK ZPOOL OK - n pools: <pool>=ONLINE` | resolve `zfs-pool` of that host and the first pool listed (an HPS storage host has one pool) |
| `om: [time level ]daemon: hb: ucast: tx: hb#N: begin a send error period for node <peer>...` | open `om3-hb` keyed by host and peer (short), warning, `urgent_after=600` |
| `om: ... end a send error period for node <peer>...` | resolve `om3-hb` of that host and peer, `settle=30` |

The kernel's `md/raid1:mdN: Disk failure on <dev>` is not a rule: the mdadm
monitor's marker reports the same failure by mirror name, and an issue keyed by
the kernel name only duplicated it (s1 drill, 2026-11-12). A zio flood (one line
per failed I/O) and the om3 pairs (one per peer, each logged twice: with and
without om's own time and level) add to one issue per key (`seen`). om3 ends a
send error period and at once begins another when only the error changes (no
route to host, then connection refused): `settle=30` keeps that from resolving
and reopening the issue. om3-hb issues are not healed: the peer is down or
unreachable, and hps-monitor's `osvc_hb` check grades the heartbeat
(docs/MONITORING.md).

## Following the logs

The watcher reads the newest `<log>/<sender ip>/<YYYY-MM-DD>.log` of every
sender, and `<log>/ips/hps/<YYYY-MM-DD>.log` (the IPS's own hps lines, for the
`from=ips` rules; nothing else under `ips/`), every 2 s, from a byte offset, complete lines only, at most
4 MiB per file per poll. The offsets are saved after each poll that read
something in `issues/.watch-state.json`.

- First start, or a state file older than 300 s: every file is followed from
  its current end. Nothing logged before is read, so a restart never replays
  old problems as new issues. The trade-off: a problem reported while the
  watcher was down for more than 5 minutes is not caught until it is reported
  again (the mdadm monitor reports once per event; `hps-issues open` files it
  by hand).
- A state file at most 300 s old is resumed: the lines written while the
  watcher restarted are read, so a supervisor restart misses nothing.
- A sender directory or day file that appears after the start is new: read
  from its beginning. At a day roll the rest of the old file is read, then the
  new one; a line rsyslog writes into the old file after that is not read.
- A file that shrank is read again from its start.

## Healing

The healer runs in the watcher's loop after each poll (one process, one place
that writes the schedule; a heal of a few node calls delays the next poll by
that long, and lines are only read later, never lost). For each `open` or
`healing` mirror-leg or zfs-vdev issue whose `heal.next_at` has come, through
`scripts/hps-run.sh` (HPS::Storage's runner, as HPS::Workload).

mirror-leg issues:

1. `mirror-status <mirror>` on the issue's host (with no `mirror` field: plain
   `mirror-status`, and every mirror neither `clean` nor `absent` is handled):
   `clean` resolves the issue (`by mirror-status clean`); `resyncing` keeps it
   `healing`; `absent` (not assembled: the VM is stopped) is a failed attempt;
   exit 3 (no such mirror there) is `needs-human`.
2. `degraded`: the workload record (cluster key `workload_<name>`) with a VM on
   that host whose disk is `/dev/md/<mirror>` gives the leg specs (none:
   `needs-human`). The legs to bring back are those `mirror-status` does not
   list as active members (a device on no mdadm line but a faulty or removed
   one); of them, the one the marker named (`leg=<iqn>@<portal>`) when it is
   one. An active member is never rejoined (a no-op that left the mirror
   degraded: s1 drill); no leg to bring back is a failed attempt.
   `mirror-rejoin <mirror> --leg <spec>` for each: all exit 0 is `healing`
   (resync from the bitmap; checked again 30 s later until clean); exit 3 with
   a `DIVERGED` line is `needs-human` and urgent, never retried; anything else,
   another exit 3 refusal included (`UNREADABLE ...: no md superblock` while the
   leg's target is down), is a failed attempt and retried.

zfs-vdev issues, through `storage-vdev-online <pool> <vdev>` on the issue's host
(its last lines `POOL <pool> <health>` and `VDEV <pool> <vdev> <state>
resilver=<yes|no>`):

- exit 0, `ONLINE`, `resilver=no`: resolved `by zpool status: <vdev> ONLINE, no
  resilver`. When the `POOL` line says `ONLINE` and no other zfs-vdev issue of
  that host and pool is unresolved, the `zfs-pool` issue of that host and pool
  is resolved too (`zpool status: pool <p> ONLINE`);
- exit 0, `ONLINE`, `resilver=yes`: `healing`, checked again 30 s later (a check
  onlines nothing: the vdev is ONLINE);
- exit 3 with `not present`: the disk is still away; a failed attempt;
- any other exit 3 (no such vdev or pool, a state online does not apply to,
  such as DEGRADED): `needs-human`, urgent;
- anything else (the vdev still not ONLINE after `zpool online`, the node not
  answering): a failed attempt.

zfs-pool issues are not healed; they resolve with their last vdev (above) or by
hps-monitor's OK line.

Timing (both kinds): the first attempt 30 s after the healer first sees the issue; after a
failed attempt 60 s, 2 min, 5 min, then every 15 min. Reaching 15 min makes
the issue urgent (once).

Storage back: a mirror-leg issue whose leg's storage host returns does not wait
out its backoff step (s1 drill, issue 20261112-039: sch-002 back about 16:37,
the 5-minute step held the rejoin until 16:41:31). When a `storage-path` issue
that names a portal resolves, or `hps-storage <host> up` (the `storage-up` job
after a storage host pairs) finishes, every `open` or `healing` mirror-leg
issue with a leg on that portal (the marker's `leg=<iqn>@<ip>:<port>`, or a
leg spec `iscsi:<ip>:...` of its workload disk) gets `heal.next_at` = now, its
attempts unchanged, and the trail entry `retry storage <ip> back`; the healer
tries at its next tick (2 s). `needs-human` issues are not touched. Issues that are `resolved` or `needs-human` are never
touched; a human resolves them (`hps-issues resolve <id> --by ...`) or the
node's resolve marker does. An issue filed by hand is healed the same way.

## Reading and filing: hps-issues

    hps-issues list [--all] [--json]
    hps-issues show <id> [--json]
    hps-issues open --kind K --key-field k=v [--key-field k=v]... [--severity urgent|warning] [--summary S] [words...]
    hps-issues resolve <id> --by TEXT [words...]
    hps-issues resolve --kind K --key-field k=v... --by TEXT [words...]
    hps-issues note <id> TEXT [words...]
    hps-issues retry <id>

`retry` puts an issue that needs a human (or one open or healing) back to
`open` with its heal backoff reset (no attempts counted, the next attempt at the
healer's next tick), and says so in the trail (`retry by operator <who>`): for
when the cause was fixed, or was transient, and the IPS should heal it after
all. A resolved issue is refused (exit 3): a new report opens a new one.
`list` shows `open`, `healing` and `needs-human` issues; `--all` the resolved
ones too, each as `<summary> → resolved by <by>: <action>`; `--json` is
`{"issues": [<record>...]}`, the form a page can read (with `resolution`).
`show` prints the issue, then its `resolution` block (at, by, action, result),
then the trail.
Words after the options are joined to the text with spaces: the ips-admin gate
passes no space inside one argument. Through the operator API:

    hps-op --cred op.cred hps-issues list
    hps-op --cred op.cred hps-issues resolve 20261112-001 --by replaced the NAS disk

Exit: 0 ok, 1 failed, 2 usage, 3 refused (already resolved; retry of a resolved issue), 4 no such issue.
