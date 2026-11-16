#!/usr/bin/env bats
#
# CS-2.1: storage-pool-create. zpool, zfs, lsblk, blkid, zdb, wipefs, readlink
# and xxd are shims. Proves it runs with no approval (ADR 0007), every disk
# refusal (signature without --wipe, partition, mounted, holder, missing,
# member of an imported pool), wipe only with --wipe and only on the named
# by-id devices, the exact zpool create flags, the encrypted
# parent created with the key on stdin (never on a command line or in a file),
# and the idempotent second run.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-31.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_xxd
  p2_shim_disks
  p2_shim_zpool
  p2_shim_zfs
  SCRIPT="$S/storage-pool-create"
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B")
}

teardown() {
  rm -rf "$TEST_DIR"
}

# create [extra args...]: run the script with the key document on stdin.
create() {
  run --separate-stderr bash "$SCRIPT" "${ARGS[@]}" "$@" <<< "$(p2_key_payload)"
}

# create_with <payload> [extra args...]: the same with another stdin.
create_with() {
  local p=$1
  shift
  run --separate-stderr bash "$SCRIPT" "${ARGS[@]}" "$@" <<< "$p"
}

no_disk_touched() {
  run ! grep -E '^(zpool create|zfs create|wipefs|zpool labelclear)' "$SHIM_LOG"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2 and run nothing" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --disk "$P2_DISK_A" --disk "$P2_DISK_B"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --approval-file -
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --wipe=1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a pool name or disk that is not a plain name is refused (3)" {
  run bash "$SCRIPT" 'a b' --disk x --disk y <<< '{}'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" lab --disk '../x' --disk y <<< '{}'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" lab --disk x --disk x <<< '{}'
  [ "$status" -eq 3 ]
}

@test "runs with no approval: the key document alone is the input, no hps.mac needed" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  create
  [ "$status" -eq 0 ]
  grep -q '^zpool create ' "$SHIM_LOG"
  [[ "$stderr" != *"approv"* ]]
}

@test "disk order in the arguments does not matter" {
  ARGS=(lab --disk "$P2_DISK_B" --disk "$P2_DISK_A")
  create
  [ "$status" -eq 0 ]
}

@test "garbage input is refused (3)" {
  create_with "not json"
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "a key_hex that is not 64 hex is refused before any disk is touched" {
  create_with "$(p2_key_payload abcd)"
  [ "$status" -eq 3 ]
  no_disk_touched
  create_with '{}'
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"key_hex"* ]]
  no_disk_touched
}

@test "a disk that does not exist under /dev/disk/by-id is refused" {
  touch "$STATE/missing.$P2_DISK_B"
  create
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"does not exist"* ]]
  no_disk_touched
}

@test "a partition is refused" {
  printf 'part \n' > "$STATE/lsblk.$P2_DISK_A"
  create
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not a whole disk"* ]]
  no_disk_touched
}

@test "a disk with a mounted partition is refused, even with --wipe" {
  printf 'disk \npart /srv\n' > "$STATE/lsblk.$P2_DISK_A"
  create --wipe
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"mounted"* ]]
  no_disk_touched
}

@test "a disk with a holder (lvm) is refused, even with --wipe" {
  printf 'disk \npart \nlvm \n' > "$STATE/lsblk.$P2_DISK_A"
  create --wipe
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"holder"* ]]
  no_disk_touched
}

@test "a disk that belongs to an imported pool is refused, even with --wipe" {
  echo "	/dev/disk/by-id/$P2_DISK_A-part1  ONLINE 0 0 0" > "$STATE/status-all"
  touch "$STATE/blkid.$P2_DISK_A"
  create --wipe
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"imported pool"* ]]
  no_disk_touched
}

@test "a filesystem signature without wipe is refused and nothing is erased" {
  touch "$STATE/blkid.$P2_DISK_B"
  create
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"--wipe is needed"* ]]
  no_disk_touched
}

@test "a ZFS label (zdb) without wipe is refused" {
  touch "$STATE/zdb.$P2_DISK_A"
  create
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "a pool in the zpool import listing on the disk without wipe is refused" {
  printf '   pool: zp03\n\tmirror-0\n\t  %s ONLINE\n' "$P2_DISK_A" > "$STATE/import-listing"
  create
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "--wipe prints WILL WIPE for the named devices and wipes exactly those" {
  touch "$STATE/blkid.$P2_DISK_A"
  touch "$STATE/zdb.$P2_DISK_B"
  create --wipe
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WILL WIPE: /dev/disk/by-id/$P2_DISK_A"* ]]
  [[ "$stderr" == *"WILL WIPE: /dev/disk/by-id/$P2_DISK_B"* ]]
  grep -qxF "zpool labelclear -f /dev/disk/by-id/$P2_DISK_A" "$SHIM_LOG"
  grep -qxF "zpool labelclear -f /dev/disk/by-id/$P2_DISK_B" "$SHIM_LOG"
  grep -qxF "wipefs -a /dev/disk/by-id/$P2_DISK_A" "$SHIM_LOG"
  grep -qxF "wipefs -a /dev/disk/by-id/$P2_DISK_B" "$SHIM_LOG"
  [ "$(grep -c '^wipefs' "$SHIM_LOG")" -eq 2 ]
  [ "$(grep -c '^zpool labelclear' "$SHIM_LOG")" -eq 2 ]
  # wiping happens before the pool is created
  local wl cl
  wl=$(grep -n '^wipefs' "$SHIM_LOG" | tail -1 | cut -d: -f1)
  cl=$(grep -n '^zpool create' "$SHIM_LOG" | cut -d: -f1)
  [ "$wl" -lt "$cl" ]
}

@test "without --wipe, clean disks: nothing is wiped" {
  create
  [ "$status" -eq 0 ]
  run ! grep -E '^(wipefs|zpool labelclear)' "$SHIM_LOG"
  [[ "$stderr" != *"WILL WIPE"* ]]
}

@test "zpool create has exactly the expected flags and the by-id paths" {
  create
  [ "$status" -eq 0 ]
  grep -qxF "zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none lab mirror /dev/disk/by-id/$P2_DISK_A /dev/disk/by-id/$P2_DISK_B" "$SHIM_LOG"
  run ! grep -E '^zpool create .* -f' "$SHIM_LOG"
  [[ "$stderr" == *"using /dev/disk/by-id/$P2_DISK_A"* ]]
}

@test "the encrypted parent is created with the key on stdin only" {
  create
  [ "$status" -eq 0 ]
  grep -qxF "zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt lab/enc" "$SHIM_LOG"
  # the 32 raw bytes reached zfs on stdin
  [ "$(wc -c < "$STATE/stdin.create")" -eq 32 ]
  [ "$(perl -0777 -ne 'print unpack("H*",$_)' < "$STATE/stdin.create")" = "$P2_KEY" ]
  # pool create comes before the dataset, key still loaded: no unload-key
  run ! grep -q 'unload-key' "$SHIM_LOG"
}

@test "--sync and --logbias go on the enc dataset at its creation; an existing enc is left alone; bad values refused" {
  create --sync disabled --logbias throughput
  [ "$status" -eq 0 ]
  grep -qxF "zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt -o sync=disabled -o logbias=throughput lab/enc" "$SHIM_LOG"
  [[ "$stderr" == *"+ zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt -o sync=disabled -o logbias=throughput lab/enc  (raw key on stdin)"* ]]
  [ "$(wc -c < "$STATE/stdin.create")" -eq 32 ]
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  : > "$SHIM_LOG"
  create --sync standard
  [ "$status" -eq 0 ]
  run ! grep -E '^zfs (create|set)' "$SHIM_LOG"
  : > "$SHIM_LOG"
  create --sync off
  [ "$status" -eq 3 ]
  create --logbias fast
  [ "$status" -eq 3 ]
  create --sync
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "the key appears in no logged command, stderr or file the script wrote" {
  create --wipe
  [ "$status" -eq 0 ]
  run ! grep -F "$P2_KEY" "$SHIM_LOG"
  [[ "$stderr" != *"$P2_KEY"* ]]
  [[ "$output" != *"$P2_KEY"* ]]
  run ! grep -rlF "$P2_KEY" "$TMPDIR" "$WORK"
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
}

@test "second run with the pool on the same disks and lab/enc present is a no-op (0) after status" {
  create
  [ "$status" -eq 0 ]
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  : > "$SHIM_LOG"
  create --wipe
  [ "$status" -eq 0 ]
  run ! grep -E '^(zpool create|zfs create|wipefs|zpool labelclear)' "$SHIM_LOG"
  grep -qxF 'zpool status lab' "$SHIM_LOG"
}

@test "the pool present on other disks is refused" {
  touch "$STATE/pool-imported"
  printf '\t/dev/disk/by-id/ata-OTHER-1  ONLINE\n\t/dev/disk/by-id/ata-OTHER-2  ONLINE\n' > "$STATE/status-pool"
  create
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different disks"* ]]
  no_disk_touched
}

@test "the pool present on the same disks but without lab/enc gets only the dataset" {
  touch "$STATE/pool-imported"
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  create
  [ "$status" -eq 0 ]
  run ! grep -E '^(zpool create|wipefs|zpool labelclear)' "$SHIM_LOG"
  grep -q '^zfs create .* lab/enc$' "$SHIM_LOG"
}

@test "every command is logged as it runs" {
  create
  [[ "$stderr" == *"+ zpool create "* ]]
  [[ "$stderr" == *"+ zfs create "* ]]
  [[ "$stderr" == *"+ zpool status lab"* ]]
}

@test "a three-way mirror: three disks, one mirror of all three (owner 2026-11-11)" {
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --disk ata-DISK-C)
  create
  [ "$status" -eq 0 ]
  grep -qxF "zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none lab mirror /dev/disk/by-id/$P2_DISK_A /dev/disk/by-id/$P2_DISK_B /dev/disk/by-id/ata-DISK-C" "$SHIM_LOG"
}

@test "one disk makes a single-vdev pool (the normal SCH shape: the mirror is across storage hosts)" {
  ARGS=(lab --disk "$P2_DISK_A")
  create
  [ "$status" -eq 0 ]
  grep -qxF "zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none lab /dev/disk/by-id/$P2_DISK_A" "$SHIM_LOG"
  run ! grep -q '^zpool create .* mirror' "$SHIM_LOG"
  [[ "$stderr" == *"one disk: a single-vdev pool (the mirror is across storage hosts)"* ]]
  grep -qxF "zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt lab/enc" "$SHIM_LOG"
  # idempotent: the same one-disk pool again is a no-op after status
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" > "$STATE/status-pool"
  : > "$SHIM_LOG"
  create
  [ "$status" -eq 0 ]
  run ! grep -E '^(zpool create|zfs create|wipefs)' "$SHIM_LOG"
  grep -qxF 'zpool status lab' "$SHIM_LOG"
}

@test "no disk, or five, is a usage error; a disk given twice is refused; nothing is touched" {
  ARGS=(lab)
  create
  [ "$status" -eq 2 ]
  no_disk_touched
  ARGS=(lab --disk a1 --disk a2 --disk a3 --disk a4 --disk a5)
  create
  [ "$status" -eq 2 ]
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --disk "$P2_DISK_A")
  create
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"given more than once"* ]]
  no_disk_touched
}
