#!/usr/bin/env bats
#
# cnh-ips-cleanup (lab 2026-11-12: a bootstrap filled cnh-001's state disk and
# the inner IPS's tools could not run): removes *.part files and incomplete
# pins under /var/lib/hps-ips, never the latest pin, never anything else.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-206.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
  N="$I/srv/hps-resources/nixos"
  mkdir -p "$N/firmware"
  p3_171_mount "$I" "$HPS_CNH_ROOT/var/lib/containers/hps-ips"
  SCRIPT="$S/cnh-ips-cleanup"
  # complete: SHA256SUMS and every profile with boot.json (ipxe is no profile)
  pin_complete p-old
  pin_complete p-latest
  echo p-latest > "$N/latest"
  printf '%2000s' x > "$N/firmware/abc-layer.cpio"
  mkdir -p "$I/hps-system/scripts" "$I/srv/hps-config"
  echo keep > "$I/hps-system/scripts/run-hps.sh"
  echo keep > "$I/srv/hps-config/cluster.db"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# pin_complete <pin>
pin_complete() {
  mkdir -p "$N/$1/node-base" "$N/$1/node-cnh" "$N/$1/ipxe"
  echo sums > "$N/$1/SHA256SUMS"
  echo '{}' > "$N/$1/node-base/boot.json"
  echo '{}' > "$N/$1/node-cnh/boot.json"
  printf '%100s' x > "$N/$1/node-base/initrd"
  echo ipxe > "$N/$1/ipxe/ipxe.json"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2" {
  run bash "$SCRIPT" --force
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --dry-run extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" somewhere
  [ "$status" -eq 2 ]
}

@test "the disk not mounted: refused (3), nothing removed" {
  : > "$STATE/mounts"
  printf '%10s' x > "$I/hps-system.tar.gz.part"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not mounted"* ]]
  [ -f "$I/hps-system.tar.gz.part" ]
}

@test "nothing to clean: 0 freed, complete pins, firmware and the tree untouched" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CLEANUP freed=0 pins=0 parts=0 free=107374182400 dry_run=no" ]
  [ -d "$N/p-old" ]
  [ -d "$N/p-latest" ]
  [ -f "$N/firmware/abc-layer.cpio" ]
}

@test "removes .part files anywhere under the state dir, and counts their bytes" {
  printf '%10s' x > "$I/hps-system.tar.gz.part"
  printf '%25s' x > "$N/firmware/def-layer.cpio.part"
  printf '%5s' x > "$N/p-latest/node-cnh/initrd.part"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CLEANUP freed=40 pins=0 parts=3 free=107374182400 dry_run=no" ]
  [[ "$output" == *"removed part hps-system.tar.gz.part bytes=10"* ]]
  [[ "$output" == *"removed part srv/hps-resources/nixos/firmware/def-layer.cpio.part bytes=25"* ]]
  [ ! -e "$I/hps-system.tar.gz.part" ]
  [ ! -e "$N/firmware/def-layer.cpio.part" ]
  [ ! -e "$N/p-latest/node-cnh/initrd.part" ]
  [ -f "$N/p-latest/node-base/initrd" ]
  [ -f "$N/firmware/abc-layer.cpio" ]
}

@test "a pin without SHA256SUMS, or with a profile lacking boot.json, is removed whole" {
  pin_complete p-nosums
  rm "$N/p-nosums/SHA256SUMS"
  pin_complete p-noboot
  rm "$N/p-noboot/node-cnh/boot.json"
  printf '%7s' x > "$N/p-noboot/node-cnh/initrd.part"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "$N/p-nosums" ]
  [ ! -e "$N/p-noboot" ]
  [[ "$output" == *"removed pin p-nosums bytes="*"(no SHA256SUMS)"* ]]
  [[ "$output" == *"removed pin p-noboot bytes="*"(profile node-cnh has no boot.json)"* ]]
  # the .part inside a removed pin is counted once, with the pin
  [[ "${lines[-1]}" == "CLEANUP freed="*" pins=2 parts=0 free=107374182400 dry_run=no" ]]
  [ -d "$N/p-old" ]
  [ -d "$N/p-latest" ]
}

@test "an ipxe directory without boot.json does not make a pin incomplete" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$N/p-old/ipxe" ]
  [[ "${lines[-1]}" == *" pins=0 "* ]]
}

@test "the pin nixos/latest names is kept even when incomplete" {
  rm "$N/p-latest/SHA256SUMS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -d "$N/p-latest" ]
  [[ "$output" == *"keeping p-latest although it is incomplete (no SHA256SUMS): nixos/latest names it"* ]]
  [[ "${lines[-1]}" == *" pins=0 "* ]]
}

@test "freed bytes are the apparent bytes of the pin directory" {
  pin_complete p-half
  rm "$N/p-half/SHA256SUMS"
  local want
  want=$(du -sb -x "$N/p-half" | cut -f1)
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CLEANUP freed=$want pins=1 parts=0 free=107374182400 dry_run=no" ]
}

@test "--dry-run lists the same and removes nothing" {
  pin_complete p-half
  rm "$N/p-half/node-base/boot.json"
  printf '%10s' x > "$I/hps-system.tar.gz.part"
  printf '%3s' x > "$N/p-half/node-base/bzImage.part"
  run bash "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove pin p-half bytes="* ]]
  [[ "$output" == *"would remove part hps-system.tar.gz.part bytes=10"* ]]
  [[ "$output" != *bzImage.part* ]]
  [[ "${lines[-1]}" == "CLEANUP freed="*" pins=1 parts=1 free=107374182400 dry_run=yes" ]]
  [ -d "$N/p-half" ]
  [ -f "$I/hps-system.tar.gz.part" ]
  [[ "$output" != *'+ rm '* ]]
}

@test "symbolic links are neither followed nor removed; odd names and firmware are no pins" {
  mkdir -p "$TEST_DIR/outside/p-x"
  echo precious > "$TEST_DIR/outside/p-x/data.part"
  ln -s "$TEST_DIR/outside/p-x" "$N/p-link"
  mkdir -p "$N/Odd_Name/node-base"
  rm -rf "$N/firmware"
  mkdir -p "$N/firmware"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$N/p-link" ]
  [ -f "$TEST_DIR/outside/p-x/data.part" ]
  [ -d "$N/Odd_Name" ]
  [ -d "$N/firmware" ]
  [[ "${lines[-1]}" == *" pins=0 parts=0 "* ]]
}

@test "the hps-system tree, the config and complete pins are never touched" {
  pin_complete p-bad
  rm "$N/p-bad/SHA256SUMS"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$I/hps-system/scripts/run-hps.sh")" = keep ]
  [ "$(cat "$I/srv/hps-config/cluster.db")" = keep ]
  [ -f "$N/p-old/node-base/initrd" ]
  [ "$(cat "$N/latest")" = p-latest ]
}
