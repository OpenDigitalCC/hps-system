# Operator access: every cluster manages itself

Every HPS cluster is run from its own IPS, through that IPS's own ctrl-exec.
An operator, a person or a lab, reaches a cluster only by calling that IPS's
ctrl-exec API with a credential the IPS issued, and runs the IPS's own tools
there. Nothing inside a cluster knows about anything outside it: no outside
dispatcher pairs with the IPS, and no outer HPS has access to it. Owner rulings
of 2026-11-11: "using inside c-e is better representation of how it would be
normally used - inside clusters are not aware of the outside world", and
"inside cluster should be fractal of outside".

## Fractal

The same IPS image, the same local agent, the same `ips-admin` scripts and the
same operator API exist at every level. The lab IPS, a nested cluster's inner
IPS (scale test `s1`, `s2`) and a real site are driven by the same calls:

```
hps-op --cred lab/secrets/s1-operator hps-onboard list
hps-op --cred lab/secrets/lab-operator hps-onboard list
```

Whatever works one level down works one level up, and on a real site.

## The pieces

| Piece | Where | What |
| --- | --- | --- |
| Local agent | the IPS, `program:ctrl-exec-agent` (supervisord, root, syslog) | the ctrl-exec agent `ips.<cluster DNS domain>` (one hostname rule, `docs/NAMING.md`), port 7446, accepting connections from 127.0.0.1 only |
| `ips-admin` allowlist | `ips-admin/` in hps-system; agent `scripts.conf`, profile `ips-admin` | one thin wrapper per tool, all through `ips-admin/ips-admin-exec` |
| Operator API | the IPS's `ctrl-exec-api`, TLS on `operator_api_listen`:7445 | the API HPS already runs (unix socket for `hps-jobs`), with a TCP listener added for operators |
| Auth hook | `scripts/ctrl-exec-auth-hook.sh` (installed as `auth-hook-hps`) | an operator credential may run only `ips-admin` scripts on `ips.<domain>` |
| Credentials | `bin/hps-operator` on the IPS | issue, list, revoke; the IPS keeps only a SHA-256 of each |
| Client | `bin/hps-op` anywhere with this tree and `ctrl-exec-cli` | runs one `ips-admin` script, prints its output, exits with its status |

## The local agent

At every IPS start with a configured cluster (`scripts/run-hps.sh`, step 4c,
`ce_ips_agent_bring_up` in `lib/functions.d/ips-admin-functions.sh`):

1. `/etc/ctrl-exec-agent` and `/var/lib/ctrl-exec-agent` are linked to
   `/srv/ctrl-exec/agent-conf` and `/srv/ctrl-exec/agent-state`, so the agent's
   key and certificate survive an image rebuild, like the dispatcher's.
2. The agent is installed from the dispatcher tarball (`install.sh --agent`)
   when `ctrl-exec-agent` is not on `PATH`.
3. `agent.conf` and `scripts.conf` are rewritten (HPS owns them):
   `port = 7446` (the IPS shares the host's network, where the host may run its
   own agent on 7443), `allowed_ips = 127.0.0.1`, `script_dirs` the `ips-admin`
   directory, and every `ips-admin` script under profile `ips-admin`.
4. If the agent has no certificate, or the dispatcher does not list it, the IPS
   pairs it with its own dispatcher: a 120 s pairing window, `request-pairing
   --dispatcher 127.0.0.1 --dispatcher-fingerprint <the dispatcher's own CA>
   --name ips.<domain> --background`, then the same non-interactive `approve`
   the node approver uses, guarded: only a pending request carrying exactly
   `ips.<domain>` and coming from 127.0.0.1 is approved (`approve <reqid> --ip
   127.0.0.1 --lookup-by ip --agent-port 7446`); anything else is refused and
   left pending. The window is closed when the certificate has arrived.
5. `hps-operator export` restores the auth hook's credential digests from the
   keysafe.

No profile is applied: the IPS image has no executor, so the agent runs the
scripts as its own user, root (the tools act on the IPS's state as root, as
they do from a root shell in the container). The `ips-admin` profile
(`run_as = root`, `no_new_privileges`) is declared for an image that builds the
executor.

## The `ips-admin` scripts

| Script | Calls | Narrowed to |
| --- | --- | --- |
| `hps-onboard` | `bin/hps-onboard` | - |
| `hps-cluster-config` | `bin/hps-cluster-config` | arguments only (no `apply FILE`: no argument names a file) |
| `hps-cluster-config-apply` | `bin/hps-cluster-config apply -` | `--dry-run`, `--json`; the `key = value` lines are the run's input (`input=raw`) |
| `hps-bmc` | `bin/hps-bmc` | `status`, `list`, `set`, `select` |
| `hps-bmc-credential` | `bin/hps-bmc credential` | the user and password lines are the run's confidential input (`input=raw`) |
| `hps-node` | `bin/hps-node` | - |
| `hps-storage` | `bin/hps-storage` | - |
| `hps-workload` | `bin/hps-workload` | - |
| `hps-pins` | `bin/hps-pins` | - |
| `hps-ips-check` | `bin/hps-ips-check` | - |
| `hps-osvc` | `bin/hps-osvc` | - |
| `hps-monitor` | `bin/hps-monitor run` | `run` |
| `ips-syslog-forward` | `bin/hps-syslog-forward` | `<ipv4> <prefix>`, `off`, `show` |

`ips-admin-exec` passes the arguments through (the tools validate their own)
but only as conservative tokens: 1 to 256 characters of `A-Z a-z 0-9 _ . , :
= @ + -`, no `..`, and a `/` only inside an IPv4 CIDR such as `10.0.0.1/24`; at
most 64 arguments. A shell metacharacter, a space, a quote or a newline never
passes, and no argument can name a file. A value that does not fit (a
description with spaces, a URL, a JSON layout) goes through
`hps-cluster-config-apply`, whose input is not an argument. The tool runs in an
empty private directory with stdin `/dev/null`, except for the two `input=raw`
scripts. Without `input=raw` the agent writes the request context (the caller's
token included) to the script's stdin: it never reaches a tool. Each call logs
two syslog lines, tag `ips-admin`: the tool and its arguments, then its exit
status. The input is never logged.

Nodes are never driven directly: an operator drives them through the IPS tools
(`hps-node`, `hps-storage`, `hps-workload`), which use the IPS's dispatcher as
they always do.

## Operator credentials

On the IPS, as root:

```
hps-operator issue <name>     # prints the credential, once
hps-operator list [--json]
hps-operator revoke <name>
hps-operator ca               # the API certificate, if the credential lacks it
```

A credential is a random token (`hpsop_` and 64 hex digits, 256 bits). The IPS
keeps only its SHA-256, in the keysafe (stored secret `operator-<name>`), and
cannot show the token again. The auth hook runs as the API's user (`ctrl-exec`),
which cannot read the root-only keysafe, so `issue` and `revoke` also rewrite
`/etc/ctrl-exec-dispatcher/hps-operators` (`<name> <sha256>` lines, root:ctrl-exec
0640); the keysafe is the record and `hps-operator export` rebuilds the file
from it. A revoked credential is refused from the next call.

`issue` prints a credential file to keep, mode 0600, on the operator's machine:

```
name = <name>
agent = ips.<domain>
url = https://<operator_api_listen>:7445
token = hpsop_...
-----BEGIN CERTIFICATE-----
(the API certificate)
-----END CERTIFICATE-----
```

## The operator API

The cluster key `operator_api_listen` (group `operator`, default empty) is the
address of the IPS on which the ctrl-exec API listens for operators. Empty: no
TCP listener and no remote operator, as before. Set: at the next IPS start
`ce_api_bring_up` sets `api_port = 7445`, `api_bind`, `api_tls_cert` and
`api_tls_key` in `ctrl-exec.conf`. The certificate is self-signed for that IP
(`/etc/ctrl-exec-dispatcher/hps-api-tls.crt`, subjectAltName `IP:<address>`,
10 years, renewed 30 days before expiry or when the address changes; then
every operator needs `hps-operator ca` again); the operator verifies the API
against it. The address must be one of the IPS's own; a loopback or wildcard
address is refused and the listener stays off. The unix socket stays as it was.

The hook (`scripts/ctrl-exec-auth-hook.sh`):

- unix socket: root only (unchanged; the job runner and `hps-run.sh`);
- the dispatcher CLI `ced`: allowed (unchanged). ctrl-exec gives a hook no
  caller field and `ced` reports 127.0.0.1, so the hook tells `ced` from an
  API caller by its parent process (`ctrl-exec-api` runs the hook from its
  request handler); an unreadable parent counts as the API;
- a TCP caller of the API must present a live operator credential (the request
  `token`). It may pass the API's pre-route check, ping `ips.<domain>`, and run
  an `ips-admin` script on `ips.<domain>`; nothing else (no node agent, no
  other script, no second host, no stored result). Each operator run is logged
  at `auth.notice`, tag `hps-auth-hook`: `OPERATOR run operator=<name>
  source=<ip> user=<claimed> agent=ips.<domain> script=<script> args=<JSON>`.
  Denials are logged as `DENY ...` with the reason.

## The client

```
hps-op [--ips URL] --cred FILE [--input] [--timeout S] [--json] <tool> [args...]
```

It runs `ctrl-exec-cli --url <url> --ca <the credential's certificate> run
ips.<domain> --script <tool> --json -- <args>`, with the token in the client's
environment (`CTRL_EXEC_TOKEN`, never an argument), and prints the tool's
stdout and stderr; its exit status is the tool's. `--input` sends stdin as the
run's confidential input, for `hps-bmc-credential` and
`hps-cluster-config-apply`:

```
printf '%s\n%s\n' "$user" "$password" | hps-op --cred FILE --input hps-bmc-credential tch-003
hps-op --cred FILE --input hps-cluster-config-apply < s1.conf
```

A credential file readable by group or others, a plain `http://` URL, or a
credential without a certificate (and no `--ca`) is refused.

## Optional: forward the IPS's syslog

`ips-syslog-forward <ipv4> <prefix>` (`bin/hps-syslog-forward`) forwards
everything this IPS's rsyslog receives or logs to a collector over TCP 514,
host names as `<prefix>.<hostname>`, so one collector can hold several
clusters. It is an operator action and off by default: the cluster does
nothing of the kind by itself. It is kept in the cluster keys
`syslog_forward_host` and `syslog_forward_prefix`, so it survives a restart
(`create_config_rsyslog` writes it before the routing rules); `rsyslogd` is
restarted at once. `ips-syslog-forward off` stops it, `show` prints it. The lab
uses it to gather its clusters' logs on the lab IPS (it replaces
`lab/syslog-lab.pl --upstream`).

## Gaps

- The agent cannot be bound to 127.0.0.1 (ctrl-exec 0.14.6 has no listen
  address for the agent): it listens on every address of the host and drops a
  connection from anywhere but 127.0.0.1 before the TLS handshake
  (`allowed_ips`).
- The hook's tell between `ced` and an API caller is the parent process; a
  caller field from ctrl-exec would make it explicit.
- Without an executor in the image the `ips-admin` profile is not applied.
- A call waits at most the dispatcher's `read_timeout` (ctrl-exec.conf, 60 s
  by default, the same for every agent). A longer tool run carries on on the
  IPS, but its output does not reach the operator; the `ips-admin end` line in
  the IPS's syslog has its exit status. ctrl-exec has no per-agent or
  per-script read timeout.
- The first credential of an IPS is issued at that IPS (`hps-operator issue`
  as root). For an inner IPS on a container host that is the CNH's bootstrap
  step, done once, like a technician at the console; nothing gives an outer
  HPS standing access.
