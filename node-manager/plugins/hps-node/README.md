# hps-node

A ctrl-exec agent plugin: the single allowlisted entry point through which the
HPS IPS drives node-manager operations on a provisioned node over mutual TLS.

## Purpose

HPS provisions nodes by PXE and then needs to run setup and lifecycle
operations on them. Rather than exposing an arbitrary remote-exec surface,
every IPS-initiated node operation goes through this one script, invoked by
ctrl-exec with the ce-agent-plugins subcommand pattern. The script sources the
HPS node function bundle (fetched during PXE bootstrap and installed at
`/usr/local/lib/hps-bootstrap-lib.sh`) and dispatches the subcommand to the
matching `n_*` node function.

The subcommand `case` in `hps-node.sh` is the authorisation surface. The
privileged ctrl-exec C executor is deferred (see
`docs/adr/0003-ctrl-exec-agent-packaging.md`), so scripts run as the agent
user with no namespace sandbox; this curated list of subcommands — not a
generic "run any node function" bridge — is what bounds what the IPS can
invoke. To expose a new operation, add a `case` label; never route a
caller-supplied function name.

## Subcommands

| Subcommand | Action |
|---|---|
| `ping` | Confirm the agent can load the HPS function bundle |
| `run-init` | Run this node's `HPS_INIT_SEQUENCE` (`n_init_run`) |
| `set-status <state>` | Report a lifecycle STATE to the IPS |
| `opensvc-join <token>` | Join the OpenSVC cluster with an IPS-minted token |
| `vm-create <name> <spec>` | Create a KVM VM on this node (TCH KVM profile) |

Exit codes: 0 success, 1 operation error, 2 usage or configuration error.

## Dependencies

- `bash` (Alpine: `bash` apk; Debian: `bash`)
- `coreutils` (`hostname`, `cat`)
- The HPS node function bundle at `/usr/local/lib/hps-bootstrap-lib.sh`,
  installed during PXE bootstrap. Override the location with the
  `HPS_BOOTSTRAP_LIB` environment variable (used by the test suite).

## Installation

Installed by HPS during node bootstrap (`n_install_ctrl_exec`). Manually:

```bash
cp hps-node.sh /usr/local/sbin/hps-node
chmod 0750 /usr/local/sbin/hps-node
chown root:ctrl-exec-agent /usr/local/sbin/hps-node
```

## scripts.conf

Add the plugin to the agent allowlist so ctrl-exec will run it:

```bash
echo "hps-node = /usr/local/sbin/hps-node" >> /etc/ctrl-exec-agent/scripts.conf
```

Reload the allowlist afterwards: SIGHUP the agent on systemd/procd hosts, or
restart the service on OpenRC (Alpine) nodes.

## Examples

Confirm connectivity and bundle load:

```bash
ced run tch-050 hps-node -- ping
```

Report a lifecycle state and run the node's init sequence:

```bash
ced run tch-050 hps-node -- set-status INSTALLING
ced run tch-050 hps-node -- run-init
```

Create a VM on a KVM host:

```bash
ced run tch-050 hps-node -- vm-create web01 /srv/vm-specs/web01.spec
```

## Limitations

- The subcommand set is fixed by design; new operations require a code change,
  not configuration.
- Without the ctrl-exec C executor, the plugin runs as the agent user with no
  namespace or capability sandbox; the allowlist is the only containment.
- `opensvc-join` requires a token minted on the IPS and passed as an argument;
  the plugin does not mint or fetch tokens itself.
- Diskless nodes rebuild their root each boot, so the plugin and its allowlist
  entry must be reinstalled per boot cycle by the HPS bootstrap.

## Tests

`bash test/run.sh` — stubs the node bundle, so it needs no PXE environment,
no ctrl-exec and no network. See `test/TEST-REPORT.md` for the last run.

## Licence

AGPL-3.0-or-later, consistent with the HPS project. See `LICENSE`.
