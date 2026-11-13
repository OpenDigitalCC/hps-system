#!/usr/bin/env bats
#
# storage-pool-create --measure: after the checks and the wipe, before
# zpool create, a raw read, write and fsync test of each named disk (IODISK
# lines on stdout). Without --measure nothing is measured; a failed measurement
# never stops the create; the raw writes never happen when a disk is refused.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_254_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-255.XXXXXX")"
  export TEST_DIR
  p3_254_setup
  p2_shim_xxd
  p2_shim_disks
  p2_shim_zpool
  p2_shim_zfs
  p3_254_disk "$P2_DISK_A"
  p3_254_disk "$P2_DISK_B"
  SCRIPT="$S/storage-pool-create"
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B")
}

teardown() {
  rm -rf "$TEST_DIR"
}

create() {
  run --separate-stderr bash "$SCRIPT" "${ARGS[@]}" "$@" <<< "$(p2_key_payload)"
}

line_no() {
  grep -n "$1" "$SHIM_LOG" | head -1 | cut -d: -f1
}

@test "shellcheck clean" {
  shellcheck -S warning "$SCRIPT"
}

@test "without --measure nothing is measured: no dd, no IODISK" {
  create
  [ "$status" -eq 0 ]
  run ! grep -q '^dd ' "$SHIM_LOG"
  [[ "$output" != *IODISK* ]]
}

@test "--measure: one IODISK line per disk with read, write, fsync p50 and max" {
  create --measure
  [ "$status" -eq 0 ]
  [[ "$output" == *"IODISK $P2_DISK_A "* ]]
  [[ "$output" == *"IODISK $P2_DISK_B "* ]]
  n=$(grep -c '^IODISK ' <<< "$output")
  [ "$n" -eq 2 ]
  grep -qE "^IODISK $P2_DISK_A [0-9]+ [0-9]+ [0-9]+\.[0-9]{2} [0-9]+\.[0-9]{2}\$" <<< "$output"
}

@test "--measure: the exact dd flags, the data from /dev/urandom, 5 sync writes per disk (HPS_IO_SYNC_COUNT)" {
  create --measure
  [ "$status" -eq 0 ]
  grep -qE "^dd if=/dev/disk/by-id/$P2_DISK_A of=/dev/null bs=4M count=1 iflag=direct" "$SHIM_LOG"
  grep -qE "^dd if=.*hps-io-measure.* of=/dev/disk/by-id/$P2_DISK_A bs=4M count=1 oflag=direct" "$SHIM_LOG"
  grep -qE '^dd if=/dev/urandom of=.*hps-io-measure' "$SHIM_LOG"
  [ "$(grep -c "of=/dev/disk/by-id/$P2_DISK_A bs=4096 count=1 .*oflag=direct,dsync" "$SHIM_LOG")" -eq 5 ]
  [ -z "$(ls "$HPS_IO_TMP")" ]
}

@test "--measure: the raw writes come after the checks and the wipe and before zpool create" {
  printf 'TYPE=ext4\n' > /dev/null
  touch "$STATE/blkid.$P2_DISK_A"
  create --measure --wipe
  [ "$status" -eq 0 ]
  w=$(line_no '^wipefs')
  d=$(line_no "of=/dev/disk/by-id/$P2_DISK_A bs=4M")
  z=$(line_no '^zpool create')
  [ "$w" -lt "$d" ]
  [ "$d" -lt "$z" ]
}

@test "a refused disk is never written: no dd, no zpool create" {
  touch "$STATE/blkid.$P2_DISK_A"
  create --measure
  [ "$status" -eq 3 ]
  run ! grep -q '^dd ' "$SHIM_LOG"
  run ! grep -q '^zpool create' "$SHIM_LOG"
}

@test "a failed measurement is logged and the create goes on" {
  FAKE_DD_FAIL_OF="by-id/$P2_DISK_A" create --measure
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"measurement of $P2_DISK_A failed"* ]]
  [[ "$output" != *"IODISK $P2_DISK_A "* ]]
  [[ "$output" == *"IODISK $P2_DISK_B "* ]]
  grep -q '^zpool create' "$SHIM_LOG"
}

@test "an existing pool on the same disks is not measured again (the disks are in use)" {
  touch "$STATE/pool-imported"
  printf '  /dev/disk/by-id/%s-part1\n  /dev/disk/by-id/%s-part1\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  create --measure
  [ "$status" -eq 0 ]
  run ! grep -q '^dd ' "$SHIM_LOG"
}
