# ADR 0007 — Authorisation is ctrl-exec's; HPS keeps no signed approvals

- Status: accepted
- Date: 2026-11-11
- Tags: security, ctrl-exec, storage, workloads, operator
- Amends: ADR 0005 (storage role driver), ADR 0006 (IPS privilege split)

## Context

Since ADR 0005 HPS carried its own approval layer for destructive actions. A
human ran `hps-approve <action> <mac> ...` on the IPS; `HPS::Approval` signed
the action, host, pool, disks, wipe flag and expiry with HMAC-SHA256 under a
per-cluster secret (`keysafe/approval.hmac`) and stored the document in the
registry (`approval_<action>_<pool>`). `HPS::Storage`, `HPS::Workload` and
`HPS::Onboard` refused to act without a valid one, and the node scripts
verified the same HMAC again with the secret sent alongside.

ctrl-exec already decides who may run what: each agent runs only the scripts
in its allowlist, and the dispatcher's auth hook decides which caller may run
which script on which agent (`docs/OPERATOR.md`). The approval layer was a
second, HPS-only gate on top of that, and it kept destructive work off the
operator API: an operator on an inner IPS could not create a pool without a
root shell on that IPS to run `hps-approve`.

## Decision

Owner ruling, 2026-11-11, verbatim:

> the approval isnt required in the lab. for any real use, ctrl-exec will
> control who does what.

HPS's own signed-approval layer is removed completely. Authorisation is
ctrl-exec's alone: its per-agent script allowlists and the IPS auth hook
decide who may run what.

Removed:

- `bin/hps-approve` and `lib/perl/HPS/Approval.pm`;
- the cluster `approval` secret (`cluster_secret('approval')`,
  `keysafe/approval.hmac`); `HPS::Keysafe::cluster_secret` stays for other
  purposes (OpenSVC);
- the approval checks in `HPS::Storage` (pool create, pool destroy, zvol
  destroy), `HPS::Workload` (workload destroy, with the zvol approvals it
  derived) and `HPS::Onboard` (host forget);
- the node-side verification (`--approval-file -`, the HMAC against the
  cluster secret, expiry, node MAC) in `storage-pool-create`,
  `storage-pool-destroy`, `storage-zvol-destroy` and `mirror-create`, and the
  signed peer-gone declaration (`--declaration-file -`) of `mirror-assemble`;
  `storage-pool-destroy`, `storage-zvol-destroy`, `mirror-create` and
  `mirror-assemble` are no longer `input = raw`, and `openssl` left the
  storage profile;
- the registry key `approval_<action>_<pool>` and the `approved_by` member of
  `workload_<name>_destroyed`.

Data an approval carried now comes as explicit arguments, validated as the
approval validated it:

```
hps-storage <host> create <pool> --disk <by-id> --disk <by-id> [--disk <by-id>]... [--wipe]
    [--dry-run] [--json] [--allow-any-pool-name]
storage-pool-create <pool> --disk <by-id> --disk <by-id> [--disk <by-id> ...] [--wipe]   (stdin: {"key_hex":"<64 hex>"})
mirror-create <name> --leg <spec> --leg <spec> [--remote-index 0|1] [--wipe]
mirror-assemble <name> --leg <spec> --leg <spec> [--remote-index 0|1] [--peer-gone]
```

`create` takes 2 to 4 distinct by-id names (with or without
`/dev/disk/by-id/`), one mirror of them all (the three-way mirror of
2026-11-11 is kept). `--peer-gone` is the caller's explicit statement that the
missing leg's owner is gone; without it a mirror with a missing leg is still
refused. The pool's encryption key is unchanged: `key_hex` from the keysafe,
the only input of `storage-pool-create` and `dataset-unlock`, on stdin.

Kept, because each protects data on its own merits:

- a disk that carries a pool label or a filesystem or partition signature is
  refused unless `--wipe` is given (pool and mirror), and then only
  the named devices are wiped; a mounted disk, one with a holder, one in an
  imported pool, or a partition is refused even with `--wipe`;
- the pool-name rule (named after the active cluster, `--allow-any-pool-name`
  to override) for create, destroy and zvol destroy;
- a pool goes on an assigned host only (STATE neither empty nor `HELD`), the
  check `hps-approve` made before it issued a `pool-create` approval;
- `--dry-run` everywhere;
- the "in use" refusals: an exported or mounted zvol, a guest that is not shut
  off (`vm-undefine`), divergent mirror legs (no override), a host still
  holding storage exports, a pool or a workload (`hps-onboard forget`), and
  `forget-key` while a pool is recorded.

## Where authorisation lives now

- **On the IPS, as root:** the tools run as before; root on the IPS is
  trusted.
- **Through the operator API:** `hps-storage`, `hps-workload` and
  `hps-onboard` are `ips-admin` scripts. The auth hook lets a live operator
  credential run an `ips-admin` script on `ips.<domain>` only, and logs each
  run (`OPERATOR run operator=<name> ... script=<script> args=<JSON>`).
  Revoking a credential (`hps-operator revoke <name>`) withdraws the right.
- **On a node:** the agent runs only its allowlisted scripts, and only for
  the IPS's dispatcher (mTLS, ADR 0001, ADR 0002).

## What an operator does instead

Before: `hps-approve pool-create <mac> --pool lab --disk A --disk B --wipe`
as root on the IPS, then `hps-storage <host> create lab`. Now one call, on the
IPS or through the operator API:

```
hps-op --cred FILE hps-storage sch-001 create lab --disk ata-SSD_A --disk ata-SSD_B --dry-run
hps-op --cred FILE hps-storage sch-001 create lab --disk ata-SSD_A --disk ata-SSD_B [--wipe]
hps-op --cred FILE hps-storage sch-001 destroy lab
hps-op --cred FILE hps-storage sch-001 zvol-destroy lab/enc/t0
hps-op --cred FILE hps-workload destroy t0 [--forget]
hps-op --cred FILE hps-onboard forget 525400000009
```

A by-id name goes without its `/dev/disk/by-id/` directory through the
operator API (`ips-admin-exec` passes no `/` outside an IPv4 CIDR).

## Consequences

- Anyone who can run `hps-storage`, `hps-workload` or `hps-onboard` (root on
  the IPS, or an operator credential) can destroy a pool, a zvol, a workload or
  a host entry in one step. Who holds an operator credential is the control.
- The job queue (ADR 0006) offered `workload-destroy <name> [--forget]` to
  anything that can write it (group `hps`, the web user), guarded only by the
  signed approval. Owner ruling 2026-11-11: the kind is removed from the queue
  (Perl and Bash allowlists). Destroy runs only as `hps-workload destroy`: root
  on the IPS, or an operator through the operator API.
- An IPS that ran an earlier build may still hold `approval_*` keys in host
  registries and `keysafe/approval.hmac`. Nothing reads them; they can be
  deleted by hand.
- `storage-pool-create` no longer checks that it runs on the node the request
  names (the approval's MAC): the dispatcher addresses one agent per host, so
  the call reaches the node `hps-storage` resolved.
