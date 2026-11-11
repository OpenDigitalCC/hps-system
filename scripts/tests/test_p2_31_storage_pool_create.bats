#!/usr/bin/env bats
#
# CS-2.1: storage-pool-create. Real openssl signs the approvals; zpool, zfs,
# lsblk, blkid, zdb, wipefs, readlink and xxd are shims. Proves every approval
# refusal (bad HMAC, expired, wrong mac, wrong pool, wrong action, wrong disks,
# extra field), every disk refusal (signature without wipe, partition, mounted,
# holder, missing, member of an imported pool), wipe only with wipe=1 and only
# on the approved by-id devices, the exact zpool create flags, the encrypted
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
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --approval-file -)
}

teardown() {
  rm -rf "$TEST_DIR"
}

# create <payload>: run the script with the payload on stdin.
create() {
  run --separate-stderr bash "$SCRIPT" "${ARGS[@]}" <<< "$1"
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
  run bash "$SCRIPT" lab --disk "$P2_DISK_A" --approval-file -
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab --disk "$P2_DISK_A" --disk "$P2_DISK_B"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a pool name or disk that is not a plain name is refused (3)" {
  run bash "$SCRIPT" 'a b' --disk x --disk y --approval-file -
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" lab --disk '../x' --disk y --approval-file - <<< '{}'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" lab --disk x --disk x --approval-file - <<< '{}'
  [ "$status" -eq 3 ]
}

fixture_payload() {
  jq -n -c --slurpfile a "$FIX/approval-canonical.json" --rawfile h "$FIX/approval-canonical.hmac" --rawfile s "$FIX/approval-canonical.secret.hex" --arg k "$P2_KEY" \
    '{approval:($a[0] + {hmac:($h|rtrimstr("\n"))}),secret:($s|rtrimstr("\n")),key_hex:$k}'
}

@test "the CS-2.2 fixture (t/fixtures) verifies and creates" {
  echo "hps.mac=52:54:00:00:00:01" > "$HPS_CMDLINE"
  ARGS=(lab --disk ata-FAKE_1 --disk ata-FAKE_2 --approval-file -)
  create "$(fixture_payload)"
  [ "$status" -eq 0 ]
  grep -q '^zpool create ' "$SHIM_LOG"
}

@test "the CS-2.2 fixture with one byte changed is refused" {
  echo "hps.mac=52:54:00:00:00:01" > "$HPS_CMDLINE"
  ARGS=(lab --disk ata-FAKE_1 --disk ata-FAKE_2 --approval-file -)
  create "$(fixture_payload | sed 's/"issued_by":"operator"/"issued_by":"operatoR"/')"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"HMAC"* ]]
  create "$(fixture_payload | sed 's/3f4e57c8/3f4e57c9/')"
  [ "$status" -eq 3 ]
  run ! grep -q '^zpool create ' "$SHIM_LOG"
}

@test "the fixture bytes are canonical (jq -S -c identical)" {
  run jq -S -c . "$FIX/approval-canonical.json"
  [ "$output" = "$(cat "$FIX/approval-canonical.json")" ]
}

@test "bad HMAC is refused (3) and touches no disk" {
  local p
  p=$(p2_create_payload 0 | jq -c '.approval.hmac = ("0" * 64)')
  create "$p"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"HMAC"* ]]
  no_disk_touched
}

@test "an approval altered after signing (wipe flipped) is refused" {
  local p
  p=$(p2_create_payload 0 | jq -c '.approval.wipe = 1')
  create "$p"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"HMAC"* ]]
}

@test "a wrong approval key is refused" {
  local p
  p=$(p2_create_payload 0 | jq -c '.secret = ("ff" * 32)')
  create "$p"
  [ "$status" -eq 3 ]
}

@test "expired approval is refused" {
  create "$(p2_create_payload 0 1000000000)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"expired"* ]]
  no_disk_touched
}

@test "an approval for another node's mac is refused" {
  create "$(p2_create_payload 0 4102444800 112233445566)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different node"* ]]
  no_disk_touched
}

@test "mac is compared case- and colon-insensitively with hps.mac" {
  create "$(p2_create_payload 0 4102444800 AABBCCDDEEFF)"
  [ "$status" -eq 0 ]
}

@test "a missing hps.mac on the command line is refused" {
  echo "console=ttyS0" > "$HPS_CMDLINE"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
}

@test "an approval for another pool is refused" {
  create "$(p2_create_payload 0 4102444800 aabbccddeeff other)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different pool"* ]]
}

@test "a pool-destroy approval cannot create" {
  create "$(p2_destroy_payload lab '["ata-DISK-A","ata-DISK-B"]')"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not pool-create"* ]]
  no_disk_touched
}

@test "an approval naming different disks is refused" {
  create "$(p2_payload "$(p2_approval pool-create lab 0 4102444800 aabbccddeeff '["ata-DISK-A","ata-DISK-C"]')")"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different disks"* ]]
  no_disk_touched
}

@test "disk order in the arguments does not matter (sorted comparison)" {
  ARGS=(lab --disk "$P2_DISK_B" --disk "$P2_DISK_A" --approval-file -)
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
}

@test "an approval with an extra or a missing field is refused" {
  create "$(p2_create_payload 0 | jq -c '.approval.extra = 1')"
  [ "$status" -eq 3 ]
  create "$(p2_create_payload 0 | jq -c 'del(.approval.issued_by)')"
  [ "$status" -eq 3 ]
}

@test "garbage input is refused (3)" {
  create "not json"
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "a key_hex that is not 64 hex is refused before any disk is touched" {
  create "$(p2_payload "$(p2_approval pool-create lab 0 4102444800 aabbccddeeff '["ata-DISK-A","ata-DISK-B"]')" abcd)"
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "a disk that does not exist under /dev/disk/by-id is refused" {
  touch "$STATE/missing.$P2_DISK_B"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"does not exist"* ]]
  no_disk_touched
}

@test "a partition is refused" {
  printf 'part \n' > "$STATE/lsblk.$P2_DISK_A"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not a whole disk"* ]]
  no_disk_touched
}

@test "a disk with a mounted partition is refused, even with wipe=1" {
  printf 'disk \npart /srv\n' > "$STATE/lsblk.$P2_DISK_A"
  create "$(p2_create_payload 1)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"mounted"* ]]
  no_disk_touched
}

@test "a disk with a holder (lvm) is refused, even with wipe=1" {
  printf 'disk \npart \nlvm \n' > "$STATE/lsblk.$P2_DISK_A"
  create "$(p2_create_payload 1)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"holder"* ]]
  no_disk_touched
}

@test "a disk that belongs to an imported pool is refused, even with wipe=1" {
  echo "	/dev/disk/by-id/$P2_DISK_A-part1  ONLINE 0 0 0" > "$STATE/status-all"
  touch "$STATE/blkid.$P2_DISK_A"
  create "$(p2_create_payload 1)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"imported pool"* ]]
  no_disk_touched
}

@test "a filesystem signature without wipe is refused and nothing is erased" {
  touch "$STATE/blkid.$P2_DISK_B"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"does not allow wipe"* ]]
  no_disk_touched
}

@test "a ZFS label (zdb) without wipe is refused" {
  touch "$STATE/zdb.$P2_DISK_A"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "a pool in the zpool import listing on the disk without wipe is refused" {
  printf '   pool: zp03\n\tmirror-0\n\t  %s ONLINE\n' "$P2_DISK_A" > "$STATE/import-listing"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  no_disk_touched
}

@test "wipe=1 prints WILL WIPE for the approved devices and wipes exactly those" {
  touch "$STATE/blkid.$P2_DISK_A"
  touch "$STATE/zdb.$P2_DISK_B"
  create "$(p2_create_payload 1)"
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

@test "wipe=0 on clean disks wipes nothing" {
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
  run ! grep -E '^(wipefs|zpool labelclear)' "$SHIM_LOG"
  [[ "$stderr" != *"WILL WIPE"* ]]
}

@test "zpool create has exactly the approved flags and the by-id paths" {
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
  grep -qxF "zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none lab mirror /dev/disk/by-id/$P2_DISK_A /dev/disk/by-id/$P2_DISK_B" "$SHIM_LOG"
  run ! grep -E '^zpool create .* -f' "$SHIM_LOG"
  [[ "$stderr" == *"using /dev/disk/by-id/$P2_DISK_A"* ]]
}

@test "the encrypted parent is created with the key on stdin only" {
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
  grep -qxF "zfs create -o encryption=aes-256-gcm -o keyformat=raw -o keylocation=prompt lab/enc" "$SHIM_LOG"
  # the 32 raw bytes reached zfs on stdin
  [ "$(wc -c < "$STATE/stdin.create")" -eq 32 ]
  [ "$(perl -0777 -ne 'print unpack("H*",$_)' < "$STATE/stdin.create")" = "$P2_KEY" ]
  # pool create comes before the dataset, key still loaded: no unload-key
  run ! grep -q 'unload-key' "$SHIM_LOG"
}

@test "neither the key nor the approval key appears in any logged command, stderr or file the script wrote" {
  create "$(p2_create_payload 1)"
  [ "$status" -eq 0 ]
  run ! grep -F "$P2_KEY" "$SHIM_LOG"
  run ! grep -F "$P2_SECRET" "$SHIM_LOG"
  [[ "$stderr" != *"$P2_KEY"* ]]
  [[ "$stderr" != *"$P2_SECRET"* ]]
  [[ "$output" != *"$P2_KEY"* ]]
  run ! grep -rlF "$P2_KEY" "$TMPDIR" "$WORK"
  run ! grep -rlF "$P2_SECRET" "$TMPDIR" "$WORK"
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
}

@test "the approval may come from a file (manual console use)" {
  p2_create_payload 0 > "$WORK/approval.json"
  run --separate-stderr bash "$SCRIPT" lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --approval-file "$WORK/approval.json"
  [ "$status" -eq 0 ]
  grep -q '^zpool create ' "$SHIM_LOG"
}

@test "second run with the pool on the same disks and lab/enc present is a no-op (0) after status" {
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  : > "$SHIM_LOG"
  create "$(p2_create_payload 1)"
  [ "$status" -eq 0 ]
  run ! grep -E '^(zpool create|zfs create|wipefs|zpool labelclear)' "$SHIM_LOG"
  grep -qxF 'zpool status lab' "$SHIM_LOG"
}

@test "the pool present on other disks is refused" {
  touch "$STATE/pool-imported"
  printf '\t/dev/disk/by-id/ata-OTHER-1  ONLINE\n\t/dev/disk/by-id/ata-OTHER-2  ONLINE\n' > "$STATE/status-pool"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different disks"* ]]
  no_disk_touched
}

@test "the pool present on the same disks but without lab/enc gets only the dataset" {
  touch "$STATE/pool-imported"
  printf '\t/dev/disk/by-id/%s-part1  ONLINE\n\t/dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  create "$(p2_create_payload 0)"
  [ "$status" -eq 0 ]
  run ! grep -E '^(zpool create|wipefs|zpool labelclear)' "$SHIM_LOG"
  grep -q '^zfs create .* lab/enc$' "$SHIM_LOG"
}

@test "every command is logged as it runs" {
  create "$(p2_create_payload 0)"
  [[ "$stderr" == *"+ zpool create "* ]]
  [[ "$stderr" == *"+ zfs create "* ]]
  [[ "$stderr" == *"+ zpool status lab"* ]]
}

@test "a three-way mirror: three approved disks, one mirror of all three (owner 2026-11-11)" {
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --disk ata-DISK-C --approval-file -)
  create "$(p2_payload "$(p2_approval pool-create lab 0 4102444800 aabbccddeeff '["ata-DISK-A","ata-DISK-B","ata-DISK-C"]')")"
  [ "$status" -eq 0 ]
  grep -qxF "zpool create -o ashift=12 -o autotrim=on -O compression=lz4 -O atime=off -O xattr=sa -O mountpoint=none lab mirror /dev/disk/by-id/$P2_DISK_A /dev/disk/by-id/$P2_DISK_B /dev/disk/by-id/ata-DISK-C" "$SHIM_LOG"
}

@test "one disk, or five, is a usage error; a disk given twice is refused; nothing is touched" {
  ARGS=(lab --disk a1 --disk a2 --disk a3 --disk a4 --disk a5 --approval-file -)
  create "$(p2_create_payload 0)"
  [ "$status" -eq 2 ]
  ARGS=(lab --disk "$P2_DISK_A" --disk "$P2_DISK_B" --disk "$P2_DISK_A" --approval-file -)
  create "$(p2_create_payload 0)"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"given more than once"* ]]
  no_disk_touched
}
