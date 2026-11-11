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

## Resource monitoring of the paired nodes (2026-11-11)

- new: `nagios-check` node script (ctrl-exec-plugins v0.3.11, new flake input
  `ctrl-exec-plugins`) with monitoring-plugins, `check_mem` and an HPS
  `check_zpool`; `/etc/nagios-checks/checks.conf` generated per node
  (`nix/modules/hps-monitor.nix`, in node-base and node-converged).
- new: `hps-monitor run|loop|interval` on the IPS (supervisor program
  `hps-monitor`): one syslog line per check and per host, a `tick` line per run;
  parallel, never overlapping; paired nodes only. `docs/MONITORING.md`.
- new: cluster key `monitor_interval_seconds` (0 disables, else 10..86400,
  default 60); catalogue rule `int0:MIN..MAX`.
- `nix/build.sh`: `CTRL_EXEC_PLUGINS_FLAKE` overrides the new input.

## Scale test phase 1: fabric bridge and emulated hardware (2026-11-11)

- new: network layout entry `kind: fabric` (`purpose: emulated-switch`, optional
  `mtu`, default 9000): `net-bridge-ensure` builds a VLAN-aware bridge with no
  uplink, no address and nothing in VLAN 1; `hps-cluster-config` validates it.
- new: `vm-define --vlan-pvid`, `--vlan-tagged`, `--nic-model`, `--disk-bus`,
  `--smbios`; `vm-start` applies recorded VLANs to the guest's tap ports with
  `bridge vlan` (a NIC on a VLAN-aware bridge without a pvid is refused).
- new: workload definitions: `nets` entries may be `{net, pvid, tagged, model}`
  and a VM may have `hardware: {disk_bus, smbios}`.

## IPS-14: a held node waits at iPXE and boots its role when one is set (2026-11-11)

- audit image: after the IPS accepts the audit (HTTP 200) it reboots
  (`systemctl reboot`); a failed post leaves it up. Cluster key
  `held_reboot_after_audit=false` keeps it up (`hps.audit_reboot=0`), for
  inspection of a held node over ctrl-exec, which the reboot otherwise ends.
- iPXE: a HELD host with its audit stored is served a hold script (message,
  `sleep`, chain back to `boot_manager.sh?cmd=init`) instead of the audit
  image; cluster key `hold_retry_seconds` (5..3600, default 30). Assign needs
  no power action: the next retry boots the role. Holds log at debug.
- new: `hps-onboard reaudit <mac>` (host key `audit_stale`, cleared when a new
  audit is stored); the audit schema version is not checked.

## IPS-15: every MAC of a machine identifies the same host (2026-11-11)

- new: the audit image records `net.nics` (interface, MAC, physical, driver,
  speed). Intake stores the physical NIC MACs as host key `macs` and refuses
  (409) a MAC another host holds. `host_resolve_mac` / `HPS::Registry->resolve_mac`
  turn any recorded MAC into its host; the iPXE init, the boot_manager CGI and
  `hps-onboard` (show, assign, repin, nets, forget), `hps-bmc` and `hps-storage`
  use it. `dhcp_addresses` has one line per host with all its MACs. Registry
  keys added: `macs`, `boot_mac_last`. The MAC index is computed on demand.

## IPS-08: modular out-of-band power control (2026-11-10)

- new: `hps-bmc status|on|off|force-off|reset|pxe-once|identify <host>`, `set`,
  `credential`, `device`, `select`, `list` (`HPS::BMC`, `docs/BMC.md`); drivers
  `hpe-ilo`, `redfish-generic`, `dell-idrac` (unproven), `ipmi`, `external`,
  `manual` under `lib/bmc/drivers`; the driver is chosen from the audit by
  `lib/bmc/drivers.map` and an operator choice is never replaced by an audit.
- audit: the audit records the BMC identity (`ipmitool lan print`, `mc info`,
  DMI types 38 and 42); the audit image carries `ipmitool` and the IPMI modules.
- keysafe: `put_secret`, `get_secret`, `has_secret`, `delete_secret` for
  operator-set credentials. Registry keys added: `bmc_driver`,
  `bmc_driver_source`, `bmc_addr`, `bmc_options`, `bmc_evidence`, `bmc_last`,
  `power_devices`.

## IPS-07: registry key catalogue, workload destroy keeps the definition (2026-11-10)

- registry: new `HPS::Registry::Keys` table and generated `docs/REGISTRY-KEYS.md`
  (name, scope, type, writer, meaning for every key the code writes; a test fails
  on an uncatalogued key); typed accessors `host_get_epoch` and `host_get_bool`
  refuse a wrong-typed value and name the key; `bin/hps-registry-keys`.
- compatibility: host key `ctrl_exec_paired_at` (epoch) is written at pairing and
  read first; `ctrl_exec_paired` keeps the same epoch value for one release and is
  then removed. Registry keys added: `ctrl_exec_paired_at`,
  `workload_<name>_destroyed`.
- workloads: `hps-workload destroy` keeps `workloads/<name>.json`; `destroy
  --forget` removes it too (job kind `workload-destroy <name> [--forget]`).
  Changed behaviour: destroy no longer deletes the definition.

## 3935261–dd1c254 — Phase 1: NixOS lab trial (2026-11-09)

Everything on `main` after `91c9272`: changesets CS-1.1 to CS-1.16 plus
supervisor follow-ups. Verified on one DL360 Gen9 (audit image six boots, node
image once) with shim-based tests elsewhere; see `.nonfunctional-report.md` for
what is hardware-tested and what is not. Plan: `plans/phase-1.md`.

- boot path (`2716814`, `42cfdf3`): fixed — `cluster_registry get` calls missing
  the cluster argument, `os_config_select` type case, the `STATUS` key typo,
  bundle init ordering (`base/` first), `HOST_PROFILE`/`PROFILE` read; added
  `ipxe_host_install_menu`, `n_init_run` lines with arguments, post-config
  hooks after a host config change.
- UEFI and TFTP (`3935261`, `2e4f08a`): added a dnsmasq `client-arch` split
  (`snponly.efi` for UEFI, `undionly.kpxe` for BIOS), TFTP root populated at
  pre-start, `/nixos/` and `/nix-cache/` locations, interface binding from
  `network_dhcp_interface`; changed dispatcher bring-up to ctrl-exec 0.14 paths.
- registry and onboarding CLI (`e793422`, `bd03029`): added the Perl registry
  (`HPS::Registry`, same on-disk layout as the Bash registry) and `hps-onboard`
  (`list`, `show`, `assign`); core Perl modules only; Test::More suites in `t/`.
- NixOS flake and builder (`ed56ce4`, `b57168e`, `c2a2a3c`, `42220eb`,
  `44453b1`): added `flake.nix` (nixos-26.05), the audit and node netboot
  images, `nix/build.sh` (pin directory with content hash, `boot.json`, file
  binary cache); changed ZFS to never force-import.
- HELD state and audit intake (`00ee857`, `73e0784`, `9506a6e`, `617cd34`):
  added the `HELD` onboarding state — an unknown MAC boots the audit image,
  never a menu — and `cmd=node_audit` intake with a size cap; changed
  `ipxe_boot_nixos` to be manifest-driven and pin-aware; added pool inspection
  with read-only foreign-pool import.
- ctrl-exec enrolment on NixOS (`7bffa76`, `437c730`, `3964440`, `a30af87`,
  `dd1c254`): added the NixOS node side (compat shims, `hps-pair`,
  `hps-node-init`); changed the approver to accept `NETWORK_BOOT` and `HELD`,
  to open a pairing window per boot, to bind the request to the API caller
  address, and to use `approve --replace` and `--name` (ctrl-exec 0.14.3+);
  changed `api.sh` to take the MAC from the connection only; the audit image
  now pairs so a held node can be inspected over ctrl-exec; ADR 0002 and 0003
  amended.
- time (`760cce3`, `9506a6e`): added chrony on the IPS as the enforced node
  time source (upstream optional, `network_time_upstream`) and timesyncd on
  nodes; fixed the epoch-2001 clock on first boot.
- logging (`35039af`, `3b13bcd`, `438ab19`, `985c77f`): added node syslog
  forwarding from early boot (`hps-log-target`); changed all IPS service
  logging to go through syslog, one tree under `hps-log/ips/<program>/`;
  fixed `n_remote_log` without a tty; added `docs/LOGGING.md`.
- node scripts and executor (`437c730`, `6178461`, `617cd34`): added node
  operations as ctrl-exec scripts (`storage-pool-inspect`, `storage-disks`,
  `node-dmesg`, `node-facts`), the privileged executor with a `node` profile
  (root plus capabilities), and `scripts/hps-run.sh`; documented in
  `docs/SECURITY.md`.
- networking (`617cd34`, `985c77f`): changed nodes to configure only the NIC
  they booted from (networkd matched by MAC, so a second NIC on another LAN is
  left alone).
- bootstrap (`d78e8d7`): added non-interactive `scripts/cluster-bootstrap.sh`.
- naming (`b7177c6`, `dd1c254`): changed node names to carry the cluster DNS
  domain; the audit image uses `<host>.<domain>`, the node image the bare
  host name (known inconsistency).
- known deferrals: single shared pairing window; fixed image-wide ZFS host id;
  no image garbage collection; static-IP allocator ignores reserved addresses;
  `flake.lock` not committed.

## Unreleased (branches in review)

Work committed on `claude/*` branches, not yet on `main`:

- `claude/ctrl-exec-integration`, `claude/ctrl-exec-dispatcher` — added:
  ctrl-exec (mTLS remote execution) as the node setup/exec mechanism, with
  registry-bound automatic enrolment, the `hps-node` agent plugin, node-side
  agent delivery, and IPS dispatcher bring-up; removed: the MAC-trust
  `osvc_cmd` CGI join path and the OpenSVC task exec bus; changed: VM creation
  now runs over ctrl-exec with OpenSVC kept only as the health/placement gate.
  See `docs/adr/0001..0003`.
- CS-2.0a — changed: lighttpd (mod_cgi) replaces nginx + spawn-fcgi +
  fcgiwrap on the IPS; removed: the nginx config generator and the nginx and
  fcgiwrap supervisor programs. See `docs/adr/0004-lighttpd.md`.
- `claude/dedup-functions` — changed: consolidated the duplicated
  `host_config` / `cluster_config` compatibility aliases to a single
  definition.
- IPS-02 — added: `n_init_run` reports each step's result (rc, seconds, own
  stderr tail) to the IPS (`cmd=host_init_result`); host keys `init_result`,
  `init_result_prev`, `init_ok`; `hps-onboard show` Init section and
  `list --all`; failed init steps log at `err`. Fixed: `n_remote_host_variable`
  and `n_remote_cluster_variable` reported the stale error of an earlier call.

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
