# ADR 0003 — ctrl-exec agent packaging and delivery to nodes

- Status: accepted
- Date: 2026-07-08
- Tags: packaging, ctrl-exec, alpine, rocky, node-manager

## Context

Every provisioned node must run the ctrl-exec agent — a Perl mTLS server
(port 7443) requiring `perl`, `perl-io-socket-ssl`, `perl-json` and the
`openssl` binary. Upstream ships Debian packages and a source tarball;
there is no Alpine apk and no rpm. Upstream's `install.sh` handles Alpine
package-manager mapping and service-user creation but installs no service
unit on OpenRC systems (it recognises only systemd and procd), and its
cert-renewal adoption timer is systemd-only. HPS already serves
self-built packages to nodes from its package repo (the OpenSVC apk,
built by `node-manager/alpine-3/TCH/BUILD/`) and delivers function
bundles plus `.init` sequences over CGI.

## Decision

- **Alpine nodes**: runtime dependencies install from the HPS-mirrored
  Alpine repo (`perl`, `perl-io-socket-ssl`, `perl-json`, `openssl`); the
  agent itself installs from the upstream release tarball served from
  `hps-resources/packages/`, driven by a new `n_install_ctrl_exec`
  function. HPS supplies its own OpenRC init script (delivered with the
  function bundle) because upstream has none.
- **Rocky nodes**: same tarball path until upstream gains rpm packaging
  (a planned contribution back to ctrl-exec).
- **Cert renewal adoption**: staged renewed certificates are promoted at
  agent restart; HPS schedules a periodic agent restart (cron/OpenRC)
  well inside the 825-day leaf lifetime rather than porting the systemd
  timer.
- **The privileged C executor is not deployed initially.** It needs
  libcap and kernel ≥ 5.12, is optional, and is mutually exclusive with
  async runs; it becomes a hardening phase once per-script privilege
  profiles are wanted.

## Rationale

The tarball is upstream's supported non-deb path and keeps HPS on
released artefacts instead of maintaining a fork or a bespoke apk build
(the OpenSVC apk build pipeline exists because upstream OpenSVC offers no
Alpine artefact at all — ctrl-exec's tarball plus four stock Alpine
packages makes that machinery unnecessary). Serving the tarball from
hps-resources keeps node installs offline-capable, consistent with every
other HPS-delivered artefact. A native apk (and rpm) remain the better
long-term answer and belong upstream, not in HPS.

## Consequences

- HPS pins a ctrl-exec release tarball in `hps-resources/packages/`;
  updating the agent fleet-wide means dropping in a new tarball and
  re-running `n_install_ctrl_exec` via ctrl-exec itself.
- The OpenRC init script is HPS-owned and must track upstream agent CLI
  changes (pre-1.0 upstream; breaking changes documented in its
  CHANGELOG).
- Without the C executor, scripts run as the agent user with no
  namespace/capability sandbox; the per-node `scripts.conf` allowlist and
  the single `hps-node` entry point are the containment boundary until
  the executor phase.
- Diskless TCH nodes rebuild their root on every boot, so agent install
  and pairing state must live in the apkovol/overlay or be re-established
  each boot — the enrolment flow (ADR 0002) must therefore be idempotent
  per boot cycle.
