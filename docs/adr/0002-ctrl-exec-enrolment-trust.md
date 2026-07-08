# ADR 0002 — Registry-bound auto-approval for ctrl-exec node enrolment

- Status: accepted
- Date: 2026-07-08
- Tags: security, enrolment, ctrl-exec, trust-bootstrap

## Context

ctrl-exec enrolment is deliberately manual: an agent submits a CSR to the
dispatcher's pairing port (7444), both sides derive a 6-digit code from
the CSR, and a human visually compares the codes before running
`ced approve <reqid>`. There is no auto-approve, no pre-shared enrolment
token and no trust-on-first-use mode, and approval is not exposed over the
HTTP API. HPS provisions nodes by PXE with no human present, so the
approval step must be automated — and automating it bypasses the 6-digit
visual check, ctrl-exec's only built-in MITM defence during pairing.

HPS, however, holds provisioning state ctrl-exec lacks: it allocated the
node's MAC, IP (DHCP lease), hostname and lifecycle STATE, and it drove
the node's boot. That state can bind a pairing request to an expected
node far more strongly than the current OpenSVC join path (a 15-second
join token issued to any caller presenting a known MAC).

## Decision

An IPS-side approver auto-approves pairing requests **only** when all of
the following bind the request to a node HPS is actively provisioning:

1. The reporting caller's MAC exists in the host registry and its STATE
   is enrolment-eligible (INSTALLING or CONFIGURING).
2. The pairing request visible in `ced list-requests --json` matches the
   registry allocation: hostname equals the allocated hostname, source IP
   equals the node's DHCP lease address.
3. The request arrives within a short window of the node's state
   transition (default 300 seconds, matching the agent's
   `request-pairing --background --timeout`).
4. No approval has already been granted for this host in this
   provisioning cycle (`ctrl_exec_paired` unset in the host registry).

On approval, `ctrl_exec_paired=<epoch>` is recorded in the host registry.
Requests failing any check are denied and logged. The node reports its
pairing reqid over the existing HPS API channel; the reqid itself is not
treated as a secret.

## Rationale

The compensating controls replace the visual code with a four-way binding
(identity allocation, network address, lifecycle state, time). An
attacker on the provisioning LAN must race a legitimate node during its
own provisioning window while presenting its allocated IP and hostname —
strictly harder than defeating the current MAC-only join-token issuance,
which requires only a spoofed MAC at any time. The provisioning network
is by design an isolated segment, further limiting the attacker
population. All post-enrolment traffic is mutually authenticated TLS, so
the exposure is confined to the pairing window.

## Consequences

- The residual risk is an on-LAN attacker racing a node inside its
  provisioning window with a spoofed IP and hostname. Accepted for the
  isolated provisioning segment; documented in docs/SECURITY.md when the
  threat model is written.
- A keysafe single-use token (purpose `ctrl-exec-pair`) can be layered as
  a second factor later without redesign — the reporting call gains a
  token parameter and the approver gains a validation step. Deferred
  until keysafe secure mode is implemented.
- The approver must run on the IPS (where `ced` and the CA live);
  approval never crosses the network.
- Re-provisioning a node requires clearing `ctrl_exec_paired` (and
  unpairing/revoking the old cert) as part of the reinstall path.
- ctrl-exec's short pairing timeout means the approver must poll promptly;
  it is triggered by the node's report rather than by periodic scan.
