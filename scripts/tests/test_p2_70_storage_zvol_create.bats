#!/usr/bin/env bats
#
# CS-2.5: storage-zvol-create. Proves: argument and name refusals before any
# command runs, a locked parent is never written, the exact zfs create, and
# idempotency (same size exits 0 with no change, a different size or a non-zvol
# is refused).

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p2_70_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-70.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zfs_zvol
  SCRIPT="$S/storage-zvol-create"
  echo available > "$STATE/keystatus"
  : > "$STATE/zvols"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "wrong argument counts and options exit 2, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/t0
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/t0 1G extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force lab/enc/t0 1G
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/t0 -1G
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "datasets outside <pool>/enc/<name> are refused (3) before any command" {
  local d
  for d in lab lab/enc lab/t0 lab/enc/a/b Lab/enc/t0 'lab/enc/t0;x' 'lab/enc/t 0' lab/other/t0 /lab/enc/t0 'lab/enc/../x'; do
    run bash "$SCRIPT" "$d" 1G
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "<pool>/enc/vm/<name> is accepted; the vm parent is created first when absent, logged" {
  run --separate-stderr bash "$SCRIPT" lab/enc/vm/t0-app-root 1G
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"creating lab/enc/vm (inherits the encryption of lab/enc)"* ]]
  grep -qxF 'zfs create lab/enc/vm' "$SHIM_LOG"
  grep -qxF 'zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 lab/enc/vm/t0-app-root' "$SHIM_LOG"
  local k p c
  k=$(grep -n 'keystatus' "$SHIM_LOG" | head -1 | cut -d: -f1)
  p=$(grep -n '^zfs create lab/enc/vm$' "$SHIM_LOG" | head -1 | cut -d: -f1)
  c=$(grep -n '^zfs create -V' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$k" -lt "$p" ]
  [ "$p" -lt "$c" ]
}

@test "an existing lab/enc/vm is not created again" {
  echo lab/enc/vm > "$STATE/datasets"
  run bash "$SCRIPT" lab/enc/vm/t1 1G
  [ "$status" -eq 0 ]
  run ! grep -qxF 'zfs create lab/enc/vm' "$SHIM_LOG"
  grep -q '^zfs create -V' "$SHIM_LOG"
}

@test "the plain form never creates a vm parent; a locked parent blocks the vm form too" {
  run bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 0 ]
  run ! grep -qxF 'zfs create lab/enc/vm' "$SHIM_LOG"
  : > "$SHIM_LOG"
  echo unavailable > "$STATE/keystatus"
  run bash "$SCRIPT" lab/enc/vm/t2 1G
  [ "$status" -eq 3 ]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "vm form refusals: deeper nesting, empty name, vm itself as a zvol name is a plain name" {
  local d
  for d in lab/enc/vm/ lab/enc/vm/a/b lab/enc/vm//x lab/vm/t0 'lab/enc/vm/t 0'; do
    run bash "$SCRIPT" "$d" 1G
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "bad sizes are refused (3) before any command" {
  local s
  for s in 1 1X 0G 00K 1g '1 G' G 1.5G 8K 1000K 99999999999999G; do
    run bash "$SCRIPT" lab/enc/t0 "$s"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "a locked parent is never written to" {
  echo unavailable > "$STATE/keystatus"
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not unlocked"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
  grep -qxF 'zfs get -H -o value keystatus lab/enc' "$SHIM_LOG"
}

@test "creates a sparse 16k lz4 zvol with the exact command, logged" {
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 0 ]
  grep -qxF 'zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 lab/enc/t0' "$SHIM_LOG"
  [[ "$stderr" == *"+ zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 lab/enc/t0"* ]]
  # keystatus was read before the create
  local k c
  k=$(grep -n 'keystatus' "$SHIM_LOG" | head -1 | cut -d: -f1)
  c=$(grep -n '^zfs create' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$k" -lt "$c" ]
}

@test "no -f, destroy, rollback or set anywhere in the script" {
  run ! grep -E 'zfs (destroy|rollback|set|rename)|zpool ' "$SCRIPT"
}

@test "same size again: exit 0, no second create" {
  run bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already exists"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "a different size is refused (3), the zvol is not touched" {
  run bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 2G
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different size"* ]]
  run ! grep -E '^zfs (create|destroy|set)' "$SHIM_LOG"
}

@test "an existing dataset that is not a zvol is refused (3)" {
  echo lab/enc/t0 > "$STATE/datasets"
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"filesystem"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "a failing zfs create exits 1" {
  FAKE_ZFS_CREATE_RC=1 run bash "$SCRIPT" lab/enc/t0 1G
  [ "$status" -eq 1 ]
}

@test "units: 512M and 2T are accepted" {
  run bash "$SCRIPT" lab/enc/m0 512M
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" lab/enc/big 2T
  [ "$status" -eq 0 ]
  grep -qxF 'zfs create -V 512M -s -o volblocksize=16k -o compression=lz4 lab/enc/m0' "$SHIM_LOG"
  grep -qxF 'zfs create -V 2T -s -o volblocksize=16k -o compression=lz4 lab/enc/big' "$SHIM_LOG"
}
