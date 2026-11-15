---
title: "IPS Logging"
subtitle: "Where each log lands, the event lines, rotation and the hps-log verbs"
brand: plain
---

# About this page

Every IPS service logs through syslog. rsyslog (in the IPS container) receives
local messages on `/dev/log` and node messages on port 514 (UDP and TCP), and
files them under `$HPS_LOG` (default `/srv/hps-log`).

The log has three views of one stream, so that an operator, or an AI agent with
a small token budget, learns "is anything wrong, and what happened" from a few
short lines without scanning the full audit trail:

Events
: The lines an operator follows: jobs, pairing, workloads, issues, monitor state
  changes, power actions. One line each, in a fixed vocabulary
  (`events.log`, `hps-log events`, `hps-log attention`).

Audit
: Every ctrl-exec call and every operator call with its identity (`audit.log`,
  `hps-log audit`). Kept and searchable, never in the events view.

Everything else
: The per-host and per-service day files, for investigation. Scanned as and when
  required, and kept for a week.

`metrics.log` holds hps-monitor's results for `hps-metrics`.

# What goes where

```datatable
columns: Kind of line | Examples | File
widths: 3cm | 7cm | 5cm
bold: 1
---
Audit | ctrl-exec-api, ctrl-exec-agent and ctrl-exec-dispatcher lines (ACTION=, REQID=, RTT=); hps-auth-hook OPERATOR, ALLOW and DENY lines; ips-admin run and end lines | audit.log only
Metric | hps-monitor host=, check= and tick lines | metrics.log, and the day file ips/hps/<date>.log
Event | a marker line (HPS-EVENT or HPS-ALERT) of an IPS program, and the derived lines below | events.log, and the day file of its program
Debug and the rest | hps_log function chatter, dnsmasq, lighttpd access lines, OpenSVC, kernel and systemd lines, console captures, node syslog | the day files ips/<date>.log, ips/<program>/<date>.log and <ip>/<date>.log
```

Audit lines are routed by program name before the day files, so they are in
`audit.log` and nowhere else. Marker lines and monitor lines are copied: they
stay in their day file as well (hps-issue-watch reads the monitor lines there).

# Where each file lands on the IPS

```datatable
columns: Source | File
widths: 6cm | 9cm
bold: 1
---
Audit programs | $HPS_LOG/audit.log
hps-monitor results | $HPS_LOG/metrics.log
Event lines | $HPS_LOG/events.log
dnsmasq (DNS) | $HPS_LOG/ips/dnsmasq/<date>.log
dnsmasq DHCP | $HPS_LOG/ips/dnsmasq-dhcp/<date>.log
dnsmasq TFTP | $HPS_LOG/ips/dnsmasq-tftp/<date>.log
lighttpd (access, error and CGI stderr) | $HPS_LOG/ips/lighttpd/<date>.log
chronyd | $HPS_LOG/ips/chronyd/<date>.log
supervisord program output | $HPS_LOG/ips/supervisord/<date>.log
hps_log (CGI and API scripts, tools) | $HPS_LOG/ips/hps/<date>.log
hps-jobs, hps-monitor, hps-issue-watch, hps-log-rotate | $HPS_LOG/ips/<program>/<date>.log
Anything else local (rsyslogd, OpenSVC, ...) | $HPS_LOG/ips/<date>.log
A node's syslog | $HPS_LOG/<node ip>/<date>.log
supervisord's own log | $HPS_LOG/supervisord.log (a file; supervisord cannot log to syslog)
```

`hps_log` sends to syslog (tag `hps`, facility `local0`) whenever `/dev/log`
exists. Only when syslog is unavailable does it fall back to
`$HPS_LOG/cluster-<name>.log` or `$HPS_LOG/hps-system.log`.

A node forwards its syslog to the IPS on port 514. rsyslog files each node by
source address, in the format `<timestamp> <source ip> [<hostname>] <tag>
<message>`. Compute nodes also write one line per mirror-leg failure and
recovery with tag `hps-issue` (`HPS-ISSUE open|resolve kind=mirror-leg ...`, from
the mdadm monitor; format in `docs/WORKLOADS.md` "Losing a leg").

The views are written by rsyslog in these forms:

```
audit.log    <rfc3339 time> <sender ip> [<host>] <tag> <message>
metrics.log  <rfc3339 time> metric <host> <tag> <message>
events.log   <rfc3339 time> <host> HPS-EVENT pri=... kind=... subject=... state=... <text>
```

# Event lines

An event is one syslog line whose message carries a marker and four fixed
fields, in this order, then free text:

```
HPS-EVENT pri=<info or notice> kind=<kind> subject=<subject> state=<state> <text>
HPS-ALERT pri=<warning or urgent> kind=<kind> subject=<subject> state=<state> <text>
```

The marker follows from the priority: `HPS-ALERT` is every line that needs
attention, so `grep -F HPS-ALERT events.log` is the whole attention filter. The
priority is in the line because the IPS's rsyslog files no syslog priority and
many tools share the tag `hps`, so a tag cannot carry it. The text starts with
the emitting tool (`hps-issue: opened ...`) and keeps the wording that readers
already parse. The words below are a fixed list (`lib/perl/HPS/Event.pm`): a
line with another priority, kind or state is not an event.

## Priorities

```datatable
columns: Priority | Marker | Syslog level | Meaning
widths: 2.5cm | 3cm | 3cm | X
bold: 1
---
urgent | HPS-ALERT | err | Needs a person now: a critical check, an escalated or needs-human issue, a node that could not be paired.
warning | HPS-ALERT | warning | Something is wrong: a bad check, an open issue, an unreachable node, a failed operation.
notice | HPS-EVENT | notice | Something happened that an operator follows: a job ended, a workload operation done, a pairing, an issue resolved, a refusal.
info | HPS-EVENT | info | Context: a service started, a heartbeat, a node stopped on purpose.
```

## Kinds

```datatable
columns: Kind | About
widths: 3cm | X
bold: 1
---
issue | The issue register (`hps-issues`): open, escalated, needs-human, resolved.
monitor | hps-monitor: a host unreachable, reachable again, pair failed, stopped; a check that is warning, critical, unknown or ok again. The subject is the host, or host/check.
workload | A `hps-workload` operation: the subject is the workload name.
job | A privileged job of `hps-jobs`: the subject is the job kind and its first argument.
pairing | A node's pairing: approved, refused, held. The subject is the host key (MAC).
storage | A storage operation (derived line).
node | A node powered on, off, up or down, or faulted (derived lines).
power | A BMC power action (derived line).
boot | iPXE initialisation and boot (derived lines); the boot-stalled watch (`HPS::BootWatch`): the subject is the workload/VM or the host.
service | An IPS program: started, stopped, alive (the monitor's heartbeat), failed.
log | The log's own housekeeping (rotation), and any local program error (derived line).
auth | Reserved for operator-call refusals.
```

## States

A state belongs to a class. The class decides how `hps-log attention` reads it.

```datatable
columns: Class | States | Meaning
widths: 2.5cm | 7cm | X
bold: 1
---
standing | open, escalated, needs-human, warning, critical, unknown, unreachable, pair-failed, boot-stalled, gave-up, unreadable, reset-failed | The problem holds until a clearing line of the same kind and subject. The emitter repeats it every 50 minutes.
clearing | resolved, ok, reachable, stopped, booted | The subject is well again, or stopped on purpose.
point | started, ended, done, failed, refused, error, requested, defined, created, destroyed, on, off, up, down, paired, held, rotated, reset, bad-setting | Something that happened once. At warning or urgent it stays a problem until a later line of the same kind and subject that does not need attention.
```

A subject has no space and no equals sign (other characters become an
underscore; an empty one is `-`), at most 128 characters.

## Priority and the standing problems

`hps-log attention` reads only `events.log`. The newest line of each kind and
subject decides: a line whose priority is warning or urgent, and whose state is
not a clearing one, is an open problem; a later line of the same kind and
subject that does not need attention closes it. So a standing problem must keep
being written, and the emitters repeat it on a fixed period of 50 minutes
(`HPS::Event::REMIND`), shorter than the default window of one hour:

- the issue watcher repeats every unresolved issue (`open`, `escalated` or
  `needs-human`);
- the monitor repeats a check that is still not OK, and a host that is still
  unreachable or pair-failed (every 10 minutes);
- the monitor writes a heartbeat (`kind=service subject=hps-monitor state=ok`)
  every 50 minutes, even with `monitor_interval_seconds` 0, so that a quiet
  cluster still has lines in the window. No line at all in the window means an
  emitter is not running, and `attention` says it cannot tell.

## Who writes event lines

Converted to the marker, in this tree:

```datatable
columns: Emitter | Lines
widths: 4cm | X
bold: 1
---
Issue register (`HPS::Issues`, `hps-issue-watch`, the healer) | opened (warning or urgent), resolved (notice), escalated (urgent), needs-human (urgent), and the reminder of every unresolved issue.
hps-monitor | UNREACHABLE (warning), REACHABLE (notice), PAIR_FAILED (urgent), STOPPED (info); a check whose state changed or still holds (warning or urgent) and its recovery (notice); started, stopped, run failed, tick skipped, heartbeat.
hps-workload (`HPS::Workload`) | the result of every operation except `status` and `console`: done (notice), refused (notice), failed (warning). `set-class`: done (notice).
hps-workload drain and undrain (`HPS::Workload::Drain`) | kind node, the host as subject: started (notice), done (notice), refused (notice), and failed (warning) when a drain leaves guests running or an undrain does not bring them all back. Each guest action is kind workload with the workload as subject: done (info), failed (warning).
Boot-stalled watch and readiness gate (`HPS::BootWatch`, `HPS::BootReady`; `docs/BOOT-RELIABILITY.md`) | kind boot, the workload/VM or host as subject: boot-stalled (warning, also while the boot services do not answer), reset-failed and gave-up (warning), unreadable (warning), booted (notice, clears them), reset (notice), failed and bad-setting (warning). The standing ones repeat every 50 minutes while they hold. A start or power-on refused because the boot services do not answer (`hps-workload start`, `hps-bmc on` and `pxe-once`): refused (notice), kind workload or power. `hps-ips-check --boot-ready` writes no line.
hps-jobs | a job that ended (notice, or warning when its exit status is not 0) and a job refused at once (notice).
Pairing (`ce_approve`) | approved (notice), refused or gave up (warning).
hps-log-rotate | rotated (notice) and any error (warning).
```

Left on the derived table: the emitters below are node-side images, shell
tools with many exit paths, or programs this tree does not own, so a marker
would not be a small change. rsyslog derives an event line from them (subject
`-`, the original text after the marker, the first matching row wins; the table
is `RSYSLOG_DERIVED_EVENTS` in `lib/functions.d/create-config-rsyslog.sh`). A
tool that gains its own marker leaves the table.

```datatable
columns: Row | Matches | Priority, kind, state
widths: 2.5cm | 7.5cm | 5cm
bold: 1
---
ipxe-init | iPXE Initialisation requested | info, boot, requested
boot | NixOS network boot: or held: booting audit image | info, boot, started
init | host_init_result stored | info, boot, done
up | Reached target Multi-User System (a node's console) | info, node, up
off | reboot: Power down or Reached target System Power Off | info, node, off
down | Stopping HPS: stop guests | info, node, down
held | is HELD, or a console line saying held for onboarding | notice, pairing, held
bmc | hps-bmc: action= other than action=status | notice, power, done
node-fault | hps-node: with FAULT | warning, node, error
node | hps-node: | notice, node, done
storage | hps-storage: with exit | notice, storage, done
ips-check | hps-ips-check FAIL or summary | warning, service, failed
error | any other local line at syslog severity err or worse, except hps-monitor lines | warning, log, error
```

# Rotation and retention

`hps-log-rotate loop` is a supervisor program of the IPS (there is no cron in the
container). Each pass does three things, in this order.

Rotate
: Once per local day, and once at its first run, each of `events.log`,
  `metrics.log` and `audit.log` that holds lines is renamed to
  `<name>-<yesterday>.log` (`<name>-<date>.<n>.log` when that name is taken) and
  rsyslogd is sent HUP, so it opens a fresh file. The day is noted in
  `$HPS_LOG/.log-rotate-state` only when the HUP succeeded, so a failure is
  retried at the next pass.

Compress
: A rotated view file, and a per-host or per-service day file of an earlier day,
  that has been untouched for 10 minutes is gzipped (gzip, because core Perl
  reads it). Today's day file is never touched.

Prune
: A file whose date (in its name, not its mtime) is more than the retention
  days before today is deleted, and a directory left empty goes with it.

```datatable
columns: Files | Cluster key | Default (days)
widths: 7cm | 5.5cm | 2.5cm
bold: 1
---
events.log and events-<date>.log.gz | log_events_retention_days | 365
metrics.log and metrics-<date>.log.gz | log_metrics_retention_days | 30
audit.log and audit-<date>.log.gz | log_audit_retention_days | 14
Day files: ips/<date>.log, ips/<program>/<date>.log and <ip>/<date>.log | log_retention_days | 7
```

The keys are whole numbers from 1 to 3650, read at every pass
(`hps-cluster-config set log_audit_retention_days 30`); a value outside the range
is reported as an error event and the default is used. A size cap is not part of
this: a key `log_max_gib` is not implemented.

`hps-log-rotate run [--dry-run] [--force]` is one pass by hand (`--dry-run`
lists the renames, compressions and deletions; `--force` rotates the views now).
Files that are not dated views or day files (`supervisord.log`, the lab's
`all.log` and `all-<date>.log.gz`) are never touched.

# Reading the logs: hps-log

`hps-log` reads these files. It is read-only and an ips-admin tool, so an
operator runs it through `hps-op` (`docs/OPERATOR.md`); the cluster browser's
"Recent log" group calls it.

    hps-log attention [--since 1h] [--json]
    hps-log events [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]
    hps-log audit [--lines N] [--since T] [--grep WORD] [--json]
    hps-log host <mac|hostname> [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]
    hps-log ips [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]

`attention`
: Is anything wrong, from `events.log` alone: one header line with the counts of
  open problems by priority, then one line per open problem, urgent first, at
  most 20 (the rest is counted). `--since` defaults to `1h`. The exit status is
  the answer: 0 nothing needs attention, 10 attention, 11 the events could not
  be read. A missing `events.log`, an empty one, a damaged rotated file and an
  hour with no event line at all are each reported by name (`absent`, `empty`,
  `unreadable`, `silent`) and exit 11: an unreadable file is never "no
  problems". `--json` gives `{status, window_minutes, events, counts,
  problems:[{pri, kind, subject, state, host, time, first, lines, text}], more,
  newest, reason}`.

`events`
: The event lines, newest last, in the compact form `<time> <pri> <kind>
  <subject> <state> <host>: <text>`.

`audit`
: The audit records of `audit.log` and its rotated files, in the form of the
  other verbs.

`host`
: A MAC in any form, a registry `HOSTNAME` or an FQDN. A node is filed by the
  address it sent from, so its lines are read from every address the registry
  knows for it: its current `IP`, then each IPv4 address its stored audit
  recorded (the audit boot's DHCP address). The directories are merged by time.

`ips`
: `ips/<date>.log` (rsyslogd, OpenSVC), `ips/hps/<date>.log` (`hps_log`) and
  `ips/dnsmasq-dhcp/<date>.log` (the DHCP leases: `hps-log ips --grep DHCPACK` is
  how the browser finds an address). hps-monitor's per-check results are left
  out (a line per check per node every tick; `metrics.log` keeps them).

The options are common. `--lines` is 1 to 500, default 50, newest last.
`--since` is 1 to 43200 minutes, or a number with `m`, `h` or `d` (`30m`, `1h`,
`2d`); rotated and compressed files are read as far back as it asks. `--grep` is
one word, case-insensitive. `--min-level warning` keeps the warnings and errors,
`--min-level error` the errors; `--lines` then counts the lines that pass (the
browser's "Recent log" opens on this). A call reads at most 64 MiB of log
(`truncated` says when it stopped there); of a gzipped file the newest 64 MiB
are read.

`level` (error, warning, info) of a line is read from the text: the day files keep
no syslog priority. An event line says its own: urgent is error, warning is
warning, notice and info are info. In other lines "No space left", "failed",
"refused" and `state=CRITICAL` are errors; "warning", "degraded", "timed out"
warnings; a count ("0 failed", "fail=0") is neither.

```datatable
columns: Exit | Meaning
widths: 2cm | X
bold: 1
---
0 | Done. For attention: nothing needs attention.
1 | Failed.
2 | Usage.
4 | No such host.
10 | attention only: something needs attention.
11 | attention only: the events could not be read (absent, empty, unreadable, silent).
```

## Redaction

A line is never printed when it may carry a secret; its message becomes
`[redacted]` (its time and tag stay). The rule: any word of the line (runs of
`A-Z a-z 0-9 _`) matches the cluster-config secret-name rule
(`HPS::ClusterConfig::secret_name_re`: `secret`, `passw`, `token`, `credential`,
`psk`, `private`, or `key` as a whole word or a `_key_` part), or the line holds
a PEM marker (`-----BEGIN ...-----`), an operator token (`hpsop_...`) or 64 hex
digits in a row (a raw key). `--grep` matches after redaction, so it cannot be
used to probe a withheld line. A redacted line has level info, so `--min-level`
never shows one; an `attention` problem with a withheld text shows
`[redacted]`. The rule is deliberately wide: kernel lines such as "Key type
asymmetric registered" are withheld too.

# Watching

Operator watching a netboot (one node):

    tail -f $HPS_LOG/$NODE_IP/$(date +%Y-%m-%d).log

Operator following what matters, on the IPS:

    tail -f $HPS_LOG/events.log

`hps-issue-watch` follows every node's file the same way and turns the
`HPS-ISSUE` marker lines (and a few raw kernel and iSCSI lines) into entries of
the issue register: `docs/ISSUES.md`. Its `from=ips` rules read hps-monitor's
lines from `ips/hps/<date>.log`, which is why those lines stay there.

# Deploy on an existing IPS

The tree is read by the IPS from `HPS_SYSTEM_BASE`, so a new tree is in place
once it is mounted; the services below load their code and configuration at
start.

1. Restart the IPS so that it regenerates `rsyslog.conf` and `supervisord.conf`
   (`create_config_rsyslog` and `supervisor_configure_core_services` run at each
   start, and a program block that is already there is not added twice). That
   restarts rsyslogd (the new views and routing), hps-jobs, hps-monitor and
   hps-issue-watch (the new event lines and reminders), and starts
   `hps-log-rotate`. Without a container restart: regenerate both files, then
   `supervisorctl reread`, `update`, and restart `rsyslogd`, `hps-jobs`,
   `hps-monitor` and `hps-issue-watch`.
2. Existing files stay. Files written by the old routing (`ips/ctrl-exec-api/`,
   `ips/ctrl-exec-agent/`, `ips/ips-admin/`) are not written again and are
   gzipped and deleted by their date like any day file (7 days). A lab
   `events.log` and `metrics.log` in the old collector form
   (`<time> <event> <host> <tag> <msg>`) are still read: `hps-log` and
   `hps-metrics` understand both forms. The first pass of `hps-log-rotate` finds
   no state file, so it renames each view that exists to
   `<name>-<yesterday>.log` at once and gzips it 10 minutes later; a large old
   file is therefore compressed once and then ages out by its retention key. The
   per-host day files of the last week are gzipped except today's.
3. Until the monitor has restarted and logged its first heartbeat,
   `hps-log attention` exits 11 (`silent` or `absent`): that is the check that
   the emitters run, not a fault.
4. On the lab IPS the collector block that `lab/syslog-lab.pl` adds to
   `rsyslog.conf` (and re-adds after each start through `lab/syslog-all.sh`)
   writes `events.log` and `metrics.log` as well. With the product's rules the
   lines would be written twice. The block must shrink to the single `all.log`
   action; its `events_block` and the `LabEvent` template go. `all.log` stays as
   the one lab-only file with every message. The cron job that runs
   `lab/log-rotate.sh` trims `events.log` and `metrics.log` in place and would
   fight with the daily rename: retire it for those two files (its `all.log`
   rotation and day-file pruning are the lab's own and `hps-log-rotate` now does
   the day files).
5. Check: `ls $HPS_LOG` shows `events.log`, `metrics.log` and `audit.log`;
   `hps-log events --lines 5` shows marker lines; `hps-log attention` exits 0 or
   10 within an hour; `hps-log ips --grep DHCPACK` shows the leases;
   `hps-log-rotate run --dry-run` lists what the next pass would do.
