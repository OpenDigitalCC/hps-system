#!/usr/bin/env bats
#
# CS-2.1: storage-pool-destroy. Proves: nothing without a valid approval (HMAC,
# expiry, action, mac, pool, disks), the announce lines, the order (devices
# recorded -> export -> forced import -> destroy -> labelclear), that -f and -m
# appear here and only here, and that a refusal after the import exports again.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-32.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_xxd
  p2_shim_zpool
  SCRIPT="$S/storage-pool-destroy"
  printf '\tmirror-0\n\t  /dev/disk/by-id/%s-part1  ONLINE\n\t  /dev/disk/by-id/%s-part1  ONLINE\n\tlogs\n\t  mirror-1  UNAVAIL\n\t    12345678901234  UNAVAIL\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  printf '   pool: zp03\n' > "$STATE/import-listing"
}

teardown() {
  rm -rf "$TEST_DIR"
}

destroy() {
  run --separate-stderr bash "$SCRIPT" zp03 --approval-file - <<< "$1"
}

nothing_destroyed() {
  run ! grep -E '^(zpool destroy|zpool labelclear|zpool export|zpool import -f)' "$SHIM_LOG"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2, a bad name 3, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" zp03
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 'Z;P' --approval-file -
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "bad HMAC, expired, wrong mac, wrong pool, create-action approvals all refuse and destroy nothing" {
  local p
  p=$(p2_destroy_payload zp03 | jq -c '.approval.hmac = ("0" * 64)')
  destroy "$p"
  [ "$status" -eq 3 ]
  destroy "$(p2_payload "$(p2_approval pool-destroy zp03 0 1000000000 aabbccddeeff '[]')")"
  [ "$status" -eq 3 ]
  destroy "$(p2_payload "$(p2_approval pool-destroy zp03 0 4102444800 112233445566 '[]')")"
  [ "$status" -eq 3 ]
  destroy "$(p2_destroy_payload other)"
  [ "$status" -eq 3 ]
  destroy "$(p2_destroy_payload zp03 '[]' pool-create)"
  [ "$status" -eq 3 ]
  nothing_destroyed
  [ ! -s "$SHIM_LOG" ]
}

@test "garbage input and no input are refused" {
  destroy "nonsense"
  [ "$status" -eq 3 ]
  destroy ""
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "imported pool: devices recorded, announced, exported, force-imported, destroyed, labels cleared" {
  touch "$STATE/pool-imported"
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WILL DESTROY: pool zp03"* ]]
  [[ "$stderr" == *"WILL DESTROY: device /dev/disk/by-id/$P2_DISK_A-part1"* ]]
  grep -qxF 'zpool export zp03' "$SHIM_LOG"
  grep -qxF 'zpool import -f -N -d /dev/disk/by-id zp03' "$SHIM_LOG"
  grep -qxF 'zpool destroy zp03' "$SHIM_LOG"
  grep -qxF "zpool labelclear -f /dev/disk/by-id/$P2_DISK_A-part1" "$SHIM_LOG"
  grep -qxF "zpool labelclear -f /dev/disk/by-id/$P2_DISK_B-part1" "$SHIM_LOG"
  # order
  local e i d
  e=$(grep -n '^zpool export' "$SHIM_LOG" | head -1 | cut -d: -f1)
  i=$(grep -n '^zpool import -f' "$SHIM_LOG" | head -1 | cut -d: -f1)
  d=$(grep -n '^zpool destroy' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$e" -lt "$i" ]
  [ "$i" -lt "$d" ]
  # only the two by-id devices, not the missing log guid
  [ "$(grep -c '^zpool labelclear' "$SHIM_LOG")" -eq 2 ]
}

@test "exported pool: imported with -f -N, no export, destroyed" {
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 0 ]
  run ! grep -q '^zpool export' "$SHIM_LOG"
  grep -qxF 'zpool import -f -N -d /dev/disk/by-id zp03' "$SHIM_LOG"
  grep -qxF 'zpool destroy zp03' "$SHIM_LOG"
  run ! grep -E 'zpool import .* -m ' "$SHIM_LOG"
}

@test "-m only when the forced import alone fails (missing log), and only in destroy" {
  touch "$STATE/import-needs-m"
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 0 ]
  grep -qxF 'zpool import -f -N -d /dev/disk/by-id zp03' "$SHIM_LOG"
  grep -qxF 'zpool import -f -m -N -d /dev/disk/by-id zp03' "$SHIM_LOG"
  grep -qxF 'zpool destroy zp03' "$SHIM_LOG"
}

@test "an import that fails even with -m destroys nothing (exit 1)" {
  touch "$STATE/import-fail"
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 1 ]
  run ! grep -E '^(zpool destroy|zpool labelclear)' "$SHIM_LOG"
}

@test "a pool that is not importable and not imported: exit 3 with the listing" {
  printf '   pool: other\n' > "$STATE/import-listing"
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"pool: other"* ]]
  nothing_destroyed
}

@test "approved disks that differ from the pool's disks refuse, and the forced import is undone" {
  destroy "$(p2_destroy_payload zp03 '["ata-OTHER-1","ata-OTHER-2"]')"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not the pool's disks"* ]]
  run ! grep -E '^(zpool destroy|zpool labelclear)' "$SHIM_LOG"
  [ ! -e "$STATE/pool-imported" ]
}

@test "approved disks that match the pool's disks proceed" {
  destroy "$(p2_destroy_payload zp03 "[\"$P2_DISK_A\",\"$P2_DISK_B\"]")"
  [ "$status" -eq 0 ]
  grep -qxF 'zpool destroy zp03' "$SHIM_LOG"
}

@test "the approval key never appears in the log or in files" {
  destroy "$(p2_destroy_payload zp03)"
  [ "$status" -eq 0 ]
  run ! grep -F "$P2_SECRET" "$SHIM_LOG"
  [[ "$stderr" != *"$P2_SECRET"* ]]
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
}

@test "no node script other than destroy uses zpool import -f or -m, or destroys" {
  local f
  for f in storage-pool-import storage-pool-create dataset-unlock storage-trim-check iscsi-export iscsi-unexport iscsi-status storage-disks node-facts node-dmesg; do
    run ! grep -E 'zpool (import .* -[fm]\b|destroy)' "$S/$f"
  done
}
