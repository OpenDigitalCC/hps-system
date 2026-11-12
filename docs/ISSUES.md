# Issue register

The IPS keeps a register of the problems it has seen that have to be
addressed: a lost mirror leg first. Each problem is an issue with a trail of
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

- On the IPS: `bin/hps-issue-watch`, supervisor program
  `program:hps-issue-watch` running `hps-issue-watch loop` as root. It follows
  every node's log files, opens and resolves issues by the trigger rules, and
  heals mirror-leg issues. Its own lines go to syslog (tag `hps`) as
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
| `kind` | `mirror-leg`, `storage-path`, or any kind a marker names |
| `severity` | `warning` or `urgent` |
| `state` | `open`, `healing`, `needs-human`, `resolved` |
| `opened_at`, `resolved_at` | ISO UTC; `resolved_at` is null until resolved |
| `summary` | one line (the kind and fields, or the operator's text) |
| `fields` | every field of the report (`host` as its short name): `mirror`, `component`, `event`, `leg`, ... |
| `seen`, `last_seen_at` | how often it was reported, and when last |
| `previous` | the id of the resolved issue of the same key, on a re-occurrence |
| `heal` | the healer's `attempts`, `next_at` (epoch), `last_at`, `last_result` |
| `trail` | append-only list of `{at, event, detail}` |

Trail events: `opened`, `reoccurred`, `seen`, `escalated`, `heal` (an attempt
and the node's result line), `check` (a status check), `healing`, `open` (back
to open after a failed heal), `needs-human`, `note`, `resolved` (by the log
line, `mirror-status clean`, or the operator). An entry equal to the one
before it (same event and detail) counts up (`count`, `last_at`) instead of
adding a line; repeats of an open are kept for the first 5 and then only
counted in `seen`; past 300 entries the last entry counts what was not kept.

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
`host` are the fields; `after=N/S` opens only at the Nth match of a key within S
seconds.

Shipped:

| Rule | Opens / resolves |
| --- | --- |
| `marker mirror-leg warning host,mirror` | the mdadm monitor's markers, keyed by host and mirror name |
| kernel `md/raid1:mdN: Disk failure on <dev>, disabling device` | open `mirror-leg` keyed by host and `md` (the kernel name: the healer then checks every mirror of the host) |
| `iscsid: ... connect to <portal> failed`, 3 times in 300 s | open `storage-path` keyed by host (warning) |
| `iscsid: connectionN:M is operational after recovery` / `now` | resolve `storage-path` of that host |

A kernel line and the marker for the same failure are two issues (different
keys); both heal through the same mirror and both resolve when it is clean.

## Following the logs

The watcher reads the newest `<log>/<sender ip>/<YYYY-MM-DD>.log` of every
sender (not `ips/`) every 2 s, from a byte offset, complete lines only, at most
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

## Healing mirror-leg issues

The healer runs in the watcher's loop after each poll (one process, one place
that writes the schedule; a heal of a few node calls delays the next poll by
that long, and lines are only read later, never lost). For each `open` or
`healing` mirror-leg issue whose `heal.next_at` has come, through
`scripts/hps-run.sh` (HPS::Storage's runner, as HPS::Workload):

1. `mirror-status <mirror>` on the issue's host (with no `mirror` field: plain
   `mirror-status`, and every mirror neither `clean` nor `absent` is handled):
   `clean` resolves the issue (`by mirror-status clean`); `resyncing` keeps it
   `healing`; `absent` (not assembled: the VM is stopped) is a failed attempt;
   exit 3 (no such mirror there) is `needs-human`.
2. `degraded`: the workload record (cluster key `workload_<name>`) with a VM on
   that host whose disk is `/dev/md/<mirror>` gives the leg specs (none:
   `needs-human`). The leg to bring back is the one the marker named
   (`leg=<iqn>@<portal>`), else each leg `mirror-status` does not list as a
   member, else every leg (a member is a no-op for `mirror-rejoin`).
   `mirror-rejoin <mirror> --leg <spec>` for each: all exit 0 is `healing`
   (resync from the bitmap; checked again 30 s later until clean); any exit 3
   (DIVERGED or another refusal) is `needs-human` and urgent, never retried;
   anything else is a failed attempt.

Timing: the first attempt 30 s after the healer first sees the issue; after a
failed attempt 60 s, 2 min, 5 min, then every 15 min. Reaching 15 min makes
the issue urgent (once). Issues that are `resolved` or `needs-human` are never
touched; a human resolves them (`hps-issues resolve <id> --by ...`) or the
node's resolve marker does. An issue filed by hand is healed the same way.

## Reading and filing: hps-issues

    hps-issues list [--all] [--json]
    hps-issues show <id> [--json]
    hps-issues open --kind K --key-field k=v [--key-field k=v]... [--severity urgent|warning] [--summary S] [words...]
    hps-issues resolve <id> --by TEXT [words...]
    hps-issues resolve --kind K --key-field k=v... --by TEXT [words...]
    hps-issues note <id> TEXT [words...]

`list` shows `open`, `healing` and `needs-human` issues; `--all` the resolved
ones too; `--json` is `{"issues": [<record>...]}`, the form a page can read.
Words after the options are joined to the text with spaces: the ips-admin gate
passes no space inside one argument. Through the operator API:

    hps-op --cred op.cred hps-issues list
    hps-op --cred op.cred hps-issues resolve 20261112-001 --by replaced the NAS disk

Exit: 0 ok, 1 failed, 2 usage, 3 refused (already resolved), 4 no such issue.
