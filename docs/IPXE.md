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

## Firmware layer (audit image)

The audit image needs the whole linux-firmware set (owner ruling: full
firmware in the audit image only, none in node images), about 825 MiB. It is
not in the image's store: `nix/pkgs/hps-firmware-layer.nix` packs it as a
separate initrd, so a normal image build does not repack it.

- The layer is an uncompressed cpio with one file, `/firmware.squashfs`
  (zstd level 6). Its root is the tree NixOS installs for
  `hardware.firmware = [ linux-firmware ]` (each file zstd-compressed). Its
  store path depends on linux-firmware and the squashfs/cpio tooling only, so
  it changes with the firmware or a nixpkgs bump, never with the audit modules.
- `hps-audit.nix` forces `hardware.firmware` to `[ ]`. Without the force,
  `enableAllHardware` would merge in the whole redistributable firmware set.
  In the systemd initrd, `/firmware.squashfs` is mounted read-only (loop) at
  `/run/hps-firmware` once `systemd-modules-load` is done and before
  `systemd-udev-trigger`, so drivers that probe in the initrd already find
  their firmware. The kernel's built-in `firmware_class` gets
  `firmware_class.path=/run/hps-firmware` on the command line. NixOS
  activation writes the (empty) `hardware.firmware` path into that parameter,
  so an activation snippet ordered after it (`deps = [ "udevd" ]`) writes the
  layer's path back. The mount lives under `/run`, which the initrd carries
  into the system, so the same path serves stage 2. A boot that gets only one
  initrd (an IPS that predates this) skips the mount and runs without firmware.
- `nix/build.sh` publishes the layer once per store path, shared by every
  pin, and copies nothing while it is unchanged:

      <resources>/nixos/firmware/<store hash>-hps-firmware-layer-<version>.cpio

  The audit `boot.json` carries
  `extra_initrds: [{path: "firmware/<file>", sha256, size}]` (the path is
  relative to `<resources>/nixos`), and `<pin>/SHA256SUMS` lists the file as
  `../firmware/<file>`. A layer change also changes the pin name.
- `nixos_boot_lines` prints one more `initrd http://<ips>/nixos/firmware/<file>`
  line after the image's own `initrd` and adds `initrd=<file>` to the kernel
  command line (for an EFI stub that reads `initrd=`; with iPXE's LoadFile2
  the kernel gets every loaded initrd anyway). On BIOS, iPXE passes the
  initrds to the kernel back to back. A boot.json without `extra_initrds`
  (every older pin) boots as before. A path other than `firmware/<file name>`,
  or a layer that is not published, refuses the boot instead of serving it
  without firmware.
- `hps-pins verify` checks the layer against boot.json and SHA256SUMS, and
  hashes it once per run. `prune` and `delete` remove a layer only when no
  remaining pin names it and it was written more than an hour ago, so a build
  that is still publishing is never raced. `firmware/` is not a pin;
  `scripts/nixos-prune-pins.sh` skips it. `hps-cnh-publish` lists each layer
  once, with the pins that name it.

## Out of scope: Secure Boot

The binaries are unsigned; the lab boots with Secure Boot off. Supporting it
would need an iPXE signed by a CA the firmware trusts (a shim-signed build, or
the HPS CA enrolled in the firmware db), `TRUST`/`CERT` options and image
signature checking for the kernel and initrd that iPXE loads, and a signing
step with its key outside the build image.
