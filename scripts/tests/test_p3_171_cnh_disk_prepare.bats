#!/usr/bin/env bats
#
# CS-3.11: cnh-disk-prepare (format a blank device once, mount it) and the
# boot-time hps-cnh-mount (mount by label, never format).

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-171.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  C="$HPS_CNH_ROOT/var/lib/containers"
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a blank device is formatted ext4 labelled hps-cnh, mounted, and the IPS state bind-mounted" {
  p3_171_disk vdb
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CNH-DISK $HPS_DEV/vdb formatted=yes containers=$C ips=$I" ]
  grep -qxF "mkfs.ext4 -q -L hps-cnh -m 0 -- $HPS_DEV/vdb" "$SHIM_LOG"
  grep -qxF "mount -t ext4 -o noatime -- $HPS_DEV/vdb $C" "$SHIM_LOG"
  grep -qxF "mount --bind -- $C/hps-ips $I" "$SHIM_LOG"
  [ "$(stat -c %a "$C/hps-ips")" = 700 ]
  # probe, mkfs, probe again, then the mounts
  [ "$(awk '{print $1}' "$SHIM_LOG" | grep -E '^(blkid|mkfs.ext4|mount)$' | paste -sd' ' -)" = "blkid mkfs.ext4 blkid mount mount" ]
}

@test "a device already labelled hps-cnh is mounted and never formatted" {
  p3_171_disk vdb
  printf 'LABEL=hps-cnh\nTYPE=ext4\n' > "$STATE/sig.vdb"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"formatted=no"* ]]
  run ! grep -q '^mkfs' "$SHIM_LOG"
  grep -q "^mount -t ext4" "$SHIM_LOG"
}

@test "idempotent: a second run on the prepared, mounted disk changes nothing" {
  p3_171_disk vdb
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"formatted=no"* ]]
  run ! grep -qE '^(mkfs|mount)' "$SHIM_LOG"
}

@test "any other signature is refused (3) and nothing is written or mounted" {
  local sig
  p3_171_disk vdb
  for sig in 'TYPE=ext4\nLABEL=data' 'TYPE=xfs\nLABEL=hps-cnh' 'TYPE=zfs_member' 'TYPE=linux_raid_member' 'PTTYPE=gpt' 'TYPE=ext4\nLABEL=hps-cnh\nPTTYPE=dos' 'USAGE=other'; do
    printf "$sig\n" > "$STATE/sig.vdb"
    run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
    [ "$status" -eq 3 ]
    [[ "$output" == *"carries a signature"* ]]
  done
  echo 8 > "$STATE/sigrc.vdb"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ambivalent"* ]]
  run ! grep -qE '^(mkfs|mount)' "$SHIM_LOG"
}

@test "a blkid error is a failure (1), never a format" {
  p3_171_disk vdb
  echo 4 > "$STATE/sigrc.vdb"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 1 ]
  run ! grep -q '^mkfs' "$SHIM_LOG"
}

@test "only vd/sd whole disks, md and by-id paths are accepted" {
  local d
  p3_171_disk vdb
  p3_171_disk sdc
  p3_171_disk md/cnh0
  p3_171_disk disk/by-id/virtio-hpscnh01
  for d in vdb sdc md/cnh0 disk/by-id/virtio-hpscnh01; do
    rm -rf "$STATE/mounts" "${HPS_CNH_ROOT:?}/var"
    run bash "$S/cnh-disk-prepare" "$HPS_DEV/$d"
    [ "$status" -eq 0 ]
  done
  p3_171_disk vdb1
  p3_171_disk nvme0n1
  p3_171_disk loop0
  p3_171_disk mapper/x
  for d in "$HPS_DEV/vdb1" "$HPS_DEV/nvme0n1" "$HPS_DEV/loop0" "$HPS_DEV/mapper/x" "$HPS_DEV/md/../vdb" "$HPS_DEV/disk/by-id/../../vdb" "/etc/passwd" "vdb" "$HPS_DEV/disk/by-uuid/x" "$HPS_DEV//vdb"; do
    run bash "$S/cnh-disk-prepare" "$d"
    [ "$status" -eq 3 ]
  done
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdz"
  [ "$status" -eq 3 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "a containers mount from another device, or files already there, are refused" {
  p3_171_disk vdb
  p3_171_disk vdc
  p3_171_mount "$C" "$HPS_DEV/vdc"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already mounted from $HPS_DEV/vdc"* ]]
  rm -f "$STATE/mounts" "$STATE/sig.vdb"
  mkdir -p "$C/storage"
  touch "$C/storage/db.sql"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already holds files"* ]]
  # refused before any format (lab 2026-11-11: the refusal came after mkfs)
  [[ "$output" != *"making an ext4 filesystem"* ]]
}

@test "empty directories (podman's tmpfiles storage/tmp at boot) are not files: the disk is prepared" {
  p3_171_disk vdb
  mkdir -p "$C/storage/tmp" "$I"
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CNH-DISK $HPS_DEV/vdb formatted=yes"* ]]
}

@test "a failing mkfs fails (1) without mounting" {
  p3_171_disk vdb
  FAKE_MKFS_RC=1 run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb"
  [ "$status" -eq 1 ]
  run ! grep -q '^mount' "$SHIM_LOG"
}

@test "usage errors exit 2" {
  run bash "$S/cnh-disk-prepare"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-disk-prepare" "$HPS_DEV/vdb" extra
  [ "$status" -eq 2 ]
  run bash "$S/cnh-disk-prepare" --force
  [ "$status" -eq 2 ]
}

# --- hps-cnh-mount (boot) ---------------------------------------------------

@test "boot: the disk labelled hps-cnh is mounted at both places" {
  p3_171_disk vdb
  printf 'TYPE=ext4\nLABEL=hps-cnh\n' > "$STATE/sig.vdb"
  echo "$HPS_DEV/vdb" > "$STATE/labelled"
  run bash "$B/hps-cnh-mount.sh"
  [ "$status" -eq 0 ]
  grep -qxF "mount -t ext4 -o noatime -- $HPS_DEV/vdb $C" "$SHIM_LOG"
  grep -qxF "mount --bind -- $C/hps-ips $I" "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$B/hps-cnh-mount.sh"
  [ "$status" -eq 0 ]
  run ! grep -q '^mount' "$SHIM_LOG"
}

@test "boot: no labelled disk is not an error and mounts nothing" {
  run bash "$B/hps-cnh-mount.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stays in RAM"* ]]
  run ! grep -q '^mount' "$SHIM_LOG"
}

@test "boot: two labelled disks, or a non-ext4 one, mount nothing (1)" {
  printf '%s\n' "$HPS_DEV/vdb" "$HPS_DEV/vdc" > "$STATE/labelled"
  run bash "$B/hps-cnh-mount.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 disks are labelled"* ]]
  echo "$HPS_DEV/vdb" > "$STATE/labelled"
  printf 'TYPE=xfs\nLABEL=hps-cnh\n' > "$STATE/sig.vdb"
  run bash "$B/hps-cnh-mount.sh"
  [ "$status" -eq 1 ]
  run ! grep -q '^mount' "$SHIM_LOG"
}

@test "boot: the mount script never formats" {
  run ! bash -c "grep -vE '^[[:space:]]*#' '$B/hps-cnh-mount.sh' | grep -E 'mkfs|wipefs|sgdisk|parted|dd '"
}
