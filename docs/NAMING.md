# Names

One rule (IPS-06, owner ruling 2026-11-10: full names everywhere, for multiple
clusters): a host's identity is its FQDN, `<label>.<cluster dns domain>`. The
registry keeps only the label (`HOSTNAME`, unique per cluster); the FQDN is
derived, never stored, and only the helpers below join or split names.

`$LABEL` is the registry `HOSTNAME`, `$DOMAIN` the cluster key
`network_dns_domain`, `$CLUSTER` the cluster name.

## The limit

Every node FQDN is at most 63 characters (om3 refuses longer node names:
letters, digits, `.` and `-`, first character alphanumeric, 63 characters). So:

- `hps-cluster-config` refuses a `network_dns_domain` longer than 52
  characters (10 are kept for the label; the longest generated is
  `nixos-001`), and so does the cluster-bootstrap DNS prompt;
- `host_network_configure` refuses to configure a host whose FQDN would be
  longer;
- the helpers (`fqdn_join`, `n_fqdn`, `HPS::Registry::fqdn_of`) refuse and say
  so; hps-node-init and hps-pair stop before naming the node.

## Identities

| Identity | Form | Produced by | Compared by |
|---|---|---|---|
| Registry `HOSTNAME` | `$LABEL` | `host_network_configure` (`_find_available_hostname`) | helpers that derive the FQDN |
| Kernel hostname, static and transient | `$LABEL.$DOMAIN` | `hps-node-init` (`hostnamectl set-hostname`, transient only where the static name cannot be written); the bundle step `n_set_hostname_and_hosts` sets the same | `hps-iscsi-name`, `hps-osvc-config` (read it back with `hostname`) |
| DHCP-supplied name | none (`UseHostname=false`, `SendHostname=false` in the `hps-net` units) | | |
| om3 node name | `$LABEL.$DOMAIN` | the kernel hostname (om3 takes `os.Hostname()`); the IPS list (`osvc_cluster_node_list`, `cmd=cluster_nodes`) names the same FQDN | `hps-osvc-config`: this node must equal one listed name exactly; the names go to `cluster.conf` and `node.conf` as listed |
| ctrl-exec agent name | `$LABEL.$DOMAIN` (`hps-<mac>.$DOMAIN` for a node with no `HOSTNAME`) | `hps-pair` (`request-pairing --name`; with `--no-hostname` it uses the kernel hostname) | `ce_approve_pair_request` (request hostname equals `host_fqdn`, case-insensitive), `hps-run.sh` (the FQDN must be a registered agent, no other form tried), `hps-onboard prune-agents` |
| iSCSI initiator name | `iqn.2026-11.hps.$CLUSTER:$LABEL.$DOMAIN`, i.e. `iqn.2026-11.hps.<cluster>:<fqdn>` | `hps-iscsi-name` (cluster from `cmd=cluster_variable&name=CLUSTER_NAME`); `HPS::Registry::initiator_iqn` on the IPS | the operator gives it as `--initiator` to `hps-storage export`; `HPS::Storage` and `iscsi-export` check the LIO rule |
| iSCSI target name | `iqn.2026-11.hps.$CLUSTER:$HOST:$NAME` (chosen by the operator) | `hps-storage export --iqn` | LIO, `HPS::Storage`, `iscsi-export` |
| Certificate | the agent name above | ctrl-exec at pairing | the dispatcher |

IQN rule: LIO (rtslib-fb 2.2.4) accepts only
`^iqn\.[0-9]{4}-[0-1][0-9]\..*\..*`, a second dot after the date. The earlier
`iqn.2026-11.hps:<hostname>` failed it (chain P run ten, "WWN not valid as:
iqn, naa, eui"); the naming authority `hps.<cluster>` supplies the dot and is
the form the target names already use. `HPS::Storage` refuses an export whose
`--iqn` or `--initiator` fails the rule (`refused`, exit 3), and `iscsi-export`
refuses on the node (exit 3).

## Helpers

| Where | Name | Does |
|---|---|---|
| IPS Bash (`host-functions.sh`) | `fqdn_join <name> [domain]` | label.domain, lower case, refuses over 63 |
| IPS Bash | `cluster_dns_domain [cluster]`, `host_fqdn <mac>` | the cluster's domain; a host's FQDN |
| Node Bash (`node-manager/base/n_configure-hostname.sh`) | `n_fqdn`, `n_shortname`, `n_set_kernel_hostname` | the same on the node (legacy bundle path) |
| Boot scripts (no library sourcing) | `fqdn_of` in `hps-node-init`, `hps-pair` | the same rule, inline |
| Perl (`HPS::Registry`) | `fqdn_of`, `short_name`, `cluster_dns_domain`, `fqdn($mac)`, `initiator_iqn($mac)` | the same |

## Before and after (the survey)

| Place | Before | After |
|---|---|---|
| `hps-node-init` | transient `<label>.<domain>`; a malformed domain left the bare label | static and transient FQDN; a bad domain or an FQDN over 63 refuses |
| `n_set_hostname_and_hosts` (bundle, run after `hps-node-init`) | set the transient hostname to the bare label: the source of the short kernel name om3 saw | sets the FQDN (also `/etc/hostname`, Alpine and Rocky files, on non-Nix systems) |
| `hps-pair` | FQDN with `--name`, but with `--no-hostname` (the node path) no `--name`, so the agent chose its own | FQDN; `--no-hostname` registers under the kernel hostname |
| `hps-net` / `hps-common.nix` | `UseHostname=false` already | unchanged; comments corrected |
| `hps-osvc-config` | matched the first label and wrote the node's own form | exact match; first-label fallback removed; a short kernel name is refused |
| `osvc_cluster_node_list` | label + domain joined inline | `fqdn_join`; skips a host whose FQDN is refused; a forgotten host has no entry |
| `ce_approve_pair_request` | compared first labels | request hostname equals `host_fqdn` |
| `hps-run.sh` | tried `<name>.<domain>`, `<name>`, `<name>..` | the FQDN only |
| `hps-iscsi-name` | `iqn.2026-11.hps:<short>` | `iqn.2026-11.hps.<cluster>:<fqdn>` |
| `HPS::Storage` / `iscsi-export` | any `iqn.` name | refuse names LIO refuses |
| `network_dns_domain` | labels up to 63 | whole domain up to 52 |
| Registry | no way to remove a host | `hps-onboard forget` |
| ctrl-exec agents | stale, short-name and `hps-<mac>` registrations stay | `hps-onboard prune-agents` |

Left as they were: the registry `HOSTNAME` (label), `hps.hostname=` on the
kernel command line (a label for log naming), `hps.domain=` (the domain).

## Forgetting a host

`hps-onboard forget <mac> [--dry-run]` (approval `hps-approve host-forget <mac>`)
refuses a host with storage exports, a pool or a workload instance recorded.
Otherwise it removes, in this order, and prints each step: the ctrl-exec agent
registration (`ctrl-exec-dispatcher unpair <fqdn>`), the registry host (its
approvals go with it), then regenerates the DHCP and DNS files and reloads
dnsmasq (`update_dns_dhcp_files`; IPS-10 owns that generation). A failure at the
agent step leaves the host in the registry, so the command can be run again.
ctrl-exec 0.14.5 has no dispatcher-side certificate revocation: `unpair`
removes the registration so the dispatcher no longer addresses the agent; the
certificate stays valid until it expires, and agent-side `revoked-serials`
lives on the agents, of which a forgotten host has none.

`hps-onboard prune-agents [--dry-run]` removes every registration that is not the
FQDN agent of a registry host. A registry host still paired under an old
short name loses that registration and gets its FQDN one at its next boot (nodes
re-pair on every boot).

## Not verified live

Dotted om3 node names end to end (`om daemon status` with two FQDN-named nodes),
the kernel name surviving DHCP on a real node, the short label resolving on the
node (`/etc/hosts` is store-managed on NixOS; the label is a DNS question for
IPS-10), and LIO accepting the new initiator name.
