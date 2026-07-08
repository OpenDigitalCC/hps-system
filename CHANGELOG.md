---
title: "HPS Changelog"
subtitle: "High-level change history, keyed by commit reference"
brand: plain
---

# Changelog

High-level history of HPS, extracted from the git log. The repository carries
no version tags, so entries are keyed against commit references (short SHA) and
grouped into thematic spans rather than version headings. Full detail always
lives in the git log; follow a commit ref into the log for the specifics. New
capabilities and removals are called out explicitly.

## Unreleased (branches in review)

Work committed on `claude/*` branches, not yet on `main`:

- `claude/ctrl-exec-integration`, `claude/ctrl-exec-dispatcher` — added:
  ctrl-exec (mTLS remote execution) as the node setup/exec mechanism, with
  registry-bound automatic enrolment, the `hps-node` agent plugin, node-side
  agent delivery, and IPS dispatcher bring-up; removed: the MAC-trust
  `osvc_cmd` CGI join path and the OpenSVC task exec bus; changed: VM creation
  now runs over ctrl-exec with OpenSVC kept only as the health/placement gate.
  See `docs/adr/0001..0003`.
- `claude/dedup-functions` — changed: consolidated the duplicated
  `host_config` / `cluster_config` compatibility aliases to a single
  definition.

## 25f4602–94eef2e — Registry refactor and bootstrap (2026-07-08 migration)

Migration of the November–December 2025 refactor developed on the deployed
instance into the repository.

- boot: added a two-tier bootstrap (`lib/hps-system.sh` initialiser plus a
  rewritten loader) and `hps_get_config` as the single configuration service.
- registry: registry v2 — moved the registry library out of `functions.d/`,
  added an explicit cluster argument and `list_all` / `count` / `destroy`
  commands.
- config: renamed the cluster registry key namespace to `network_*` / `osvc_*`;
  changed the default OpenSVC heartbeat to unicast.
- cluster: split the interactive cluster tooling from the non-interactive
  functions; service configuration (supervisor, dnsmasq, nginx, rsyslog) is now
  registry-driven.
- api: reduced request latency with single-pass `jq` extraction, jq-free client
  fast paths, and a four-worker fcgiwrap pool.
- removed: the legacy `__guard_source` mechanism and `scripts/hps-initialise.sh`.

## 7128551–14dcc03 — JSON registry migration (Nov 2025)

- config: migrated configuration management from the key-value store to the
  JSON registry functions — the durable shift underpinning the later refactor.
- api: added the node API client and registry documentation; corrected
  client-api search-parameter examples.

## 6db4f17–096c4d3 — Init/bundle model and storage (Nov 2025)

- node-manager: re-implemented init and library bundling to support different
  node states, types and operating systems (the per-OS/type/profile bundle
  model).
- storage: added iSCSI/LIO and ZFS management functions for SCH storage nodes.
- boot: refactored `boot_manager.sh` with required-parameter checks; added
  host-variable management.
- docs: restructured the DOCUMENTATION tree; enhanced the documentation
  generator.

## 5152444 and earlier — Platform foundations (Feb–Nov 2025)

- provisioning: the PXE/iPXE boot manager, the node-manager function
  architecture, and the iPXE menu/init handling.
- lifecycle: rescue functionality, Alpine and Rocky installer functions, and
  kickstart scripts.
- orchestration: OpenSVC init and agent integration for cluster nodes.
- housekeeping: repeated cleanup of `boot_manager.sh` and removal of deprecated
  code across the early history.

## Maintenance

This changelog is maintained at each non-functional close-out (see
`/srv/projects/rules/nonfunctional-close.md`, documentation dimension). Add a
span or bullet against the relevant commit refs when an area is touched, a
capability is added, or a feature is removed.
