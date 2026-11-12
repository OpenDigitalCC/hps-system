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
   is enrolment-eligible (INSTALLING, CONFIGURING, or NETWORK_BOOT for a
   RAM-booted NixOS node, or HELD for a held node running the audit image,
   which pairs so it can be inspected over ctrl-exec).
2. The pairing request visible in `ced list-requests --json` matches the
   registry allocation: the hostname's first label equals the allocated
   hostname (the agent registers under an FQDN whose domain is not
   HPS's to decide), source IP equals the node's DHCP lease address.
3. The request arrives within a short window of the node's last
   boot-script issue (default 300 seconds, `CTRL_EXEC_PAIR_WINDOW`,
   matching the agent's `request-pairing --background --timeout`). The
   time is the host key `last_boot_at` (epoch), written by
   `ipxe_init_handler`; a missing or unreadable value refuses.
4. No approval has already been granted for this host in this
   provisioning cycle (`ctrl_exec_paired_at` unset in the host registry; the pre-IPS-07 name
   `ctrl_exec_paired` is read as a fallback).

On approval, `ctrl_exec_paired_at=<epoch>` is recorded in the host registry,
and for one release the same epoch under the old name `ctrl_exec_paired` (the
name reads as a boolean; it is not one: see `docs/REGISTRY-KEYS.md`).
`ipxe_boot_nixos` clears both keys and opens the dispatcher
pairing window (`pairing-mode start`, one window at a time) when it issues
a boot script, since a RAM node loses its certificate on every boot. The
approver closes the window shortly after approval (delayed, so the
dispatcher can deliver the certificate on the agent's next poll).
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
- An HMAC single-use pairing ticket from `HPS::Keysafe`, if ever needed, can
  be layered as a second factor later without redesign — the reporting call
  gains a ticket parameter and the approver gains a validation step.
- The approver must run on the IPS (where `ced` and the CA live);
  approval never crosses the network.
- Re-provisioning a node requires clearing `ctrl_exec_paired_at` (and `ctrl_exec_paired`,
  and unpairing/revoking the old cert) as part of the reinstall path.
- From ctrl-exec 0.14.3 the agent registers under the HPS-chosen name
  (`request-pairing --name`) and the approver passes `approve --replace`,
  so re-pairing a node replaces its previous registration; older agents
  and dispatchers are detected and used without those options.
- ctrl-exec's short pairing timeout means the approver must poll promptly;
  it is triggered by the node's report rather than by periodic scan.

## Amendment 2026-11-12: when pairing does not go through at once

Incident, s1 after a host reboot: six nodes booted and asked to pair at once.
The approval jobs waited behind a 30 s `storage-up` in the one serial job
runner, the approver's 15 s wait gave up and the request read as missing (403),
the first approval closed the pairing window under the five others, and their
retries (hps-node-init, Restart=on-failure, 30 s apart) came after their own
windows and were refused by check 3. Rebooting each VM by hand was the only recovery. Check 3 is
unchanged and stays the security control; what changed is around it.

The approver answers with a reason
:   `ce_approve_pair_request` returns 0 approved, 3 not yet, 4 outside the
    window, 1 refused, and sets `CE_PAIR_REASON`. The API
    (`action ctrl_exec_pair_request`) turns that into the HTTP code the node
    acts on, with a JSON body `{error, code, reason, details, window_left,
    last_boot_at, timestamp}`:

| HTTP | reason | meaning | the node |
|---|---|---|---|
| 200 | `paired` | approved | waits for the certificate |
| 503 | `pending` | a pairing job did not finish within `CTRL_EXEC_PAIR_REQUEST_TIMEOUT` | retries |
| 503 | `unknown_request` | the dispatcher holds no pending request with that reqid | requests pairing again, retries |
| 503 | `no_request` | no reqid was given (the node has none yet); inside the window | retries |
| 410 | `outside_window` | the request came after the window (check 3); `pair_reboots` counted | reboots into netboot |
| 403 | `reboots_exhausted` | outside the window after `CTRL_EXEC_PAIR_MAX_REBOOTS` (3) reboots; `pair_failed_at` set | stops, logs at error |
| 403 | `refused` | any other failed check (state, address, hostname, already paired, malformed reqid, no `last_boot_at`) | stops |

Approval never waits behind other jobs
:   The root job runner runs the pairing kinds in their own lane (ADR 0006).
    One approval waits at most `CTRL_EXEC_PAIR_REQUEST_TIMEOUT` (300 s) in
    total for its pairing jobs: the node's own request timeout
    (`HPS_PAIR_TIMEOUT` in `hps-pair`, the `request-pairing --timeout`), so the
    IPS never gives up on a request the node still holds open. The two
    constants are kept equal (a bats test checks the IPS one is not shorter).

The window is not closed under other waiting nodes
:   After an approval (and after a refusal for check 3) the dispatcher's
    pairing listener is closed only when no other host is still within its own
    window and unpaired (eligible STATE, `last_boot_at` at most
    `CTRL_EXEC_PAIR_WINDOW` ago, no `ctrl_exec_paired_at`); otherwise it stays
    open, and the log names how many wait and when the last window ends.

The node retries, then reboots, then stops
:   `hps-pair` (run by `hps-node-init` and `hps-audit-pair`) reports its reqid
    and retries a 503 after 5, 10, 20, 40, 60, 60 ... s, each wait cut so the
    next ask lands no later than just after its window ends (the window is
    counted from its own boot until the IPS's `window_left` replaces it). A
    410 makes it run `systemctl reboot`: the netboot issues a new boot script,
    which renews `last_boot_at` and with it the window. The IPS counts these
    reboots in the host key `pair_reboots` and allows three; the next late
    request is a 403 `reboots_exhausted` and records `pair_failed_at`. A
    pairing removes both keys. A 403 makes `hps-pair` exit 3, and the units
    carry `RestartPreventExitStatus = 3`, so the node stays up, unpaired, with
    the reason in its journal. `hps-monitor` logs `state=PAIR_FAILED` for it
    (every 10 minutes) and `hps-ips-check` reports a WARN `pairing` naming it.
    Every attempt is logged on the node with the code and reason. Recovery:
    fix the cause, then reboot the node (a pairing clears the keys).

Still one listener for the IPS (IPS-17)
:   The dispatcher listener is opened for `CTRL_EXEC_PAIR_WINDOW` by the first
    boot script and an open while it runs does not extend it, so a host that
    boots late in another host's window can find it stopped before its own
    window ends. Its retries then get no reqid and ask with an empty one
    (503 `no_request` until its window ends, then 410 and a reboot, which
    reopens the listener). A per-node window (IPS-17) removes this.
