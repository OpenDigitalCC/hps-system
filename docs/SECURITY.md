# HPS security policy and threat model

This document is the security dimension's home: how to report a vulnerability,
the trust boundaries and threat model, and the current security posture. It is
a **skeleton** established at the open-source-regime baseline (8 July 2026) and
is expected to grow as the platform reaches a running state.

## Coordinated vulnerability disclosure

If you find a security vulnerability in HPS, please report it privately rather
than opening a public issue:

- Email the maintainer at the address in the repository metadata / `LICENSE`
  copyright line, with subject prefix `[HPS SECURITY]`.
- Include the affected component, a description, and reproduction steps where
  possible.
- Please allow a reasonable period for a fix before public disclosure.

There is no bug-bounty programme. Reports are handled on a best-effort basis
consistent with the open-source-steward posture in `docs/POLICY.md`.

## Trust boundaries

HPS provisions unattended machines over a network, so several boundaries are
inherent to the problem rather than defects:

1. **PXE / DHCP / TFTP.** By protocol, these are unauthenticated. Any host on
   the provisioning segment can request a DHCP lease and fetch the iPXE
   payload. The mitigation is network isolation: the provisioning network is a
   dedicated, isolated segment (see the container network notes and
   `docs/adr/0002`), not the general LAN.
2. **CGI boot manager and JSON API.** These parse client-supplied input (MAC,
   parameters) and are authenticated only by MAC address (`hps_origin_tag` /
   `X-HPS-MAC`), which is spoofable on the local segment. They must therefore
   never be exposed off the provisioning network.
3. **ctrl-exec (node setup/exec).** Post-enrolment node execution is over
   **mutual TLS** with per-node certificates issued by the IPS-hosted CA, and a
   per-node script allowlist (the single `hps-node` entry point). This is the
   authenticated channel; it replaces the former MAC-trust `osvc_cmd` join
   path. Enrolment is bound to provisioning state (`docs/adr/0002`).
4. **Keysafe secret store (`HPS::Keysafe`).**
   Keys are 32 random bytes from `/dev/urandom`, one file per host and name
   under `clusters/<cluster>/keysafe/` (directory 0700, files 0600, root only),
   never in the registry JSON, an image or a log. A directory or file that is
   group/world accessible, a symlink or owned by another uid is refused, never
   repaired silently. Keys reach a node only over ctrl-exec mTLS as the
   run's input (`input = raw`). Authorisation of destructive actions (pool
   create and destroy, zvol and workload destroy, host forget) is ctrl-exec's
   alone: its per-agent script allowlists and the operator API's auth hook
   decide who runs what (`docs/adr/0007`, owner ruling 2026-11-11). HPS keeps
   the refusals that protect data on their own merits: it wipes a disk that
   carries a signature only with an explicit `--wipe`, and refuses to destroy
   an exported or in-use zvol or a guest that is not shut off, or to forget a
   host that still holds a pool or a workload. The former Bash keysafe and its
   unauthenticated `keysafe_request_token` route are retired.

## Node identity at boot

A booting node is identified by its **MAC address on the dedicated
provisioning VLAN** (`$MAC`). The IPS looks the MAC up in the registry and
delivers that node's keys and identity from the registry; a MAC the registry
does not know is held (`STATE=HELD`) and boots only the audit image, never a
menu or an install. Once its audit is stored it waits at iPXE (a hold script that
carries only the MAC and the retry interval) until a role is assigned. Once running, the node authenticates with its ctrl-exec
identity (mutual TLS, per-node certificate issued by the IPS-hosted CA); the
MAC is not used as a credential after enrolment. No secret is part of a boot
image. Where the site requires it, MAC and port security are applied at the
switch, outside HPS.

A machine has one identity, not one per port (IPS-15). The registry keeps the
host under the MAC it first booted from (`hosts/<mac>.db`, the host key). The
audit lists the machine's physical NICs and intake records them in the host key
`macs` (`[{mac, ifname, driver, speed}]`, the host key MAC first). Every MAC
lookup goes through one helper (bash `host_resolve_mac`, Perl
`HPS::Registry->resolve_mac`), so a boot from any recorded port reaches the same
host, state, role and address. Rules:

- Which interfaces count: loopback never; virtual interfaces (veth, bridge,
  bond, vlan, tap, dummy) never. The audit's `net.nics` (read from
  `/sys/class/net` by the audit image) marks `physical` when a bus device sits
  behind the interface. The locally administered bit is not used to decide: a
  VM's virtio NIC (`52:54:00:...`) has it set and is the machine's real NIC. An
  audit without `net.nics` is read from `net.link` by interface name.
- The MAC index is computed from the registry on each lookup (a scan of the
  host directories; a MAC that is a host key needs no scan) and is never stored,
  so it cannot go stale and nothing edits it by hand.
- A MAC held by two hosts is refused at audit intake (409, logged); a MAC is
  never moved between hosts silently. `hps-onboard forget` on the other host
  frees its MACs, then the audit is sent again.
- An unknown MAC still becomes a new HELD host.
- dnsmasq gets one `dhcp_addresses` line per host listing all its MACs
  (`mac1,mac2,ip,name`), so the host's single address is handed to whichever
  port asks. dnsmasq serves that address to one port at a time; a machine with
  two ports up on the provisioning VLAN at once gets the address on one and a
  dynamic address on the other. `dns_hosts` is per host and is unchanged.
- The kernel parameter `hps.mac` stays the MAC that booted, so the
  `uplink: boot` network role follows the port actually used; the host key
  `boot_mac_last` records which port booted last. `hps-onboard show` lists all
  the MACs and accepts any of them.

The provisioning VLAN is the security boundary for this identity. Physical
breach – someone plugging a device into the provisioning network, or cloning
a node's MAC address – is **out of scope** for HPS; it is a physical and
network-security matter for the site.

## Threat model (STRIDE)

A structured pass over the trust boundaries above. Each item is either
mitigated, accepted-with-isolation, or an open hardening item.

**Spoofing.** MAC-based identity on the CGI/API surface is spoofable
(accepted; mitigated by segment isolation). ctrl-exec mTLS provides strong
identity post-enrolment (mitigated). The enrolment window is the exposure —
the registry-bound approver limits it (`docs/adr/0002`); an HMAC single-use pairing
ticket from `HPS::Keysafe` is the planned hardening if ever needed.

**Tampering.** Config lives in a file-per-key JSON registry with locking; the
integrity of downloaded distro/package artefacts is checked with gpg where
signatures are available (partial — coverage is an open item). ctrl-exec runs
scripts with no shell and an allowlist, preventing argument-injection
tampering of node operations.

**Repudiation.** rsyslog centralises logs from the IPS and nodes; ctrl-exec
logs each run with a request id. Audit completeness is an open item.

**Information disclosure.** Cluster secrets (OpenSVC agent key, cluster
secret) and keysafe keys (`clusters/<cluster>/keysafe/`, 0700 root) live under the config tree; the SBOM and any
security artefacts are handled per the open-source-steward distribution
posture. No customer data is processed. Secrets in the tree should be reviewed
against least-exposure at each close-out.

**Denial of service.** The provisioning services are single-container and not
rate-limited; DoS resistance relies on segment isolation. An authoritative
DHCP server under host networking is a specific risk if the container is ever
attached to a non-isolated network — verify the interface binding before first
start.

**Elevation of privilege.** On Alpine nodes the ctrl-exec agent runs node
scripts as its own user with no namespace/capability sandbox (the privileged C
executor is deferred — `docs/adr/0003`); the `hps-node` allowlist is the
containment boundary there. See *Node scripts under the executor* for NixOS. The `osvc_cmd`
eval-style CGI path has been removed.

5. **Operator access (the IPS's own ctrl-exec API; `docs/OPERATOR.md`).** A
   cluster is run only through its own IPS. The IPS's local ctrl-exec agent,
   `ips.<domain>`, listens on 127.0.0.1 only (`bind`, with `allowed_ips`
   as defence in depth) and
   is paired by the IPS itself, approving only a request carrying that name
   from 127.0.0.1. Remote operators reach the API only when the cluster key
   `operator_api_listen` names an address of the IPS: TLS on that address
   (self-signed certificate for the IP, pinned by the operator), never a
   loopback or wildcard bind. An operator credential is a 256-bit random
   token, shown once; the IPS keeps its SHA-256 (keysafe, and a 0640 digest
   file for the hook, which runs as the API user). The auth hook lets a
   credential run only the `ips-admin` scripts on `ips.<domain>` and ping that
   agent: never a node agent, another script, two hosts or a stored result.
   Every operator run is logged (operator, source, script, arguments). The
   `ips-admin` wrapper accepts only plain-token arguments (no metacharacters,
   no file names) and gives a tool stdin only for the two `input=raw` scripts,
   so the request context the agent writes to stdin (with the caller's token)
   never reaches a tool. Secrets (a BMC credential) travel only as ctrl-exec
   confidential input. HPS's own callers are unchanged: root on the unix
   socket, and `ced`, told from an API caller by `ENVEXEC_CALLER` (an operator
   call must also arrive on `ENVEXEC_LISTENER=tls`). The dispatcher sets
   `api_forward_token = no`, so the operator's token reaches the hook but never
   an agent. Needs ctrl-exec >= 0.14.7; with an older dispatcher the hook has no
   caller field, refuses operators (fail closed) and bring-up leaves the
   operator API off.

## State ownership

One system group, `hps`, owns the IPS state. The web user (`www-data`, to
which lighttpd drops for the CGI) is a member. Every writer runs with `umask 002`, and every
directory under the config base and the log base is setgid with group `hps`,
so the CGI can write the registry that root created and the reverse.
`supervisor_fix_state_permissions` re-asserts this at each start. The group is
a convention of the image, not of the host: HPS never relies on a host group
id. keysafe (`clusters/<cluster>/keysafe/`) is the exception: root-only
(0700), the CGI never reads keys, and the permission pass skips any path named
`keysafe`.

## Privileged actions on the IPS

The web user holds no dispatcher and no keysafe access. The CGI asks for a
privileged action by writing a job file into `clusters/<cluster>/jobs/new/`;
`bin/hps-jobs`, a root process under supervisor, runs it from a fixed table of
fifteen kinds (`%KINDS` in `lib/perl/HPS/Jobs.pm`): `pairing-window-open`,
`pairing-window-close`, `pairing-list`, `pairing-approve`; `storage-up`,
`storage-down`, `storage-trim-check`, `storage-status`; `net-up`; `osvc-deliver`; `workload-create`,
`workload-start`, `workload-stop`, `workload-status`; and
`pins-prune`. `hps-jobs` validates the arguments again. Anything that can
write that queue (group `hps`) can request those actions, so group membership is
trusted as the web user is. Destroying a workload is not a queue
kind (owner ruling 2026-11-11, ADR 0007): it runs only as `hps-workload
destroy`, by root on the IPS or an operator through the operator API. See `docs/adr/0006-ips-privilege-split.md`.

## Node scripts under the executor

Node scripts run as root with capabilities through the ctrl-exec executor;
the allowlist and the per-script arguments are the control, not the sandbox.
On NixOS images every HPS script is allowlisted under the profile `node`
(`run_as = root`, `no_new_privileges`, a fixed list of `CAP_*` names; no
`writable` list, so the filesystem is as on the console, with one difference:
the executor runs each script in a private mount namespace, so a mount a
script makes ends with it and is not seen by the next script. A script that
needs a mount to persist starts the unit that makes it, as `cnh-disk-prepare`
does with `hps-cnh-mount.service`, and reads mounts from PID 1's table with
`findmnt -N 1`). The scripts are the
readable manual runbook, so a `ced run` of `$SCRIPT` on `$NODE` does what the
same commands do by hand as root, and recovery by hand matches it. A script
reaches the profile only by being added to the allowlist in the image; `default`
stays the restrictive baseline for anything that names no profile. The control
directories of the agent stay read-only to every profile.

## Verification method

Threat-model items are checked at close-out with the security tooling in
`rules/nonfunctional-close.md` (shellcheck security warnings, `gitleaks` /
`trufflehog` secret scans, the strict SBOM drift gate). OWASP ASVS Level 1 is
the intended verification companion once the platform runs end to end.

## Open hardening items (tracked)

- ctrl-exec privileged executor adoption for per-script sandboxing (the IPS's
  own agent runs the `ips-admin` scripts as root without one).
- gpg signature coverage for all downloaded artefacts.
- a second enrolment factor (an HMAC pairing ticket from `HPS::Keysafe`) on ctrl-exec pairing.
- audit-log completeness review.
