# ADR 0006 — The web user never holds dispatcher or keysafe access

- Status: accepted
- Date: 2026-11-09
- Tags: security, ctrl-exec, keysafe, lighttpd, supervisor

## Context

Since the move to lighttpd (ADR 0004) the CGI runs as `www-data` (group `hps`).
Under nginx and fcgiwrap it effectively ran as root, which hid two needs for
root that the IPS has:

- The ctrl-exec dispatcher config and key belong to `ctrl-exec` (mode 0600) and
  the pairing queue is `root:ctrl-exec` 2770. `ctrl-exec-dispatcher
  pairing-mode`, `list-requests` and `approve` fail for `www-data` with
  "Cannot open config ... Permission denied", so a node could not pair.
- `bin/hps-storage` reads the 0700 keysafe and drives the node over
  `ctrl-exec-cli` and the `ctrl-exec-api` socket. The web user must never read
  the keysafe (ADR 0005).

Giving the CGI root, or `sudo` rights to the dispatcher, would put the whole
dispatcher (every paired node) behind every CGI bug.

## Decision

The web user holds no dispatcher and no keysafe access. A short allowlist of
privileged actions is executed by a root runner from a queue the web user can
write but not act through.

### The queue

`${HPS_CONFIG_BASE}/clusters/<cluster>/jobs/{new,run,done,failed}`, created with
`hps_state_mkdir` (group `hps`, setgid, group-writable) so `www-data` can write
`new/` and read the results.

A job is one JSON file `new/<epoch>-<pid>-<id>.json`:
`{id, kind, args: [...], requested_by: "<uid>/<program>", requested_at}`. It is
written under a temporary name and renamed, so the runner never sees half a file.

The runner moves the file to `run/`, executes it, writes
`<id>.result.json` (`{id, kind, exit, stdout, stderr, finished_at, duration}`,
stdout and stderr each capped at 64 KiB and flagged when cut) into `done/`
(exit 0) or `failed/`, and removes the job file. Results older than 7 days are
pruned.

Callers: `hps_job_submit`, `hps_job_wait`, `hps_job_result`
(`lib/functions.d/jobs-functions.sh`) and `HPS::Jobs` (`lib/perl/HPS/Jobs.pm`),
which keep the same file shapes and argument patterns.

### The allowlist

| kind | arguments | runs |
|---|---|---|
| `pairing-window-open` | `[seconds 1-600]` | `ctrl-exec-dispatcher pairing-mode start --timeout <n>` |
| `pairing-window-close` | none | `ctrl-exec-dispatcher pairing-mode stop` |
| `pairing-list` | none | `ctrl-exec-dispatcher list-requests` (read-only; the approver needs the pending request) |
| `pairing-approve` | `<reqid hex> [--replace]` | `ctrl-exec-dispatcher approve <reqid> [--replace]` |
| `storage-up` | `<mac 12 hex>` | `bin/hps-storage <mac> up --wait 120` |
| `storage-down`, `storage-trim-check`, `storage-status` | `<mac>` | `bin/hps-storage <mac> down\|trim-check\|status` |

Anything else, and any argument outside its pattern, is refused twice: by the
submitter, and again by the runner (the queue is writable by the web user, so the
runner trusts nothing in a file). The commands come from a fixed table and are
executed as an argument list, never through a shell. `storage-create` and
`storage-destroy` are not in the list: they run from `hps-storage`, on the IPS
command line or through the operator API (`ips-admin`), where ctrl-exec decides
who may run them (ADR 0007; until 2026-11-11 they also needed a signed HPS
approval).

`pairing-approve ... --replace` asks for replace; the runner probes the
dispatcher's usage text and drops it for a dispatcher that lacks it.

### The runner

`bin/hps-jobs` runs under supervisor as root (`program:hps-jobs`, logging to
syslog). It polls `new/` every 0.5 s and runs one job at a time, oldest first. It
logs the start and end of every job (id, kind, exit, duration). A job found in
`run/` at start was interrupted; it is moved to `failed/` with exit 125 and a
note, and is not run again. A job that outlives its limit (60 s for the
dispatcher kinds, 15 min for storage) is stopped and fails with exit 124.

One job at a time means a long `storage-up` delays a pairing approval behind it.
Callers wait a bounded time (15 s for an approval, 5 s for the window) and report
the timeout; the job still runs when the runner reaches it.

### Callers

As root (CLI, tests) `ce_pairing_window_open/_close`, the request listing and
`ce_approve_pair_request` call the dispatcher directly. As any other user
(`id -u` not 0: the CGI) they submit a job and wait. `api_storage_after_pair`
submits `storage-up <mac>` and returns at once.

### ctrl-exec-api

`hps-storage` reaches nodes with input through `ctrl-exec-cli`, which talks to
`ctrl-exec-api` on a unix socket (`hps-run.sh --input`; `ced run` has no input
option). `ce_dispatcher_bring_up` sets `api_socket` and `api_socket_group = hps`
in the dispatcher config once, adds the service user `ctrl-exec` to group `hps`
(the image creates it that way), and installs the client from
`/srv/hps-resources/packages/ctrl-exec/ctrl-exec-api-plugins-latest.deb` with
`dpkg -i` only when `ctrl-exec-cli` is absent. `latest` is a symlink to the
release file, as for the dispatcher tarball. `program:ctrl-exec-api` creates
`/run/ctrl-exec-api` and drops from root to `ctrl-exec` (with its groups) before
starting the API. The API keeps the dispatcher key; the runner and the root CLIs
reach it through the socket.

## What an operator does by hand

All of it is plain files and a root shell on the IPS.

- Look at the queue: `ls ${HPS_CONFIG_BASE}/clusters/$CLUSTER/jobs/{new,run,failed}`;
  results: `jq . .../jobs/failed/$ID.result.json`. The runner log is
  `${HPS_LOG}/ips/hps-jobs/`.
- A job stuck in `new/` means the runner is down: `supervisorctl status hps-jobs`,
  `supervisorctl restart hps-jobs`. Queued jobs run when it is back.
- Run an action yourself, as root: `ctrl-exec-dispatcher pairing-mode start
  --timeout 300`, `ctrl-exec-dispatcher approve $REQID --replace`,
  `bin/hps-storage $MAC up`. The library detects root and calls the dispatcher
  directly.
- Queue a job from a shell: `hps_job_submit storage-status $MAC`, then
  `hps_job_wait $ID 60` (functions loaded with `source lib/functions.sh`).
- Cancel a queued job: delete its file in `new/`. A job in `run/` cannot be
  cancelled; kill the command it started.
- The API socket: `/run/ctrl-exec-api/api.sock`; `curl --unix-socket
  /run/ctrl-exec-api/api.sock http://localhost/health`. If `ctrl-exec-cli` is
  missing, `dpkg -i` the plugins `.deb` from the lab resources.

## Consequences

- A bug in the CGI can ask for one of eight fixed actions with validated
  arguments. It cannot run the dispatcher, read the keysafe or run a command of
  its choosing.
- The queue directory is the trust boundary. Anything that can write `new/`
  (group `hps`) can request an allowlisted action, including approving a pairing
  request by id; the registry-bound checks in `ce_approve_pair_request` run in
  the CGI before it asks, and are not repeated by the runner.
  Members of `hps` are therefore trusted as the web user is.
- `www-data` can read results, which carry dispatcher and `hps-storage` output
  (no keys: the key never leaves the keysafe process).
- Latency: a request is picked up within about 0.5 s, plus the time of any job
  ahead of it.
