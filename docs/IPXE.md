# iPXE served by the IPS

Every node boot goes through iPXE, so its version is part of the HPS pin, not
of the IPS image's distribution.

## What is built

`flake.nix` builds iPXE from the pinned nixpkgs (`pkgs.ipxe`, overridden to
exactly three targets, no embedded script, no secret):

| File | Target | Used for |
|---|---|---|
| `snponly.efi` | `bin-x86_64-efi/snponly.efi` | UEFI clients: dnsmasq's first chain step |
| `ipxe.efi` | `bin-x86_64-efi/ipxe.efi` | UEFI NICs without SNP (kept in the TFTP root) |
| `undionly.kpxe` | `bin/undionly.kpxe` | BIOS clients |

`nix build .#ipxe` gives the three files and `ipxe.json` (version, file names,
nixpkgs rev); `checks.<system>.ipxe` builds the same output.

## What is published

`nix/build.sh` publishes the set with the pin:

    <pin>/ipxe/{snponly.efi,ipxe.efi,undionly.kpxe,ipxe.json}

`ipxe.json` adds `built_at`, `pin`, and `sha256` and `size` per file. The three
binaries are listed in `<pin>/SHA256SUMS` as `ipxe/<file>`, and every profile's
`boot.json` carries `ipxe.version`. `hps-pins verify` checks the `ipxe/` files
when the directory exists (a pin without one verifies as before); `ipxe/` is
not a profile directory.

## What the IPS serves

At bring-up `supervisor_populate_tftp` selects the latest pin's iPXE
(`<resources>/nixos/latest`), checks each file against its `ipxe.json` sha256
and copies it into the TFTP root. When the latest pin has no `ipxe/`, or a
file is missing or fails its hash, the image's own Debian iPXE is served
instead and the reason is logged (`supervisor_select_pin_ipxe`).
Restart the IPS after a new pin is built to serve its iPXE.

`hps-ips-check` reports `ipxe: pin <pin> <version>` or, for the fallback,
`ipxe: image <version>` as a WARN.

The DHCP chain is unchanged: dnsmasq hands `snponly.efi` (UEFI) or
`undionly.kpxe` (BIOS) to a non-iPXE client, and iPXE then fetches
`boot_manager.sh?cmd=init`.

## Audit admission (IPS-16)

An audit image is large (about 1.5 GB with full firmware), so the IPS serves
only so many at once and a burst of new nodes does not compete with workloads.
The limit applies only to a held host that needs an audit (no audit stored, or
`hps-onboard reaudit`). An assigned host is never limited: its role image is
served at once.

- `audit_max_concurrent` (cluster key, default 2, 0 = no limit) and
  `audit_timeout_seconds` (default 900; 30..86400).
- A host is auditing from the moment the IPS serves it the audit image (host
  key `audit_started_at`) until its audit is stored (the key is deleted), or
  until `audit_timeout_seconds` has passed. A timed-out audit frees its slot.
- A held host that needs an audit is admitted when fewer than
  `audit_max_concurrent` other hosts are auditing and no earlier-seen host is
  waiting for the slot. "Earlier" is the host key `initialised_at`, then the
  MAC: first seen, first audited. A waiting host that stopped asking (no boot
  request within 3 x `hold_retry_seconds` + 30 s) does not hold a slot back.
  A host already auditing that asks again (a reboot of the audit image) is
  served again without taking a second slot; its timeout still counts from the
  first serve.
- Otherwise the host gets the hold script (as in IPS-14), which prints
  `HPS: <mac> is held; waiting for an audit slot (<n> running, retry in <s> s)`
  and asks again every `hold_retry_seconds`. Waiting costs about 3% of a core.
- The decision is taken under a lock (`/tmp/hps-audit-admission.lock`, or
  `$HPS_AUDIT_LOCK`) so two requests cannot take the last slot. Each admission
  is logged at info (`audit admitted: ...`); a wait is logged at debug.

## Out of scope: Secure Boot

The binaries are unsigned; the lab boots with Secure Boot off. Supporting it
would need an iPXE signed by a CA the firmware trusts (a shim-signed build, or
the HPS CA enrolled in the firmware db), `TRUST`/`CERT` options and image
signature checking for the kernel and initrd that iPXE loads, and a signing
step with its key outside the build image.
