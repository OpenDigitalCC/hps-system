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
| Local agent | the IPS, `program:ctrl-exec-agent` (supervisord, root, syslog) | the ctrl-exec agent `ips.<cluster DNS domain>` (one hostname rule, `docs/NAMING.md`), port 7446, listening on 127.0.0.1 only (`bind`) |
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
   own agent on 7443), `bind = 127.0.0.1` (the agent listens on loopback only;
   ctrl-exec 0.14.7) with `allowed_ips = 127.0.0.1` kept as defence in depth, `script_dirs` the `ips-admin`
   directory, and every `ips-admin` script under profile `ips-admin`.
4. If the agent has no certificate, or the dispatcher does not list it, the IPS
   pairs it with its own dispatcher: a 120 s pairing window, `request-pairing
   --dispatcher 127.0.0.1 --dispatcher-fingerprint <the dispatcher's own CA>
   --name ips.<domain> --background`, then the same non-interactive `approve`
   the node approver uses, guarded: only a pending request carrying exactly
   `ips.<domain>` and coming from 127.0.0.1 is approved (`approve <reqid> --ip
   127.0.0.1 --lookup-by ip --agent-port 7446 --read-timeout 900`); anything
   else is refused and left pending. The window is closed when the certificate
   has arrived. The read timeout (below) is also set on an agent already
   registered, at every start (`edit-agent ips.<domain> --read-timeout`).
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
| `hps-workload-define` | `bin/hps-workload define <name>` | one workload name, `--dry-run`, `--replace`, `--json`; the JSON definition is the run's input (`input=raw`) |
| `hps-pins` | `bin/hps-pins` | - |
| `hps-ips-check` | `bin/hps-ips-check` | - |
| `hps-osvc` | `bin/hps-osvc` | - |
| `hps-monitor` | `bin/hps-monitor run` | `run` |
| `ips-syslog-forward` | `bin/hps-syslog-forward` | `<ipv4> <prefix>`, `off`, `show` |
| `hps-repo` | `bin/hps-repo` | - (`seed` from the IPS's own cache only: a URL has a `/`; `--profiles a,b`) |
| `hps-log` | `bin/hps-log` | `host`, `ips` (read-only: the newest syslog lines of a host or of the IPS, secret lines redacted; `--min-level warning` (or `error`) for the warnings and errors only; docs/LOGGING.md) |
| `hps-metrics` | `bin/hps-metrics` | `last`, `series` (read-only: hps-monitor's latest result and utilisation series per host; docs/MONITORING.md) |
| `hps-issues` | `bin/hps-issues` | `list`, `show`, `open`, `resolve`, `note`, `retry` (the issue register: what the IPS found wrong, what it healed, what needs a human; texts as words after the options; docs/ISSUES.md) |

`ips-admin-exec` passes the arguments through (the tools validate their own)
but only as conservative tokens: 1 to 256 characters of `A-Z a-z 0-9 _ . , :
= @ + -`, no `..`, and a `/` only inside an IPv4 CIDR such as `10.0.0.1/24` or,
for `hps-storage` only, in exactly the dataset forms `hps-storage` itself
accepts: `<pool>/enc`, `<pool>/enc/<name>` and `<pool>/enc/vm/<name>` (the
pattern `^[a-z][a-z0-9_.-]*/enc(/(vm/)?[A-Za-z0-9_-]+)?$`, `HPS::Storage`'s
`$DS_RE`); no leading `/`, no empty part, no other directory; at most 64
arguments. A shell metacharacter, a space, a quote or a newline never
passes, and no argument can name a file. A value that does not fit (a
description with spaces, a URL, a JSON layout) goes through
`hps-cluster-config-apply`, whose input is not an argument; a workload
definition goes through `hps-workload-define` the same way. The tool runs in an
empty private directory with stdin `/dev/null`, except for the three `input=raw`
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
To apply a change without restarting the IPS, run `hps-operator-api-apply` as
root on the IPS: the same bring-up, a check that `api_bind` is now the address
(exit 3 when the IPS left the listener off), then `supervisorctl restart
ctrl-exec-api`.

The hook (`scripts/ctrl-exec-auth-hook.sh`):

- unix socket: root only (unchanged; the job runner and `hps-run.sh`);
- the dispatcher CLI `ced`: allowed (unchanged). ctrl-exec 0.14.7 tells the
  hook who is asking: `ENVEXEC_CALLER` is `cli` for `ced` and `api` for a
  request the API serves, and `ENVEXEC_LISTENER` is `unix`, `tcp` or `tls` for
  an API caller (empty for `ced`). Both are set by ctrl-exec's code path, never
  from the request, so a local API caller that also appears as 127.0.0.1 is not
  taken for `ced`;
- an API caller must arrive on the TLS listener (`ENVEXEC_LISTENER=tls`); on
  any other listener it is denied. It must present a live operator credential (the request
  `token`). It may pass the API's pre-route check, ping `ips.<domain>`, and run
  an `ips-admin` script on `ips.<domain>`; nothing else (no node agent, no
  other script, no second host, no stored result). Each operator run is logged
  at `auth.notice`, tag `hps-auth-hook`: `OPERATOR run operator=<name>
  source=<ip> user=<claimed> agent=ips.<domain> script=<script> args=<JSON>`.
  Denials are logged as `DENY ...` with the reason.
- an older dispatcher (ctrl-exec < 0.14.7) sets neither variable. The hook then
  fails closed for operators (no caller is ever taken for an operator, so remote
  operator access does not work) and keeps HPS's own callers working: root on
  the unix socket, and `ced`, recognised by its parent process, which is not the
  API's request handler (the only remaining use of `/proc`). Bring-up also logs
  an error and leaves the operator API off.

## The client

```
hps-op [--ips URL] --cred FILE [--input] [--timeout S] [--json] <tool> [args...]
```

It runs `ctrl-exec-cli --url <url> --ca <the credential's certificate> run
ips.<domain> --script <tool> --json -- <args>`, with the token in the client's
environment (`CTRL_EXEC_TOKEN`, never an argument), and prints the tool's
stdout and stderr; its exit status is the tool's. `--input` sends stdin as the
run's confidential input, for `hps-bmc-credential`, `hps-cluster-config-apply`
and `hps-workload-define`:

```
printf '%s\n%s\n' "$user" "$password" | hps-op --cred FILE --input hps-bmc-credential tch-003
hps-op --cred FILE --input hps-cluster-config-apply < s1.conf
hps-op --cred FILE --input hps-workload-define w1 < w1.json
```

A credential file readable by group or others, a plain `http://` URL, or a
credential without a certificate (and no `--ca`) is refused.

## Storage and workloads through the operator API

`hps-storage` and `hps-workload` are `ips-admin` tools, so an operator on an
inner IPS creates and destroys pools, zvols and workloads through that IPS's
operator API, with no step on the IPS itself. HPS asks for no approval of its
own (ADR 0007, owner ruling 2026-11-11): the operator credential and the auth
hook are the authorisation, and every run is logged (`OPERATOR run ...`, then
the `ips-admin` start and end lines). For example:

```
hps-op --cred FILE hps-storage sch-001 status
hps-op --cred FILE hps-storage sch-001 create s1 --disk ata-SSD_A --disk ata-SSD_B --dry-run
hps-op --cred FILE hps-storage sch-001 create s1 --disk ata-SSD_A --disk ata-SSD_B --disk ata-SSD_C
hps-op --cred FILE hps-storage sch-001 destroy s1
hps-op --cred FILE hps-workload destroy t0 --dry-run
hps-op --cred FILE hps-onboard forget 525400000009
```

Zvols and exports take the dataset as an argument (`<pool>/enc/vm/<name>` for
a guest disk), which `ips-admin-exec` passes for `hps-storage`:

```
hps-op --cred FILE hps-storage sch-001 zvol-create c1/enc/vm/probe-a 1G
hps-op --cred FILE hps-storage sch-001 export c1/enc/vm/probe-a \
  --iqn iqn.2026-01.example.c1:probe-a --initiator iqn.2026-01.example.c1:tch-001 \
  --portal 192.0.2.10
hps-op --cred FILE hps-storage sch-001 unexport iqn.2026-01.example.c1:probe-a
hps-op --cred FILE hps-storage sch-001 vdev-online c1 virtio-c1-sch-001-d3
hps-op --cred FILE hps-storage sch-001 zfs-set c1/enc/vm/probe-a sync=disabled logbias=throughput
hps-op --cred FILE hps-storage sch-001 zvol-destroy c1/enc/vm/probe-a
```

`zfs-set` changes only `sync` and `logbias`, on `<pool>/enc` or a zvol under
it; its `<prop>=<value>` tokens are plain tokens to the gate. New zvols take
the cluster keys `storage_zvol_sync` and `storage_zvol_logbias`
(`docs/CLUSTER-CONFIG.md` "Zvol write properties").

Give each disk as its bare `/dev/disk/by-id` name (`ata-...`, `nvme-...`,
`wwn-...`): `ips-admin-exec` passes no `/` outside an IPv4 CIDR, so the
`/dev/disk/by-id/` prefix is refused there (`hps-storage` accepts both forms
from a root shell). `create` takes 1 to 4 disks: one disk makes a plain
single-vdev pool, the normal storage-host shape (each SCH holds one disk; the
mirror runs across the storage hosts, one md leg per SCH, `docs/WORKLOADS.md`);
2 to 4 make one mirror of them all.
A disk that carries a pool label or a filesystem or partition signature is
refused unless `--wipe` is given, which wipes exactly the named disks; a
mounted disk, a disk with a holder or a member of an imported pool is refused
even with `--wipe`. Run `--dry-run` first: it prints the node calls and
changes nothing. A long `create` returns its output within the IPS agent's read
timeout (`ips_admin_read_timeout`, default 900 s).

### Defining and creating a workload

A workload's definition is the file `workloads/<name>.json` in the cluster's
config directory (`docs/WORKLOADS.md`). An operator writes it with
`hps-workload-define <name>`, the definition being the run's input; it is
checked exactly as `create` checks a definition, the name must equal the
definition's `name`, an existing definition is replaced only with `--replace`,
and never while the workload exists (destroy it first). `hps-workload
show-definition <name>` prints the stored JSON. For example, a workload `w1`
on an inner cluster `c1`, one VM whose disk mirrors a local zvol on `tch-001`
with a LUN exported by `sch-001` (the `mgmt` network is in the cluster's
`network_layout`):

```
cat > w1.json <<'JSON'
{"name": "w1", "project": "c1",
 "vms": [{"name": "w1-app", "memory_mib": 2048, "vcpus": 2,
          "image": "debian-13-generic-amd64", "nets": ["mgmt"],
          "disks": [{"name": "root", "size": "20G",
                     "legs": [{"host": "tch-001", "pool": "c1"},
                              {"host": "sch-001", "iqn": "iqn.2026-01.example.c1:w1-root",
                               "portal": "192.0.2.10"}]}]}]}
JSON
hps-op --cred FILE hps-storage sch-001 zvol-create c1/enc/vm/w1-root 20G
hps-op --cred FILE hps-storage sch-001 export c1/enc/vm/w1-root \
  --iqn iqn.2026-01.example.c1:w1-root --initiator iqn.2026-01.example.c1:tch-001 \
  --portal 192.0.2.10
hps-op --cred FILE --input hps-workload-define w1 --dry-run < w1.json
hps-op --cred FILE --input hps-workload-define w1 < w1.json
hps-op --cred FILE hps-workload show-definition w1
hps-op --cred FILE hps-workload create w1 --dry-run
hps-op --cred FILE hps-workload create w1
hps-op --cred FILE hps-workload start w1
```

To change it later: `hps-workload destroy w1`, then `hps-workload-define w1
--replace` and `create` again. The same holds for a VM's guest `seed`
(`docs/WORKLOADS.md` "A guest seed"): the seed travels inside the definition
(the `hps-workload-define` input), `create` writes it onto the fresh disk
(`vm-seed-write`, the seed as that node run's input), and cloud-init reads it
once, so a changed seed needs destroy, define `--replace` and create.

### Reading a guest's console

`hps-workload console <name> [--vm <vm>] [--lines N]` prints the tail of a
VM's serial console log (`vm-console-log` on its compute host; read-only). It
is open through the `ips-admin` gate like `hps-workload status` (every
argument a plain token), so an operator reads a guest's console with no
network path to the guest:

```
hps-op --cred FILE hps-workload console w1 --vm w1-app --lines 20
hps-op --cred FILE hps-workload console w1 --json
```

The scale test's board (`lab/scale/board.pl`, lab-only) reads each probe's
`PROBE` line this way.

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

## ctrl-exec 0.14.7 is required

Operator access and the `ips-admin` agent use four things ctrl-exec 0.14.7
delivers (R-036). Bring-up reads the installed version
(`ctrl-exec-dispatcher --version`) and, when it is older or unreadable, logs an
error naming the requirement and leaves the operator API off:

- agent.conf `bind = 127.0.0.1` for the IPS's own agent;
- `ENVEXEC_CALLER` and `ENVEXEC_LISTENER` for the auth hook;
- a per-agent read timeout (`approve --read-timeout`, `edit-agent --read-timeout`)
  for the IPS's own agent only: the cluster key `ips_admin_read_timeout`
  (seconds, an integer 60..3600, default 900), applied at pairing and at every
  start, so a long tool run (publish, storage) returns its output. Node agents
  keep the dispatcher's global `read_timeout`;
- `api_forward_token = no` in the dispatcher's ctrl-exec.conf, written by
  bring-up, so the operator's token (the request `token`) is not passed on to
  the agents. The API's own auth hook still receives it.

## Gaps

- Without an executor in the image the `ips-admin` profile is not applied.
- A call to the IPS's agent waits at most `ips_admin_read_timeout` (900 s by
  default, at most 3600). A tool run longer than that carries on on the IPS,
  but its output does not reach the operator; the `ips-admin end` line in the
  IPS's syslog has its exit status. ctrl-exec has no per-script read timeout.
- The first credential of an IPS is issued at that IPS (`hps-operator issue`
  as root). For an inner IPS on a container host that is the CNH's bootstrap
  step `cnh-ips-operator-init <address>:7445 <label>` (`docs/CONTAINER-HOST.md`),
  done once, like a technician at the console: it sets `operator_api_listen`,
  restarts the API and returns the credential as confidential output; nothing
  gives an outer HPS standing access.
