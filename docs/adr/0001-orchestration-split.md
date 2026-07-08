# ADR 0001 — Split orchestration: ctrl-exec for remote setup, OpenSVC for durable services

- Status: accepted
- Date: 2026-07-08
- Tags: orchestration, ctrl-exec, opensvc, architecture

## Context

HPS provisions cluster nodes (SCH storage, TCH compute, DRH recovery) and
must then run setup and operational commands on them. OpenSVC v3 has been
the single orchestration mechanism, but an audit of the integration surface
showed it is used predominantly as a remote-execution bus, not as a service
manager:

- `o_opensvc-task-functions.sh` creates transient OpenSVC services carrying
  a `task#` purely to run a shell command on a node, then purges them.
- `o_vm_create` builds throwaway `vm-ops-create-*` services as the
  transport for `n_vm_create`, so no durable service state survives the
  operation.
- The node join path (`boot_manager.sh?cmd=osvc_cmd` →
  `_osvc_get_auth_token`) issues 15-second cluster-join tokens
  authenticated only by client MAC address.
- The only genuinely durable managed service is `iscsi-manager` (LIO on
  SCH).

OpenSVC's core purpose is service health and availability management;
HPS's primary need is remotely setting up systems. ctrl-exec
(/srv/projects/ctrl-exec, mTLS remote script execution with per-node
script allowlists, no shell, structured results) matches that need
directly.

## Decision

Remote command execution and node setup move to **ctrl-exec**. OpenSVC is
retained **only** for durable availability management:

- **ctrl-exec takes**: the `o_task_*` exec bus; the exec-transport half of
  `o_vm-functions.sh`; node join-token delivery (the `osvc_cmd` CGI path is
  removed); all future "run this on node X" needs.
- **OpenSVC keeps**: `iscsi-manager` and future durable services, cluster
  membership and heartbeat, node labels for placement, the
  `o_vm_get_healthy_nodes` health gate, and durable VM services
  (`orchestrate=ha`) where failover is wanted.
- **Retired**: OpenSVC as a config-distribution channel (the HPS
  registry/API already fills that role).

Container orchestration for the TCH Docker profile (currently a menu stub
with no implementation) is decided when that profile is designed — not
assumed to be OpenSVC.

## Rationale

Using a service-availability manager as an exec transport costs the
weakest part of the security model (MAC-trust token issuance), obscures
intent (transient services that manage nothing), and couples every remote
operation to OpenSVC cluster state. ctrl-exec provides mutual TLS
identity, per-node script allowlists, no-shell argument passing and
structured audit logging — the properties the remote-setup role actually
needs. Keeping OpenSVC where availability management is real (LIO, VM HA)
preserves the existing investment (self-built Alpine apk, heartbeat
configuration) without forcing a second migration.

## Consequences

- Nodes carry two agents: ctrl-exec-agent (always) and the OpenSVC agent
  (on nodes hosting durable services). Their roles no longer overlap.
- The VM-create flow becomes: health-gate via OpenSVC → `ced run <tch>
  hps-node vm-create …` → optionally register a durable OpenSVC service
  for the VM. This fixes the current gap where VM state evaporates with
  the transient service.
- `o_opensvc-task-functions.sh` and the `osvc_cmd` CGI handler are
  removed; anything still needing them must move to ctrl-exec first.
- ctrl-exec has no rpm packaging yet, so Rocky nodes install from the
  release tarball until an rpm exists (see ADR 0003).
- The IPS container gains the ctrl-exec dispatcher and CA (see ADR 0002
  for the trust bootstrap).
