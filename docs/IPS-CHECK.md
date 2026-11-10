# IPS self-check

`bin/hps-ips-check` answers one question: did this IPS come up healthy? A
degraded start otherwise shows only when a node boots and something fails much
later, with the cause in an unrelated log (a `411` on every `boot_manager`
POST, a ctrl-exec API that never came up, rsyslog not filing).

supervisord runs it once after every start (`program:hps-ips-check`,
`autorestart=false`, `--wait 60` for the HTTP port and the ctrl-exec API
socket). Run it by hand any time:

    /srv/hps-system/bin/hps-ips-check [--json] [--wait SECONDS]

Exit status: `0` no check failed, `1` at least one FAIL (or the result file
could not be written), `2` usage. A WARN never fails the run.

## Reading the result

Three places carry the same result:

- stdout: one line per check, `PASS|WARN|FAIL <check>: <reason>`, then
  `summary: N PASS, N WARN, N FAIL`. With `--json` stdout is the JSON instead.
- syslog: one line per check and the summary, tag `hps-ips-check`; rsyslog
  files them in `$HPS_LOG/ips/<date>.log`.
- `/srv/hps-config/clusters/$CLUSTER/services/ips-check.json`:
  `{timestamp, cluster, summary: {pass, warn, fail}, checks: [{name, status,
  reason}]}`. It is rewritten by every run, so its timestamp says when the
  IPS was last checked.

Start with the FAIL lines. The reason names what was seen (an HTTP status, a
missing file, a group name), so a FAIL can be acted on without re-running by
hand.

## The checks

| Check | PASS when | Notes |
|---|---|---|
| `boot_manager init` | `GET ?cmd=init` from the IPS's own address returns 200 and an iPXE script (`#!ipxe`) | A 4xx or 5xx is a FAIL naming the status. The request is answered like any node's, so an unknown source is registered as a held host. |
| `boot_manager POST log_message` | an empty-body POST returns 200 | A `411` here is the lighttpd Length Required fault: the node calls are POSTs with `--data-binary ""`. Writes one tagged log line. |
| `boot_manager cluster_variable` | `?cmd=cluster_variable&name=network_dns_domain` returns 200 and a non-empty value | |
| `nixos boot.json` | `/nixos/<latest pin>/<profile>/boot.json` returns 200 and JSON with `pin` | No `nixos/latest` is a WARN (no image built or seeded). |
| `tftp boot files` | `snponly.efi` and `undionly.kpxe` exist and are non-empty in the TFTP root | |
| `dns ips`, `dns registry host` | dnsmasq answers for `ips.$DOMAIN` and for the first registry host with a `HOSTNAME` | No registry host is a WARN; no `dig` or `host` on the IPS is a WARN. |
| `ctrl-exec dispatcher`, `api`, `cli` | each is installed; `ctrl-exec-dispatcher --version` and `ctrl-exec-cli --version` are printed | The API server has no `--version`; its version is in the `api health` line. |
| `ctrl-exec api socket` | the `api_socket` of `ctrl-exec.conf` is a socket owned by the configured `api_socket_group` | |
| `ctrl-exec api health` | `ctrl-exec-cli --socket $SOCK health` succeeds (no target, no authentication needed) | |
| `rsyslog` | a `logger` message with a unique token appears in `ips/<date>.log` within 5 s | |
| `chrony` | `chronyc tracking` answers and the leap status is Normal | Unsynchronised is a WARN (the cluster may have no upstream by design); chronyd not answering is a FAIL. |
| `disk resources`, `disk log` | free space on `$HPS_RESOURCES` and `$HPS_LOG` is at least 15% | Below 15% WARN, below 5% FAIL. |
| `registry` | `cluster.db` of the active cluster is readable and the IPS address is set | |

The checks read only, except the `log_message` probe (one tagged log line)
and the `init` request (see the table). No secret is read or printed.

## Environment

`HPS_BASE` (default `/srv`), `HPS_SYSTEM_PATH` (default: the parent of
`bin/`), `CTRL_EXEC_DISPATCHER_CONF` (default
`/etc/ctrl-exec-dispatcher/ctrl-exec.conf`), `HPS_IPS_CHECK_SYSLOG_WAIT`
(seconds the rsyslog check waits, default 5).
