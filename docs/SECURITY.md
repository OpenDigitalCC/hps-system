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
4. **keysafe.** Single-use, time-limited tokens for privileged node operations
   (e.g. backup). The "secure" (cryptographic) mode is not yet implemented;
   "open" mode issues UUID tokens and is explicitly marked insecure in the
   code — a hardening item, not a shipped guarantee.

## Threat model (STRIDE)

A structured pass over the trust boundaries above. Each item is either
mitigated, accepted-with-isolation, or an open hardening item.

**Spoofing.** MAC-based identity on the CGI/API surface is spoofable
(accepted; mitigated by segment isolation). ctrl-exec mTLS provides strong
identity post-enrolment (mitigated). The enrolment window is the exposure —
the registry-bound approver limits it (`docs/adr/0002`); a keysafe second
factor is the planned hardening.

**Tampering.** Config lives in a file-per-key JSON registry with locking; the
integrity of downloaded distro/package artefacts is checked with gpg where
signatures are available (partial — coverage is an open item). ctrl-exec runs
scripts with no shell and an allowlist, preventing argument-injection
tampering of node operations.

**Repudiation.** rsyslog centralises logs from the IPS and nodes; ctrl-exec
logs each run with a request id. Audit completeness is an open item.

**Information disclosure.** Cluster secrets (OpenSVC agent key, cluster
secret) and keysafe tokens live under the config tree; the SBOM and any
security artefacts are handled per the open-source-steward distribution
posture. No customer data is processed. Secrets in the tree should be reviewed
against least-exposure at each close-out.

**Denial of service.** The provisioning services are single-container and not
rate-limited; DoS resistance relies on segment isolation. An authoritative
DHCP server under host networking is a specific risk if the container is ever
attached to a non-isolated network — verify the interface binding before first
start.

**Elevation of privilege.** The ctrl-exec agent currently runs node scripts as
its own user with no namespace/capability sandbox (the privileged C executor is
deferred — `docs/adr/0003`); the `hps-node` allowlist is the containment
boundary until the executor is adopted. The `osvc_cmd` eval-style CGI path has
been removed.

## Verification method

Threat-model items are checked at close-out with the security tooling in
`rules/nonfunctional-close.md` (shellcheck security warnings, `gitleaks` /
`trufflehog` secret scans, the strict SBOM drift gate). OWASP ASVS Level 1 is
the intended verification companion once the platform runs end to end.

## Open hardening items (tracked)

- keysafe secure (cryptographic) mode — currently a stub.
- ctrl-exec privileged executor adoption for per-script sandboxing.
- gpg signature coverage for all downloaded artefacts.
- a second enrolment factor (keysafe token) on ctrl-exec pairing.
- audit-log completeness review.
