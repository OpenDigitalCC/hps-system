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

## Out of scope: Secure Boot

The binaries are unsigned; the lab boots with Secure Boot off. Supporting it
would need an iPXE signed by a CA the firmware trusts (a shim-signed build, or
the HPS CA enrolled in the firmware db), `TRUST`/`CERT` options and image
signature checking for the kernel and initrd that iPXE loads, and a signing
step with its key outside the build image.
