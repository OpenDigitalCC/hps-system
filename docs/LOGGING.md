# IPS logging

Every IPS service logs through syslog. rsyslog (in the IPS container)
receives local messages on `/dev/log` and node messages on port 514
(UDP and TCP), and files them under `$HPS_LOG` (default `/srv/hps-log`).

## Where each log lands on the IPS

| Source | File |
|---|---|
| dnsmasq (DNS) | `$HPS_LOG/ips/dnsmasq/<date>.log` |
| dnsmasq DHCP | `$HPS_LOG/ips/dnsmasq-dhcp/<date>.log` |
| dnsmasq TFTP | `$HPS_LOG/ips/dnsmasq-tftp/<date>.log` |
| lighttpd (access, error and CGI stderr) | `$HPS_LOG/ips/lighttpd/<date>.log` |
| chronyd | `$HPS_LOG/ips/chronyd/<date>.log` |
| supervisord program output | `$HPS_LOG/ips/supervisord/<date>.log` |
| `hps_log` (CGI and API scripts) | `$HPS_LOG/ips/hps/<date>.log` |
| anything else local (rsyslogd, OpenSVC, ...) | `$HPS_LOG/ips/<date>.log` |
| supervisord's own log | `$HPS_LOG/supervisord.log` (a file; supervisord cannot log to syslog) |

`hps_log` sends to syslog (tag `hps`, facility `local0`) whenever
`/dev/log` exists. Only when syslog is unavailable does it fall back to
`$HPS_LOG/cluster-<name>.log` or `$HPS_LOG/hps-system.log`.

## How a node's syslog is filed

A node forwards its syslog to the IPS on port 514. rsyslog files each
node by source address: `$HPS_LOG/$NODE_IP/<date>.log`, where
`$NODE_IP` is the address the message came from. Line format:
`<timestamp> <source ip> [<hostname>] <tag> <message>`.

## Watching

Operator watching a netboot (one node):

    tail -f $HPS_LOG/$NODE_IP/$(date +%Y-%m-%d).log

Operator watching the IPS services (all of them, today):

    tail -f $HPS_LOG/ips/*/$(date +%Y-%m-%d).log

(`tail` over several files prints a header when the file changes. The
date in the path rolls at midnight: restart the `tail`.)

## Reading a host's log: hps-log

`hps-log` reads the newest lines of one host, or of the IPS itself, from
this tree. It is read-only and an ips-admin tool, so an operator runs it
through `hps-op` (`docs/OPERATOR.md`); the cluster browser's "Recent log"
group calls it.

    hps-log host <mac|hostname> [--lines N] [--since MINUTES] [--grep WORD] [--min-level LEVEL] [--json]
    hps-log ips [--lines N] [--since MINUTES] [--grep WORD] [--min-level LEVEL] [--json]

- `host`: a MAC in any form, a registry `HOSTNAME` or an FQDN. A node is
  filed by the address it sent from, so its lines are read from every
  address the registry knows for it: its current `IP`, then each IPv4
  address its stored audit recorded (the audit boot's DHCP address). The
  directories are merged by time.
- `ips`: `ips/<date>.log` (rsyslogd, OpenSVC, the auth hook),
  `ips/hps/<date>.log` (`hps_log`) and, where the lab collector writes it,
  the `events.log` lines of host `ips`. hps-monitor's per-check results are
  left out (a line per check per node every tick; `metrics.log` keeps them).
- `--lines` 1 to 500, default 50, newest last; `--since` 1 to 43200 minutes;
  `--grep` one word, case-insensitive. `--min-level warning` keeps the
  warnings and errors, `--min-level error` the errors; `--lines` then counts
  the lines that pass (the browser's "Recent log" opens on this, the newest
  warnings and errors, and offers the full log). A call reads at most 64 MiB of log
  (`truncated` says when it stopped there).
- `level` (error, warning, info) is read from the text: the files keep no
  syslog priority. "No space left", "failed", "refused", `state=CRITICAL` are
  errors; "warning", "degraded", "timed out" warnings; a count ("0 failed",
  "fail=0") is neither.

### Redaction

A line is never printed when it may carry a secret; its message becomes
`[redacted]` (its time and tag stay). The rule: any word of the line (runs
of `A-Z a-z 0-9 _`) matches the cluster-config secret-name rule
(`HPS::ClusterConfig::secret_name_re`: `secret`, `passw`, `token`,
`credential`, `psk`, `private`, or `key` as a whole word or a `_key_`
part), or the line holds a PEM marker (`-----BEGIN ...-----`), an operator
token (`hpsop_...`) or 64 hex digits in a row (a raw key). `--grep` matches
after redaction, so it cannot be used to probe a withheld line. A redacted
line has level info, so `--min-level` never shows one. The rule is
deliberately wide: kernel lines such as "Key type asymmetric registered"
are withheld too.
