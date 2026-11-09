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
| nginx (access and error) | `$HPS_LOG/ips/nginx/<date>.log` |
| fcgiwrap | `$HPS_LOG/ips/fcgiwrap/<date>.log` |
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
