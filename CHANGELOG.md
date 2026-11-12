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

## hps-metrics: monitor results and utilisation per host (2026-11-12)

The owner asked for a low-resolution utilisation indicator per machine in the
browser, with the separate resources on a click. The monitor's results were
only in syslog; no read verb gave them, so the browser's health badge could not
read the monitor either.

- new: `hps-metrics last <mac|hostname|ips|all>`: each host's newest monitor
  result (checks, state, text, perfdata, unreachable) with its utilisation;
  `hps-metrics series <host|all> [--hours N] [--step S]`: utilisation per time
  bucket (max within a bucket, last state per check). Utilisation: cpu busy,
  mem 100 - available, load per core x 100 (capped), disk the worst used or
  inode %, pool the worst capacity; compound = their max. diskio busy is shown
  but not in the compound; net has no capacity and is throughput only
  (docs/MONITORING.md).
- new: an ips-admin tool; the gate opens `last` and `series` only.
- changed: `HPS::Log` takes a per-call scan budget (`max_scan`); its own stays
  64 MiB.

## Pairing survives a cluster booting at once; guests stop in storage order (2026-11-12)

Incident 2026-11-12 09:27 UTC, s1 after a host reboot: six nodes asked to pair
at once. The approval jobs waited behind sch-001's 30 s `storage-up` in the one
serial job runner, the approver gave up and answered a bare 403, the first
approval closed the pairing window under the other five, and their retries came
after their own 300 s windows. Each VM had to be rebooted by hand. In the same
shutdown, s1's SCH VMs stopped before its TCH VMs and the probes' md mirrors
lost both iSCSI legs.

- changed: `hps-jobs` runs the pairing kinds in their own lane beside the work
  lane (one job at a time in each); an approval never waits behind a storage,
  net or workload job. One approval waits at most
  `CTRL_EXEC_PAIR_REQUEST_TIMEOUT` (300 s, equal to the node's
  `HPS_PAIR_TIMEOUT`) for its jobs (ADR 0006).
- new: the pairing API says why: 200 `paired`; 503 `pending`,
  `unknown_request`, `no_request` (retry); 410 `outside_window` (reboot); 403
  `reboots_exhausted`, `refused` (stop). The body carries `reason`, `details`,
  `window_left`, `last_boot_at` (ADR 0002, amendment 2026-11-12).
- changed: the pairing listener stays open while another host is within its
  own window and unpaired; check 3 (the per-host window) is unchanged.
- new: `hps-pair` retries after 5, 10, 20, 40, 60, 60 ... s within the window,
  reboots into netboot on 410 (at most 3 times, host key `pair_reboots`), and
  on 403 exits 3, which `hps-node-init` and `hps-audit-pair` do not restart
  (`RestartPreventExitStatus = 3`). After the last reboot the IPS records
  `pair_failed_at`; `hps-monitor` logs `state=PAIR_FAILED` and
  `hps-ips-check` a WARN `pairing`. A pairing clears both keys.
- changed: a storage provider (a `boot: network` VM with disks: a nested SCH
  or IPS) defaults to workload priority 1 and, at one priority, starts first
  and stops last. `vm-start --priority N [--provides-storage]` records the
  order on the node, and `hps-shutdown-storage` (every poweroff and reboot,
  `node-poweroff` included) stops guests priority 5 first, consumers before
  providers (docs/WORKLOADS.md "Stop order on a node").
- tests: `t/207-jobs-pairing-lane.t`, `t/208-pair-failed-monitor.t`,
  `t/209-workload-stop-order.t`, `test_p3_210_pair_retry.bats`,
  `test_p3_211_pair_window.bats`, `test_p3_212_guest_stop_order.bats`; the
  hps-ips-check pairing case in `test_p3_90_ips_check.bats`.
- not done: the dispatcher listener is still one for the IPS and an open while
  it runs does not extend it (IPS-17): a host that boots late in another
  host's window can find it stopped early, and then gets its window back only
  through the reboot.

## A full CNH state disk can be recovered, and VM disks grown (2026-11-12)

Lab 2026-11-12: a bootstrap of a new pin filled cnh-001's 20G disk (the s1 IPS
state); the inner IPS's tools could no longer run, so its `hps-pins prune` was
impossible and nothing in HPS could free space or grow the disk.

- new: `cnh-ips-cleanup [--dry-run]` (CNH node script): removes `*.part` files
  under `/var/lib/hps-ips` and incomplete pins (no `SHA256SUMS`, or a profile
  without `boot.json`), never the latest pin, nothing else; reports the bytes
  freed and the space free.
- new: `cnh-ips-bootstrap` checks the free space before the first download and
  refuses (3, nothing fetched) when it is less than the bytes still to fetch
  plus a margin of 10% of the disk or 1 GiB, whichever is larger; the refusal
  names both numbers.
- new: growing a VM's disk in three node scripts. `storage-zvol-grow
  <pool>/enc/[vm/]<name> <size>` (`zfs set volsize`; only grows, refuses a
  shrink or an unknown dataset), `vm-disk-resize <vm> <target|/dev/zvol path>`
  (`virsh blockresize` to the zvol's size, for the running guest) and, on a
  CNH, `cnh-disk-grow` (`resize2fs`, online). `hps-storage <host> zvol-grow`
  (`HPS::Storage`) and `hps-workload grow-disk <workload> <vm> <disk> <size>`
  (the first two, for a single-leg local disk) drive them from the IPS.
- docs: `docs/CONTAINER-HOST.md` "When the state disk fills",
  `docs/WORKLOADS.md` (grow-disk), `docs/VM-LIFECYCLE.md` (vm-disk-resize).
- tests: `test_p3_174_cnh_ips_bootstrap.bats` (space check),
  `test_p3_206_cnh_ips_cleanup.bats`, `test_p3_207_cnh_disk_grow.bats`,
  `test_p3_208_storage_zvol_grow.bats`, `test_p3_209_vm_disk_resize.bats`,
  `test_p3_200_ips_admin_datasets_and_define.bats`, the wiring tests, and
  `t/206-disk-grow.t`.

## Disk checks: every persistent filesystem and pool, nodes and IPS (2026-11-12)

- new (node image): `check_fs`, space and inode use, WARNING at 80% used,
  CRITICAL at 90%. Checks `disk_var_lib_containers` and
  `disk_var_lib_hps_ips` (container hosts: the CNH state disk),
  `disk_var_lib_hps_builder` (builders) and `disk_other` (every other
  persistent local filesystem, every node); `zpool_cap`
  (`check_zpool -m cap`, pool capacity) on storage nodes. Takes effect with a
  new node image.
- new (IPS): hps-monitor also checks the IPS's own resources and log
  filesystems each tick (host `ips.<domain>`, checks `disk_resources`,
  `disk_log`), and grades the nodes' disk checks again with the new cluster
  keys `monitor_disk_warn_pct` (default 80) and `monitor_disk_crit_pct`
  (default 90), so a threshold change needs no image.
- change: hps-ips-check `disk resources` and `disk log` WARN at
  `monitor_disk_warn_pct` used and FAIL at `monitor_disk_crit_pct` (was: below
  15% and 5% free), inodes included.
- tests: `test_p3_207_disk_checks.bats`, `t/207-monitor-disk.t`; p3_90 and
  `t/101-hps-monitor.t` updated.

## hps-log: read a host's or the IPS's recent syslog (2026-11-12)

- new: `hps-log host <mac|hostname>` and `hps-log ips` (`--lines N` up to
  500, `--since MINUTES`, `--grep WORD`, `--json`), an ips-admin tool, so it
  works through `hps-op`. A host's lines come from every address the registry
  knows for it (its `IP` and the addresses its stored audit recorded), merged
  by time, newest last; each line has a level (error, warning, info) read from
  its text. Read-only.
- security: a line that may carry a secret is printed as `[redacted]`: any
  word matching the cluster-config secret-name rule, a PEM marker, an operator
  token or 64 hex digits; `--grep` matches after redaction
  (`docs/LOGGING.md`).
- tests: `t/206-hps-log.t` (temp log tree and registry),
  `test_p3_206_hps_log_wiring.bats` (allowlist, wrapper, gate: `host` and
  `ips` only).

## Workload start works on nodes with an older vm-start (2026-11-12)

- fix: `hps-workload start` passes `vm-start <vm> --priority N
  [--provides-storage]`. A node on an older image does not know those options
  and exits 2 (usage), so every start on the lab's sch-001 failed after the
  stop-order change landed. On exit 2 the IPS now retries once with the plain
  `vm-start <vm>`, logs a notice and adds a note. The guest starts with no
  stop-order record until the node's image is updated. Other failures are not
  retried.
- tests: `t/209-workload-stop-order.t`.

## Node script runs may take longer than a minute (2026-11-12)

- fix: the dispatcher waited 60 s (ctrl-exec's default `read_timeout`) for a
  node agent's reply, so `vm-image-write` of a 4G probe disk on s1 failed with
  "read timeout after 60s" while the write went on. IPS bring-up now appends
  `read_timeout = 900` (`CTRL_EXEC_AGENT_READ_TIMEOUT`) to ctrl-exec.conf once;
  a value already there is kept.
- tests: `test_p2_62_api_bring_up.bats`.
- fix: `hps-run.sh --json/--input` calls ctrl-exec-cli, whose own wait for the
  API is 120 s by default; s1's image writes finished one second after it gave
  up. hps-run now sets `CTRL_EXEC_TIMEOUT` to `CE_RUN_TIMEOUT` (900) unless
  the caller set it (an environment variable, so an older client is not
  broken by an unknown option). Test: `test_p2_64_hps_run_api_defaults.bats`.
- fix: `hps-workload destroy` passes `vm-stop <vm> --force`: a guest that does
  not shut down within the graceful wait is forced off instead of blocking the
  destroy (s1's probe-tch-003). `stop` still never forces. Test:
  `t/71-workload-driver.t`.

## repo update orders pre-release tags correctly (2026-11-12)

- fix: repo update's newest-release check ranked every pre-release kind the
  same and compared only the number, so om3 `v3.0.0-alpha111` was reported as
  NEWER than the pinned `v3.0.0-rc62`. Within one version the order is now
  alpha < beta < rc < final, then the number.
- tests: `test_p3_204_repo_scripts.bats` (alpha and beta tags among the rcs).

## om3 v3.0.0-rc62 (2026-11-12)

- change: om3 follows the newest release tag (ruling 2026-11-09): v3.0.0-rc62
  (e29c763) replaces rc60. The vendorHash is unchanged; the Go module set is
  the same.

## flake.lock committed: builds are reproducible from the repository (2026-11-12)

- new: `flake.lock`. nixpkgs is locked at `ac588ef1c914` (2026-11-08), the
  revision every pin so far was built from. om3-src is at v3.0.0-rc60
  (`4ff6def`), ctrl-exec-plugins at v0.3.11 (`b30aafe`), and ctrl-exec at
  github main `3d307e6` (the lab builds with its local checkout through
  `CTRL_EXEC_FLAKE`). A build from the site repository with no upstream no
  longer depends on whatever revision a fetcher cache resolved `nixos-26.05`
  to.
- change: `nix/build.sh` always passes `--no-write-lock-file`, so a build never
  rewrites the committed lock, even with an `--override-input`.
- tests: `test_p1_40_build_sh.bats`.

## Site repository, stage 1: on the builder's disk, signed (2026-11-12)

- new: the site repository (docs/REPOSITORY.md, plans/ips-repository.md),
  for now the builder's disk: a signed Nix binary cache in
  `/var/lib/hps-builder/repo/nix-cache` (zstd), served read-only on port 8091
  by `hps-repo-http` with its public key `repo.pub`; pins stay in `out/` on
  8090. The signing key is made on the node at first use and stays in
  `/var/lib/hps-builder/keys` (never served).
- new: node scripts `repo-seed <ips|url> <paths-sha256>` (import a binary
  cache: NARs checked against their narinfo hashes on import, re-hashed with
  `nix store verify --no-trust`, then signed; `--no-check-sigs` for this
  import only), `repo-update <source-sha256>` (through the egress proxy:
  substitute what the builds would fetch, build only the fixed-output inputs,
  name the hosts of a failed fetch, report pinned inputs with a newer release
  tag) and `repo-status` (key, cache counts, the packages HPS built with their
  signature, pins, last job, newer inputs).
- changed: `builder-build` builds from the repository and the local store
  alone, with no proxy, unless `--upstream`; whatever the build fetched or
  produced is signed into the repository, after a failed build too.
  `hps-builder-run` takes `--mode build|update|seed`; `nix/build.sh` appends
  `BUILD_CACHE_PARAMS` to its cache URL.
- new: IPS tool and ips-admin script `hps-repo status|seed|update|build`
  (`HPS::Repo`), on the host of the cluster key `repo_host` (refused when
  unset); status stores the repository key as `repo_nix_pubkey` when empty
  and refuses a different one; `repo_upstream` (default false) lets repo build
  use upstream.

## Image builder on a cluster node; published files proved on disk (2026-11-12)

- new: Nix profile `node-builder` (`nix/modules/profiles/builder.nix`, role
  `BLD`), booted for host profile `BUILDER`; built by default by
  `nix/build.sh`. The node base without om3; a build store of its own on a
  local disk (`/var/lib/hps-builder/root/nix`, used in a private mount
  namespace with the disk store at `/nix`); `hps-builder-http` (darkhttpd,
  read-only, port 8090) serves its outputs. docs/BUILDER.md.
- new: node scripts `builder-disk-prepare <device>` (ext4 labelled
  `hps-builder`, blank devices only, never reformats), `builder-build
  <source-sha256> [--profiles] [--input NAME=SHA256]` (fetches and checks the
  source tarball from the IPS, starts the transient unit `hps-builder-build`
  running `hps-builder-run`) and `builder-status`; boot unit
  `hps-builder-mount`.
- new: cluster key `egress_proxy` (`http://<host>:<port>`) becomes `hps.proxy=`
  on the `node-builder` command line only; the builder's one way out.
- new: role type `BLD` (`hps-onboard assign --type BLD`, OS seed
  `hps_types`).
- new: `hps-cnh-publish --source-only` writes the hps-system tarball alone and
  prints `SOURCE <sha256> <url>`; `hps-pin-fetch --from <builder> --pin <pin>
  [--latest]` (`HPS::PinFetch`) pulls a pin from a builder, checks that
  SHA256SUMS, boot.json and ipxe.json agree, reads every file back with
  O_DIRECT until it gives the listed hash, proves it again in place and
  requires `hps-pins verify`; a pin that never proves is moved aside, never
  published.
- changed: `nix/build.sh` reads every store original and every published copy
  with O_DIRECT, writes a copy again when they differ (3 tries), and records
  that proved hash in boot.json, ipxe.json and SHA256SUMS instead of hashing
  the copy once more (IPS-33 #3, #3b; the first build with it, 2026-11-12,
  re-copied an initrd whose first copy gave an I/O error on read-back).

## VXLAN workload networks over the transit VLAN (2026-11-12)

- new: layout kind `vxlan`, `{"kind": "vxlan", "vni": 1-16777215, "over":
  "<purpose-transit network>", "bridge": "br-...", "purpose": "workload",
  "mtu"?: 576-8950}`; VNIs unique, no `cidr`, `vlan`, `nic` or `uplink`;
  MTU by default the transit MTU less 50 (8950). VXLAN is the default for
  virtual networks between client hosts, on the cluster's transit VLAN (owner
  ruling 2026-11-10, `plans/networking.md`).
- new: node script `net-vxlan-ensure <vni> <bridge> --local <ip> [--peer
  <ip>]... --mtu <N>`, allowlisted on every node image. It builds
  `vxlan<vni>` (`local`, `dstport 4789`, `nolearning`) in the bridge, one
  all-zero MAC FDB entry per peer, the MTUs, links up; idempotent, a changed
  peer list replaces the entries exactly; refuses when the local address is
  not on the host or the transit link's MTU is too small.
- new: `HPS::Vxlan`: transit hosts (TYPE TCH, NixOS) at their transit address
  (the host-address rule of `net-up`), the peers of a host (every other one)
  and the node call.
- new: `hps-node net-up` on a TCH builds every vxlan network after the transit
  address and refreshes the other TCHs' peer lists (`refresh` lines; a failed
  refresh is reported and does not change the exit status). It runs after
  every pairing, so the networks survive reboots and follow TCHs joining.
- new: `hps-workload create` and `start` run `net-vxlan-ensure` on the compute
  host for each vxlan net of a VM (before `vm-define` / the VM's start steps);
  a compute host that is not a transit host refuses the plan.
- change: `net-bridge-ensure` lists and skips vxlan networks.
- docs: `docs/CLUSTER-CONFIG.md` (the kind, the script, net-up),
  `docs/WORKLOADS.md` (a VM on a vxlan network).
- tests: `t/202-vxlan.t`, `test_p3_201_net_vxlan_ensure.bats`, a vxlan case in
  `test_p3_166_fabric_bridge.bats`.

## Zvols and workload definitions through the operator API (2026-11-11)

- new: `ips-admin-exec` passes a `/` for `hps-storage` in exactly the dataset
  forms `hps-storage` validates (`<pool>/enc`, `<pool>/enc/<name>`,
  `<pool>/enc/vm/<name>`; `^[a-z][a-z0-9_.-]*/enc(/(vm/)?[A-Za-z0-9_-]+)?$`,
  `HPS::Storage` `$DS_RE`), so an operator can `zvol-create`, `export`,
  `unexport` and `zvol-destroy` through the operator API. No `..`, no leading
  `/`, no other slash; every other refusal unchanged, and no other tool takes
  a dataset.
- new: `hps-workload define <name> [--replace] [--dry-run] [--json]` writes
  `workloads/<name>.json` from the JSON on stdin, checked by the same code
  `create` loads a definition with; refuses an existing definition without
  `--replace` and `--replace` while the workload exists; temp file and rename,
  mode 0664 and the directory's group (a replaced file keeps its own).
  `hps-workload show-definition <name>` prints the stored JSON.
- new: ips-admin script `hps-workload-define` (`input=raw`), mapped to
  `hps-workload define <name>` like `hps-cluster-config-apply`; one name and
  only `--dry-run`, `--replace`, `--json`. In `IPS_ADMIN_SCRIPTS` and
  `IPS_ADMIN_RAW_SCRIPTS`, so the agent's `scripts.conf` and the auth hook's
  `hps-operator.conf` list it.
- docs: `docs/OPERATOR.md` (dataset arguments; defining and creating a
  two-leg workload through `hps-op`), `docs/WORKLOADS.md` (define,
  show-definition).
- tests: `t/200-workload-define.t`,
  `test_p3_200_ips_admin_datasets_and_define.bats`; script counts in
  `test_p3_190`, `test_p3_192`.

## Workload start after a compute host reboot (2026-11-11)

- fix: `hps-workload start` brings a workload back after its compute host
  rebooted. The node runs from RAM, so libvirt's VM definitions were gone and
  `start` failed (`vm-start exited 4: ... is not defined`) with no way out
  (`create --resume` had nothing to resume). `start` now runs `vm-status`
  before each `vm-start`; a VM that is not defined is re-defined with
  `vm-define`, built by create's own argument builder from the definition and
  the record, with the recorded MACs (`--mac` per NIC), the same disks and
  legs, NIC VLAN settings and SMBIOS, and no zvol create or image write. A
  definition edited since create refuses the re-define (3) and names the
  difference. The re-define is a plan step, listed in `--dry-run`.
- new: the workload record keeps each VM's `vm-define` arguments (`define`)
  from create, and the MACs of a `boot: disk` VM (`macs`, read with
  `vm-status`), so later re-defines keep the VM's identity.
- tests: `t/201-workload-start-redefine.t`; start call lists in
  `t/71-workload-driver.t`, `t/72-hps-workload-cli.t`,
  `t/76-workload-network-boot.t` include the `vm-status` step.

## Host addresses on storage and transit VLANs (2026-11-11)

- new: NixOS nodes get an address on each storage network and, for TCH hosts,
  on the transit network (scale test phase 2: until now only the boot NIC had
  one, so an SCH could not export iSCSI on its storage VLANs and TCHs could not
  reach each other on transit). Address rule, no new state: the host part of
  the provisioning address inside the target subnet, modulo its size
  (`HPS::ClusterConfig::vlan_host_address`); network, broadcast and gateway
  refused. s1: sch-001 10.11.0.153 gets 10.113.0.153 (storage A, VLAN 113),
  10.113.1.153 (storage B, VLAN 114) and, as a TCH, 10.11.2.153 (transit,
  VLAN 112).
- new: node script `net-vlan-address <parent-iface|boot> <vlan> <ip>/<prefix>
  [--mtu N]`, allowlisted on every node image (`hps-ctrl-exec.nix`). It makes
  `<nic>.<vlan>` and gives it the address and MTU through a systemd-networkd
  `.network` file (`05-hps-vlan-<link>.network`, ahead of hps-net's MAC
  match), raises the parent's MTU when lower, and is idempotent.
- new: `hps-node net-up <host> [--dry-run] [--json] [--wait SECONDS]`, one
  `net-vlan-address` call per network; also open to operators through the
  `hps-node` ips-admin script. New job kind `net-up <mac>`, queued by the API
  after every pairing of a NixOS SCH or TCH host, before `storage-up`, so a
  rebooted node gets its addresses back on its own.
- tests: `t/198-vlan-host-address.t`, `t/199-net-up.t`, `t/45-jobs.t`,
  `test_p3_198_net_vlan_address.bats`, `test_p3_199_net_up_hook.bats`.

## om3 membership through the operator API (2026-11-12)

- new: `hps-osvc status <host>` runs the read-only node script `osvc-status`
  and passes its output and exit through (0 healthy, 2 a peer stale, 1 om not
  answering). `hps-osvc` is an ips-admin tool, so an operator can now check a
  cluster's om3 membership through its own operator API. Before, only the IPS
  itself could run `osvc-status`.
- tests: `t/90-hps-osvc.t`.

## A thin compute host caches workload images in RAM (2026-11-12)

- fix: a VM whose legs are all remote, on a compute host with no pool of its
  own (a thin TCH), failed its first create step: "cannot create
  's1/enc/images': no such pool 's1'". Such a host now caches the base image in
  `/run/hps/images`, which `image-fetch` may create (mode 0700). Any other
  missing `--dest` is still refused. A host with a pool keeps
  `/<pool>/enc/images`.
- tests: `t/71-workload-driver.t`, `test_p3_22_image_fetch.bats`.

## Images and ctrl-exec-cli reach an inner IPS (2026-11-12)

- new: `hps-cnh-publish --image NAME` adds a catalogue image
  (`images/NAME.qcow2` and `NAME.sha256`) to the container host manifest, and
  `cnh-ips-bootstrap` accepts `srv/hps-resources/images/` paths. An inner IPS
  can then run disk-boot workloads (the scale test's probes). A symlinked or
  missing image is refused.
- change: the manifest's default packages are the ctrl-exec tarball and the
  ctrl-exec API plugins package (`ctrl-exec-cli`). `hps-run` sends every node
  call through that CLI, so an inner IPS without it ran no node script at all
  (IPS-31 #1).
- tests: `t/171-cnh-publish.t`, `test_p3_174_cnh_ips_bootstrap.bats`.

## Storage networks on any VLAN (2026-11-11)

- change: `network_storage_base_vlan` takes 2 to 4094 (was 31 to 99), in
  `hps-cluster-config`, the interactive menu and `050-set-storage-network.sh`.
  31 stays the default and the conventional range. A per-cluster VLAN plan,
  such as the scale test's storage A and B on 113 and 114, no longer has to
  fit under 100. A base VLAN above 255 has no `10.<vlan>` default subnet base,
  so `network_storage_subnet_base` must be given; it is an error, where it used
  to derive nothing without a word.
- tests: `t/81-cluster-config-validate.t`.

## workload-destroy is no longer a job kind (2026-11-11)

- removed: `workload-destroy` from the root job queue (`HPS::Jobs` and
  `hps_job_validate`). It was the one destructive kind that anything able to
  write the queue (group `hps`, the web user) could request, and the signed
  approval that guarded it is gone. Owner ruling 2026-11-11. Destroy runs
  only as `hps-workload destroy`: root on the IPS, or an operator through the
  operator API. ADR 0007, SECURITY.md and WORKLOADS.md updated.
- tests: `t/73-jobs-workload-kinds.t`, `t/45-jobs.t`,
  `test_p3_50_workload_jobs.bats`,
  `test_p3_96a_workload_destroy_keeps_definition.bats`.

## Authorisation is ctrl-exec's: signed approvals removed (2026-11-11)

- removed: HPS's own signed-approval layer (owner ruling 2026-11-11: "the
  approval isnt required in the lab. for any real use, ctrl-exec will control
  who does what"). ctrl-exec's script allowlists and the operator API's auth
  hook now decide who runs what (ADR 0007).
- removed: `bin/hps-approve` and `HPS::Approval`; the cluster `approval`
  secret (`keysafe/approval.hmac`); the approval checks of `hps-storage`
  create, destroy and zvol-destroy, `hps-workload destroy` and `hps-onboard
  forget`; the registry key `approval_<action>_<pool>` and `approved_by` in
  `workload_<name>_destroyed`.
- removed: the node-side HMAC verification (`--approval-file -`) of
  `storage-pool-create`, `storage-pool-destroy`, `storage-zvol-destroy` and
  `mirror-create`, and `mirror-assemble --declaration-file -`. The last four
  are no longer `input = raw`; `openssl` left the storage profile.
- changed: what the approval carried is now an argument. `hps-storage <host>
  create <pool> --disk <by-id> --disk <by-id> [--disk <by-id>]... [--wipe]`
  (2 to 4 disks, validated as before); `storage-pool-create ... [--wipe]`
  reads only `{"key_hex"}`; `mirror-create ... [--wipe]`; `mirror-assemble ...
  [--peer-gone]` for a degraded assembly. A pool still goes on an assigned host
  only; every disk, in-use and pool-name refusal stays.
- new: pools, zvols, workloads and host forgets run through an inner IPS's
  operator API (`hps-op ... hps-storage ...`; `docs/OPERATOR.md`).
- docs: ADR 0007; ADR 0005 and 0006 amended; `docs/SECURITY.md`,
  `docs/WORKLOADS.md`, `docs/VM-LIFECYCLE.md`, `docs/NAMING.md`,
  `docs/REGISTRY-KEYS.md`.
- tests: `t/31-approval.t`, `t/32-hps-approve.t`, `t/50-zvol-approval.t`,
  `t/61-approval-peer-gone.t`, `t/74-approval-workload-destroy.t` and the
  `t/fixtures/approval-*` files removed; the storage, workload, forget and
  node-script tests now prove each operation runs with no approval, the
  `--disk`/`--wipe`/`--peer-gone` arguments are validated, and the
  data-protecting refusals still fire.

## prune-agents keeps the IPS's own agent (2026-11-11)

- fix: `hps-onboard prune-agents` removed every agent with no registry host,
  including the IPS's own `ips.<domain>` (ips-admin). Every lab chain run cut
  the operator API off: "unknown agent: not a registered agent: ips.lab.hps",
  found by the cluster browser. Run through an inner IPS's operator API, it
  would have locked the operator out of that cluster. The IPS's own agent is
  now always kept; an `ips.` agent of another domain is still stale.
- tests: `t/95-hostname-forget.t`.

## An IPS with no builder gets a latest pin (2026-11-11)

- new: `hps-pins latest <pin>` points `nixos/latest` at a pin on disk that
  verifies. It refuses a pin that does not verify and leaves latest unchanged,
  and writes through a temporary file and a rename. A cluster's inner IPS gets
  its pins from `cnh-ips-bootstrap` but has no builder to write latest. With
  no latest and no cluster default it has no pin to audit or boot from. Seen
  in the scale test: s1's six nodes were held with no audit.
- docs: `docs/CONTAINER-HOST.md` bring-up step 9.
- tests: `t/94-pins.t`.

## The IPS no longer installs OpenSVC (2026-11-11)

- removed: `ensure_opensvc_installed` and `ips_install_opensvc`, the IPS-side
  OpenSVC install path (owner ruling 2026-11-11). No OpenSVC package exists
  to publish: om3 is built in the flake and runs on the nodes. With no `om`
  on the IPS, `osvc_prepare_cluster` logs that there is nothing to prepare
  and returns 0. With `om` present it prepares as before.
- tests: `test_p3_183_opensvc_offline_install.bats`, rewritten. The function
  reference pages for the two functions are removed.

## The IPS never reaches the internet for OpenSVC (2026-11-11)

- fix (IPS-30): `ips_install_opensvc` installs only a package published in
  the IPS's own repository (`packages/opensvc/*.deb`), with `dpkg -i`, and
  never calls `apt-get`. Its old check, `test -s $OSVC_DEB` unquoted, was true
  with no package, so every IPS start ran `apt-get update` against
  deb.debian.org (seen from the s1 IPS in the scale test). With no package
  the IPS warns and starts without OpenSVC, as before. Owner ruling
  2026-11-11: a cluster that needs packages gets them from the IPS repository
  or through a router VM.
- tests: `test_p3_183_opensvc_offline_install.bats`.

## An inner IPS's first operator credential, from its CNH (2026-11-11)

- new: CNH node script `cnh-ips-operator-init <address>:7445 <label>`. In the
  running `hps-ips` container it sets `operator_api_listen`, brings the
  operator API up on that address and issues the first operator credential
  (`hps-operator issue <label>`). The address must be on a non-loopback
  interface of the CNH (the container shares its network); the port is the
  IPS's fixed 7445. Refused (3): the container not running, a label that
  already holds a credential (checked before anything changes; revoke it
  first with `hps-operator revoke <label>`), the IPS not taking the address.
- The credential is the run's stdout and goes nowhere else: the script is
  allowlisted on the CNH image with `output=confidential`, so ctrl-exec
  returns it only in the synchronous response, never stores it, and refuses
  an async run. The last line, `OPERATOR-INIT done label=<label>
  url=https://<address>:7445`, carries no token.
- new: `bin/hps-operator-api-apply` (`ce_operator_api_apply`) applies
  `operator_api_listen` without an IPS restart: `ce_api_bring_up`, a check
  that it left `api_bind` on the address, then `supervisorctl restart
  ctrl-exec-api`. The rest of the IPS keeps running.
- tests: `test_p3_182_cnh_ips_operator_init.bats`; `test_p3_175_cnh_wiring.bats`
  covers the new script. Docs: `docs/CONTAINER-HOST.md` (step 8),
  `docs/OPERATOR.md`.

## Container host boots without an ordering cycle (2026-11-11)

- fix: `hps-cnh-mount` is no longer ordered before `podman.socket`. Sockets
  start before `basic.target`, which the mount unit follows, so systemd broke
  a cycle at boot (lab, scale test phase 2). It still runs before
  `podman.service` and `hps-ips.service`.
- tests: `test_p3_175_cnh_wiring.bats` (cycle regression); the usage-checks
  test is renumbered to 181 (172 was taken twice).
- fix: `cnh-disk-prepare` refused on every CNH: podman's tmpfiles rule makes
  `/var/lib/containers/storage/tmp` at boot, and the "already holds files"
  check counted that empty directory. Only non-directories count now, and the
  mount-point refusals run before any format, so a refused run writes nothing
  (it used to format, then refuse). Tests: `test_p3_171_cnh_disk_prepare.bats`.

## Audits start only when there is room for them (2026-11-11)

- new (IPS-16): cluster keys `audit_max_concurrent` (default 2, 0 = no limit)
  and `audit_timeout_seconds` (default 900) cap the audit images the IPS
  serves at once. A held host that needs an audit is admitted when fewer than
  the limit are auditing and no earlier-seen waiting host is ahead of it;
  otherwise it gets the hold script saying `waiting for an audit slot (<n>
  running, retry in <s> s)` and asks again every `hold_retry_seconds`. A host
  counts as auditing from the moment it is served the audit image (host key
  `audit_started_at`) until its audit is stored or the timeout passes.
  Assigned hosts are never limited: a role boot is served at once. Admissions
  are logged at info. Load-aware admission (step 4 of the filing) is not done.
- tests: `test_p3_179_audit_admission.bats`; rules in `docs/IPXE.md`.

## A ZFS hostid per node (2026-11-11)

- changed: every node had the image-wide ZFS hostid `48505331`, so with
  several storage nodes a pool looked owned by every one of them (ZFS uses the
  hostid to tell which host imported a pool, and for multihost protection).
  The IPS now passes `spl.spl_hostid=0x<id>` on the kernel command line of
  every NixOS boot, audit image included. The id is the first 8 hex digits of
  the sha256 of the host key MAC (12 lower-case hex digits), so it is stable
  across reboots, needs no storage, and a boot from another port of the same
  machine (IPS-15) gets the same id. spl takes a non-zero `spl_hostid` in
  preference to `/etc/hostid`, in the kernel and in `zpool import`; the
  image's fixed `networking.hostId` stays only to satisfy the NixOS build and
  as the fallback for a boot without the parameter.
- new: host key `zfs_hostid` (8 hex digits) records the id the IPS handed out
  (catalogued in `docs/REGISTRY-KEYS.md`).
- tests: `test_p3_178_zfs_hostid.bats`.

## ctrl-exec 0.14.7 for ips-admin (2026-11-11)

Requires ctrl-exec >= 0.14.7 (R-036 delivered). Bring-up reads
`ctrl-exec-dispatcher --version`; an older or unreadable version logs an error
naming the requirement and the operator API stays off.

- changed: the IPS's own agent writes `bind = 127.0.0.1` (with `allowed_ips`
  kept as defence in depth).
- changed: the auth hook decides CLI or API from `ENVEXEC_CALLER`, and requires
  an operator call to arrive on `ENVEXEC_LISTENER=tls`, in place of the
  parent-process check. Without `ENVEXEC_CALLER` (an older dispatcher) it
  refuses operators and keeps HPS's own callers (unix socket root, `ced`).
- new: cluster key `ips_admin_read_timeout` (60..3600 s, default 900) is set as
  the IPS agent's own read timeout at pairing and at every start, so long
  ips-admin jobs return their output; node agents keep the global default.
- changed: the dispatcher config the IPS writes has `api_forward_token = no`,
  so the operator's token never reaches an agent.

## Audit image: firmware as its own initrd layer (2026-11-11)

- The audit image no longer carries linux-firmware in its store
  (`hardware.firmware` forced to `[ ]`). Before this change,
  `enableAllHardware` also merged in the sound, TV-tuner and Wi-Fi firmware
  that IPS-03 was meant to drop. A normal audit build therefore no longer
  repacks about 825 MiB of firmware.
- new: `nix/pkgs/hps-firmware-layer.nix` (flake package `firmware-layer`). It
  is a cpio holding `/firmware.squashfs` (linux-firmware, zstd 6), published
  once per content as `nixos/firmware/<hash>-<name>.cpio` and shared by every
  pin. The audit `boot.json` names it in `extra_initrds` (sha256, size), and
  `SHA256SUMS` lists it as `../firmware/<file>`.
- The IPS emits one `initrd` line per `extra_initrds` entry, after the image's
  own. Pins without the key boot unchanged, and a missing or malformed layer
  refuses the boot. The audit initrd mounts the layer at `/run/hps-firmware`
  before udev, and `firmware_class.path` points at it.
- `hps-pins verify`, `prune` and `delete` cover layers: a layer is kept while
  a remaining pin names it, plus one hour of grace. `nixos-prune-pins.sh`
  skips `firmware/`, and `hps-cnh-publish` ships the layers with their pins.
- docs: `docs/IPXE.md` (Firmware layer). tests: `test_p3_197`,
  `t/197-firmware-layer.t`, `test_p3_92` updated.

## Storage pools: a mirror of two to four disks (2026-11-11)

- `storage-pool-create` takes 2 to 4 `--disk` by-id names and builds one
  mirror of them all (a three-way mirror survives two disk losses; owner
  ruling for the scale test's storage nodes). A disk given twice is refused.
  The approval document already lists the disks it was issued for.

## Operator access: every IPS manages itself (ips-admin, 2026-11-11)

- new: the IPS runs its own ctrl-exec agent, `ips.<cluster domain>`
  (`program:ctrl-exec-agent`, root, port 7446, 127.0.0.1 only), installed from
  the dispatcher tarball (`install.sh --agent`), state under
  `/srv/ctrl-exec/agent-{conf,state}`, and paired with the IPS's own
  dispatcher at IPS start by the IPS itself: verified pairing against its own
  CA, and only a request named `ips.<domain>` from 127.0.0.1 is approved
  (`ce_ips_agent_bring_up`, `lib/functions.d/ips-admin-functions.sh`; owner
  rulings 2026-11-11, "inside cluster should be fractal of outside").
- new: the `ips-admin` allowlist (`ips-admin/`, profile `ips-admin`):
  `hps-onboard`, `hps-cluster-config`, `hps-cluster-config-apply` (input),
  `hps-bmc` (status, list, set, select), `hps-bmc-credential` (confidential
  input), `hps-node`, `hps-storage`, `hps-workload`, `hps-pins`,
  `hps-ips-check`, `hps-osvc`, `hps-monitor` (run), `ips-syslog-forward`.
  Arguments pass through as plain tokens only; every call is logged
  (tag `ips-admin`).
- new: remote operators through the IPS's own ctrl-exec API. Cluster key
  `operator_api_listen` (default empty: no listener) turns on the API's TLS
  listener on that address, port 7445, with a self-signed certificate for the
  IP. `bin/hps-operator issue|list|revoke|export|ca` manages operator
  credentials (random tokens, SHA-256 in the keysafe, shown once). The auth
  hook lets a credential run only `ips-admin` scripts on `ips.<domain>`, logs
  each run, and tells `ced` from an API caller by its parent process; HPS's
  own callers are unchanged.
- new: `bin/hps-op`, the operator client (any machine with this tree and
  `ctrl-exec-cli`): `hps-op --cred FILE [--input] <tool> [args...]`.
- new: optional syslog forward to a collector, `ips-syslog-forward <ipv4>
  <prefix>|off|show` (`bin/hps-syslog-forward`), kept in the cluster keys
  `syslog_forward_host` / `syslog_forward_prefix` and written by the rsyslog
  generator; the product form of `lab/syslog-lab.pl --upstream`.
- `HPS::Keysafe::list_secrets`; rsyslog files `ctrl-exec-agent` and
  `ips-admin` under `ips/<program>/`.
- docs: `docs/OPERATOR.md`; `docs/SECURITY.md` (trust boundary 5, hardening
  items); `docs/CLUSTER-CONFIG.md`, `docs/REGISTRY-KEYS.md`.
- tests: `test_p3_190`..`194` (wrappers, auth hook, agent bring-up, operator
  API listener, syslog forward), `t/190-operator.t`, `t/191-hps-op.t`.

## Usage checks in node monitoring (2026-11-11)

- new: five usage checks collect trend and baseline data (owner request,
  2026-11-11), logged by `hps-monitor` like the others: `cpu` (CPU time by
  state), `net` (traffic and error/drop counters per interface), `diskio`
  (throughput, IOPS, busy per whole disk; "no disks" is OK on a RAM node) on
  every node; `zpool_io` (pool I/O, allocated and free bytes) on storage nodes;
  `vms` (CPU, memory, disk and network per running guest) on compute nodes.
  Plugins `check_cpu`, `check_net`, `check_diskio`, `check_zpool_io`,
  `check_vms` in `node-manager/nixos-26/plugins/`; each samples twice, one
  second apart (`-i`, 1 to 5), and reports rates as perfdata with the label
  suffixes `_Bps`, `_pps`, `_iops`. They are usage, not alarms: OK unless the
  source cannot be read (`check_cpu` has optional `-w`/`-c`).
- `hps-monitor.nix` installs them, gives each its tools and `isCompute`
  selects the guest check like `isStorage` the pool one. `docs/MONITORING.md`
  has the label scheme and the time budget (about 5 s more per node run).
- tests: `test_p3_181_usage_checks.bats`.

## Several disks per workload VM (2026-11-11)

- new: a workload VM may have 1 to 8 disks (`MAX_DISKS` 8 in `HPS::Workload`).
  Every disk gets its zvol (and mirror when it has two legs) and the driver
  passes one `--disk` per disk to `vm-define`, in definition order.
- new: `vm-define --disk` is repeatable (1..8, each path once): targets `vda`,
  `vdb`, ... (virtio) or `sda`, `sdb`, ... (scsi, sata); with `--boot network`
  the NIC boots first, then disk 1. `--image` and `vm-image-write` concern the
  first disk only. A single-disk domain renders byte-identically to before, so
  its spec hash is unchanged.
- new: every `vm-define` disk carries a `<serial>` `<vm>-d<N>` (last 20
  characters when longer) so guests can use `/dev/disk/by-id`. This changes the
  rendered XML and spec hash of existing single-disk domains; a redefine of one
  needs `--replace`.
- tests: `test_p3_170_multi_disk.bats`, `t/77-workload-multi-disk.t`. Needed by
  the scale test (storage VMs with 3 data disks, `lab/scale`).

## CS-3.11: the container host role (2026-11-11)

- new: role `CNH`, host profile `CONTAINER_HOST`, image profile `node-cnh`
  (`nix/modules/profiles/container-host.nix`, built by `nix/build.sh` by
  default): the node base, om3, root podman with netavark; no libvirt, no LIO,
  no pool. Not yet evaluated by `nix flake check`.
- new: node scripts on the CNH image only: `cnh-disk-prepare` (ext4 `hps-cnh`
  on a blank device only, mounted at `/var/lib/containers` and
  `/var/lib/hps-ips`), `cnh-image-load` (archive from this node's IPS only,
  verified, `podman load`), `cnh-ips-bootstrap` (IPS state by manifest, every
  file verified, resumable), `cnh-ips-cluster-bootstrap`, `cnh-ips-run`,
  `cnh-ips-stop`; boot units `hps-cnh-mount` (never formats) and `hps-ips` (the
  IPS container, host networking, the lab IPS shape).
- new: IPS tool `hps-cnh-publish` (`HPS::CnhPublish`): the hps-system tarball and
  the `hps-cnh-manifest/1` manifest under `hps-resources/packages/cnh/`.
- `hps-onboard`, the NixOS OS seed and `hps.roles` take `CNH`.
  `docs/CONTAINER-HOST.md`.

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

## IPS-01 to IPS-12: IPS hardening (2026-11-10 to 2026-11-11)

IPS-07 and IPS-08 have their own spans above.

- IPS-01 (`79c2f69`, `9a97cb0`): added `hps-ips-check`, a read-only self-check run
  after every IPS start, one syslog line per check.
- IPS-02 (`f227180`): added: `n_init_run` reports each step's result (rc, seconds,
  own stderr tail) to the IPS (`cmd=host_init_result`); host keys `init_result`,
  `init_result_prev`, `init_ok`; `hps-onboard show` Init section and `list --all`;
  failed init steps log at `err`. Fixed: `n_remote_host_variable` and
  `n_remote_cluster_variable` reported the stale error of an earlier call.
- IPS-03 (`d35c912`): changed: the audit image carries `linux-firmware` and no
  other firmware.
- IPS-04 (`c01afb9`): added: graceful shutdown that the node honours, storage first.
- IPS-05 (`bc3d50a`): added: pin integrity and retention (`hps-pins`, content
  hashes in `boot.json`, verify before pin); job kind `pins-prune`.
- IPS-06 (`f19100b`): changed: one hostname rule, the FQDN everywhere; added
  `hps-onboard forget` and stale agent pruning. See `docs/NAMING.md`.
- IPS-09 (`87a844b`, `0d43454`): changed: a pinned, current iPXE is built in the
  flake and served by the IPS.
- IPS-10 (`234d670`, `2d17752`): changed: `dns_hosts` is generated from the
  registry through one `dns_regenerate` entry point; the storage allocator uses it.
- IPS-11 (`3edea8e`, `7884acb`): fixed: normal boots no longer log errors; the
  kernel hostname is the transient name only.
- IPS-12 (`29db772`): added: one om3 cluster CA, held by the IPS keysafe and
  delivered to the nodes. Needs ctrl-exec 0.14.6 (confidential input over 16 KB).
  `2efa9d6`: `osvc-status` reads the rc60 heartbeat path.

## Phase 3: compute, workloads and OpenSVC (2026-11-09 to 2026-11-10)

- CS-3.1 to CS-3.3 (`2f7ac06`, `d3f24c0`, `7e20c23`, `2f24f46`): added: the
  compute profile with libvirt guests, network layout keys and bridges; legs and
  md mirrors (`mirror-create`, `-assemble`, `-status`, `-rejoin`, `-stop`,
  `-detach-leg`); VM lifecycle node scripts, `image-fetch`, and
  `vm-confinement-report`. See `docs/CONFINEMENT.md`.
- CS-3.4a (`d89189c`, `0416780`, `9defece`): added: a per-guest AppArmor profile
  layer for libvirt guests; confirmed on a lab node.
- CS-3.5 (`3970ca8`, `4123bdb`): added: OpenSVC (om3) in the flake and on the
  nodes, and `osvc-status`. See `docs/OPENSVC.md`.
- CS-3.6 (`c17a73d`, `366abb4`, `50c3e48`): added: `HPS::Workload` and
  `bin/hps-workload` (definition, driver, job kinds `workload-create`,
  `-start`, `-stop`, `-destroy`, `-status`); guest zvols under `<pool>/enc/vm`.
- CS-3.9 (`78b051b`, `a18b7c0`): added: `hps-cluster-config`, declarative
  cluster configuration; `commit_changes` routes through `hps-cluster-config apply`.
- CS-3.12a (`a70a6c9`): added: a nested HPS node on the lab segment.
- tooling (`022b0e2`, `6a6c416`): `hps-run --json` and one JSON runner; parallel
  bats.

## Phase 2: storage and the privileged IPS (2026-11-09)

- CS-2.0a (`28381b3`): changed: lighttpd (mod_cgi) replaces nginx, spawn-fcgi and
  fcgiwrap on the IPS; removed: the nginx config generator and the nginx and
  fcgiwrap supervisor programs. See `docs/adr/0004-lighttpd.md`.
- CS-2.0b, CS-2.0d (`3ad1129`, `ebd69dd`): static allocations from a declared
  pool, repin and pin housekeeping; one group (`hps`) owns the IPS state.
- CS-2.1 to CS-2.3 (`46fe53e`, `841474a`, `a9887d9`): added: node storage scripts
  and the storage profile; `HPS::Keysafe` with HMAC approvals (the Bash keysafe
  is retired); `HPS::Storage` and `bin/hps-storage`.
- CS-2.4, CS-2.5 (`c3704e9`, `660ddb8`, `d62d5c9`): added: privileged IPS actions
  run by the root job runner `hps-jobs`; `ctrl-exec-api` for script input with
  the HPS auth hook; zvol lifecycle scripts and an iSCSI test from the IPS.
  See `docs/adr/0006-ips-privilege-split.md`.

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

## 25f4602–94eef2e — Registry refactor and bootstrap (2026-07-08 migration)

Migration of the November–December 2025 refactor developed on the deployed
instance into the repository.

- ctrl-exec (`23237fa`, `bdfa0bb`, `7220e52`, `4c312ae`, `c42515a`) — added:
  ctrl-exec (mTLS remote execution) as the node setup/exec mechanism, with
  registry-bound automatic enrolment, the `hps-node` agent plugin, node-side
  agent delivery and IPS dispatcher bring-up; removed: the MAC-trust `osvc_cmd`
  CGI join path and the OpenSVC task exec bus; changed: VM creation runs over
  ctrl-exec with OpenSVC kept only as the health gate. See `docs/adr/0001..0003`.
- dedup (`95f2406`) — changed: the duplicated `host_config` / `cluster_config`
  compatibility aliases have a single definition.
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
