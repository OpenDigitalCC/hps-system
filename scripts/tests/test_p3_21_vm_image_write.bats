#!/usr/bin/env bats
#
# CS-3.3: vm-image-write.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-21.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "writes the image on a fresh (zero) disk: sha256, then qemu-img convert; last line IMAGE" {
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
  sum=$(/usr/bin/sha256sum "$IMG")
  [ "${lines[-1]}" = "IMAGE vm1 ${sum%% *} written" ]
  [[ "$output" == *"image sha256 ${sum%% *}"* ]]
  grep -qF "qemu-img convert -f qcow2 -O raw $IMG $DISK" "$SHIM_LOG"
  [ "$(awk '{print $1}' "$SHIM_LOG" | paste -sd' ' -)" = "virsh sha256sum qemu-img" ]
  head -c 8 "$DISK" | grep -q RAWIMAGE
}

@test "idempotent: a second run is refused (3), runs no qemu-img and leaves the disk alone" {
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
  before=$(/usr/bin/sha256sum "$DISK")
  : > "$SHIM_LOG"
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"first sector"* ]]
  run ! grep -q qemu-img "$SHIM_LOG"
  [ "$(/usr/bin/sha256sum "$DISK")" = "$before" ]
}

@test "a disk with a non-zero byte in the first 512 bytes is refused (3)" {
  printf 'X' | dd of="$DISK" bs=1 seek=511 conv=notrunc status=none
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 3 ]
  run ! grep -q qemu-img "$SHIM_LOG"
}

@test "a non-zero byte after the first 512 bytes does not count" {
  printf 'X' | dd of="$DISK" bs=1 seek=512 conv=notrunc status=none
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
}

@test "--force writes over a disk with data" {
  printf 'DATA' | dd of="$DISK" conv=notrunc status=none
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --force
  [ "$status" -eq 0 ]
  grep -q '^qemu-img convert' "$SHIM_LOG"
}

@test "a guest that is defined and not shut off blocks the write (3), --force does not override it" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --force
  [ "$status" -eq 3 ]
  [[ "$output" == *"in use"* ]]
  run ! grep -q qemu-img "$SHIM_LOG"
}

@test "a defined, shut-off guest is fine" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
}

@test "usage errors exit 2" {
  run bash "$S/vm-image-write"
  [ "$status" -eq 2 ]
  run bash "$S/vm-image-write" vm1 --disk "$DISK"
  [ "$status" -eq 2 ]
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --bogus
  [ "$status" -eq 2 ]
}

@test "refusals exit 3: bad name, disk outside /dev, missing disk, missing image, not .qcow2" {
  run bash "$S/vm-image-write" VM1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-image-write" vm1 --disk /etc/hosts --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-image-write" vm1 --disk "$HPS_DEV/md/none" --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$TEST_DIR/images/none.qcow2"
  [ "$status" -eq 3 ]
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$TEST_DIR/images/base.raw"
  [ "$status" -eq 3 ]
  run ! grep -q qemu-img "$SHIM_LOG"
}

@test "a failing qemu-img fails the script (1) and prints no IMAGE line" {
  FAKE_QEMU_RC=1 run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 1 ]
  [[ "$output" != *"IMAGE vm1"* ]]
}
