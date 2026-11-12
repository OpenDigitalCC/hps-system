# OpenSVC (om3) on HPS nodes

OpenSVC v3 (`om3`) runs on the node profiles that import `hps-opensvc.nix`
(`node-converged` today; a container-host profile imports it unchanged) for three things only: cluster
**membership**, **health**, and **local service management** on the node that
owns a service. HPS and its IPS are the only decision makers (ADR 0001): the
daemon never places, moves, restarts or fails over anything. The finding that
this is possible is `plans/opensvc-finding.md`; two rig tests (below) prove the
last two unproven points on real nodes.

The bats tests use a shimmed `om`, `curl`, `systemctl` and `hostname`. A real
two-node om3 cluster (`sch-001.lab.hps` and `tch-001.lab.hps`) forms and beats
in the lab: both nodes show `hb#1` running, each peer `is_beating: true`, and
`osvc-status` reports `peers=1 beating=1` (IPS-12 close-out,
`inbox/archive/2026-11-11-IPS-12-om3-shared-cluster-ca.md`, chain P run
nineteen). Cluster CA rotation (`om cluster ca rotate`) has not been run; it
needs a re-export first.

## What it does here

Membership and health
: `opensvc-daemon` on each node exchanges unicast heartbeats with every other
  paired node. `osvc-status` reports who is beating and who is stale.

Local service management
: The node scripts `osvc-object-set`, `osvc-object-start`, `osvc-object-stop`
  and `osvc-object-delete` manage one OpenSVC object per workload part
  (`disk.md` + `container.kvm`) with `om <obj> ... --local`. `HPS::Workload`
  does not call them: it starts and stops a guest directly with the `vm-start`
  and `vm-stop` node scripts. The object scripts exist for the workload plane
  and are exercised by the rig tests; today OpenSVC provides membership and
  health only.

## What it is never allowed to do

* Place or move an object: every object carries `nodes = <the one owner node>`,
  `topology = failover`, `orchestrate = no`, `monitor_action = none`,
  `placement = none`.
* Be driven globally: a plain `om <obj> start` or `stop` (no `--local`) sends an
  expectation through the orchestrator and is never used.
* Be told otherwise: `osvc-object-set` refuses `orchestrate` other than `no`, a
  `nodes` list of more than one name, `placement` or `monitor_action` other than
  `none`, and any keyword outside the list below. `osvc-object-start` reads the
  five keywords back before it starts anything and refuses an object that does
  not hold them. HPS may keep every node frozen (`osvc-freeze`) as a second
  guard; explicit `--local` start and stop work on a frozen node (rig test 1).

The node scripts below are the only way HPS touches OpenSVC. There is no
generic `om` runner on a node.

## Enforced and allowed keywords

| Keyword | Value |
| --- | --- |
| `nodes` | one node name, `^[a-z0-9][a-z0-9.-]*$` |
| `topology` | `failover` |
| `orchestrate` | `no` |
| `monitor_action` | `none` |
| `placement` | `none` |
| `disk#<id>.type` | `md`; also `uuid`, `devs`, `name`, `level`, `chunk`, `spares`, `bitmap` |
| `container#<id>.type` | `kvm`; also `name`, `vcpus`, `memory`, `disk`, `bridge`, `network`, `osinfo`, `image`, `cdrom` |
| `fs#<id>.type` | `flag` (the trivial resource of the rig tests) |

A value may contain only `[A-Za-z0-9_./:@,+-]`. A new object must set the five
enforced keywords in its first call (`om <obj> create --kw ...`); an existing
one is changed with `om <obj> set --local --kw ...`.

## Node scripts

All run as root under ctrl-exec profile `node`; each logs every command as
`+ <command>` on stderr.

| Script | Does | Exit codes |
| --- | --- | --- |
| `osvc-status` | `om daemon status --format json` and `om mon --format json`, both printed, then `OSVC <node> peers=<n> beating=<n> stale=<list or -> frozen=<yes or no>`. Read-only | 0 healthy, 1 `om` failed (daemon down), 2 a peer is stale, 3 usage |
| `osvc-object-set <obj> <kw=value>...` | Create or change an object, see above | 0, 1, 2 usage, 3 refused |
| `osvc-object-start <obj>` | Check the enforced keywords, then `om <obj> start --local` | 0, 1, 2, 3 |
| `osvc-object-stop <obj>` | `om <obj> stop --local` | 0, 1, 2 |
| `osvc-object-delete <obj>` | `om <obj> delete --local --ignore-not-found`; stops and unprovisions nothing | 0, 1, 2 |
| `osvc-freeze`, `osvc-thaw` | `om node freeze`, `om node thaw` | 0, 1, 2 |
| `osvc-secret-set` | Cluster secret on stdin (`input = raw`), see below | 0, 1, 2, 3 |
| `osvc-ca-export` | Prints this node's cluster CA (`<mtime> <base64>`), read-only; see The cluster CA | 0, 1, 2 |
| `osvc-rig-probe` | Lab test only (rig test 2); remove after the rig results are recorded | 0, 1, 2, 3 |

`<obj>` is `svc/<name>` or `<name>`, `^[a-z][a-z0-9-]{0,31}$`.

## How to read `osvc-status`

The summary line is the quick answer. `stale=` lists peers that no heartbeat
stream sees beating (`is_beating` false in every stream of
`.daemon.heartbeat.streams[].peers.<peer>`), which `osvc_hb_timeout` (default
15 s) after a node goes away. A node alone in its cluster has `peers=0` and is
healthy. The JSON follows under `== om daemon status --format json`:

* `.daemon.nodename` – this node, `.cluster.status.is_frozen` – frozen.
* `.cluster.node.<node>.instance` – the instances each node reports, per object,
  `.status.avail` being `up`, `down`, `warn` or `n/a`.
* `.daemon.heartbeat.streams[]` – one stream per heartbeat and direction.

The "peer gone" field the IPS will use is `.daemon.heartbeat.streams[].peers.<peer>.is_beating`
(the field names come from the om3 source; rig test 2 and the kill-a-node check
record them on a real daemon).

## Files on the node

Nothing persists across a boot (RAM root); everything is rewritten at start.

| Path | Holds |
| --- | --- |
| `/etc/opensvc/cluster.conf` | `[cluster]` name, node list, secret. Mode 0600 |
| `/etc/opensvc/node.conf` | `[listener] port`; `[hb#1]` type, interval, timeout, one `addr@<node>` per node. Mode 0600 |
| `/etc/opensvc/<name>.conf` | An object's configuration (made by `osvc-object-set`) |
| `/var/lib/opensvc` | Daemon state |
| `/run/hps/osvc-cluster-secret` | The delivered cluster secret. Mode 0600 |
| `/run/hps/opensvc.env` | `OSVC_DAEMON_ARGS` for the unit (log level) |
| `/etc/hps/hps-osvc-config` | The generator (`node-manager/nixos-26/boot/hps-osvc-config.sh`) |

## Configuration comes from the IPS

`opensvc-daemon` is a systemd unit (`om daemon run`, `Restart=always`, after
`hps-node-init` and the network). Before each start `hps-osvc-config` reads the
IPS and writes the files above:

* cluster name and the paired nodes (name and IP): the read-only CGI command
  `cmd=cluster_nodes` (`osvc_cluster_node_list`). A node name is the registry
  `HOSTNAME`, lower case, plus `.<network_dns_domain>` when the cluster has one.
  A host is listed once it is paired.
* the `osvc_*` cluster keys: `osvc_listener_port` (1215), `osvc_hb_type`
  (unicast), `osvc_hb_interval` (5), `osvc_hb_timeout` (15), `osvc_log_level`
  (info). Log level is a command-line flag in om3: `debug` adds `--debug`; `info`
  is the default; `warn` and `error` are not selectable and run at `info`.
  `osvc_web_ui`, `osvc_web_port`, `osvc_templates_url` and `osvc_packages_url`
  have no use here and are ignored.
* The node firewall opens TCP 1215 (listener) and 10000 (heartbeat). A
  different `osvc_listener_port` needs the port list in `hps-opensvc.nix` to
  follow it.

### The cluster secret

om3's listener and heartbeat share one secret. It is in the keysafe
(`HPS::Keysafe`, purpose `opensvc-cluster`, 16 random bytes sent as 32 hex characters, created on first use). om3 uses the secret string itself as the AES key of its heartbeat secret, so it must be 16, 24 or 32 characters; a 64-character value stops the daemon at bootstrap ("crypto/aes: invalid key size"). The unit runs with `HOME=/var/lib/opensvc`, which the daemon bootstrap needs, never
in an image, a log or an argument. On the IPS:

```
hps-osvc deliver $NODE
```

sends it as confidential input to `osvc-secret-set`, which stores it in RAM and
restarts `opensvc-daemon`. Until it has arrived the unit stays down
(`ConditionPathExists`). Run it for every node, and again on every node after a
node is paired, because the restart is also what refreshes the node list.

A deliver that works records the host key `osvc_delivered_at`: the host is an
om3 cluster member. Nodes run from RAM, so a reboot loses the secret and om3
stays down; after every pairing the API queues an `osvc-deliver <mac>` job
(`hps-osvc deliver <mac>` in the job runner's work lane, after the host's
`net-up` and `storage-up`) for a member, so om3 comes back on its own (s1:
sch-002 after a power-off, `osvc_hb` UNKNOWN and om3-hb issues urgent until a
hand deliver). A host never delivered to is not a member and gets no job
("osvc hook: ... not an om3 cluster member", info); the first deliver to a
host stays an operator step, and nothing here can fail a pairing. The other
nodes keep the rebooted node in their node list; deliver to them again only
when a node is new.

### The cluster CA

om3 nodes authenticate each other with certificates from the cluster CA
(`system/sec/ca`), and node tokens are signed with its key, so every node needs
the same CA. A RAM-booted node would otherwise create its own at every boot and no
two nodes would trust each other. The IPS keeps the one CA in the keysafe (stored
secret `opensvc-ca`, one line `<mtime> <base64 of ca.conf>`, never logged):

- The first `hps-osvc deliver` finds none, sends the secret alone, and reads the CA
  the node daemon created through the read-only node script `osvc-ca-export`
  (`node` profile, no input), then stores it.
- Every later `hps-osvc deliver` sends it as a second input line to
  `osvc-secret-set`, which writes `ca.conf` (0600, directory 0700) with the stored
  mtime before restarting the daemon. Discovery prefers the newest copy, so the
  mtime must be the original. When the node's CA differed, `cert.conf` is removed
  and the daemon reissues the node certificate from the shared CA. A node that made
  its own CA before the keysafe held one is brought into line by its next deliver.
- `hps-osvc ca-forget` deletes the stored CA for a deliberate re-bootstrap.
  `om cluster ca rotate` is not supported: HPS would re-seed the old CA at the next
  boot, so a rotation needs a re-export first. A second cluster has its own keysafe
  and so its own CA.

## Lab rig tests

Run on the IPS, against nodes whose daemons are up (`hps-osvc deliver` done).
Both use the throwaway object `rig0` (a trivial `fs.flag` resource), print each
node script's output and then `PASS:` or `FAIL:` per check, and clean up after
themselves.

```
bash lab/osvc-rig-1.sh $NODE
bash lab/osvc-rig-2.sh $NODE $PEER
```

Rig 1: `start --local` and `stop --local` work on a frozen node; thawing the node
does not start the object. Rig 2: `om node drain`, `om cluster thaw` and a plain
`om <obj> start` never start an instance on `$PEER` (run it without `$PEER` and
the peer checks are skipped, which does not answer the question). A failure of
rig 2 reads: "OpenSVC v3 can disable orchestration per object, but `<command>`
started a service on a peer, so it cannot be trusted as a no-failover manager."
Rig 2 uses the lab-only `osvc-rig-probe`, which refuses on a node that has any
object other than `rig<N>`, because `drain` stops everything.

Not covered by the scripts (by hand, recorded in the runsheet): kill a node and
see its peers show it stale within `osvc_hb_timeout` with no instance of its
objects appearing elsewhere; reboot a node and see its objects stay down.
