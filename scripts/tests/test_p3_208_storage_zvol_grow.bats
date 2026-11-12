#!/usr/bin/env bats
#
# storage-zvol-grow: grows an existing zvol under <pool>/enc (zfs set volsize),
# never shrinks, refuses an unknown dataset or a non-zvol, and a locked parent.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p2_70_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-208.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zfs_zvol
  SCRIPT="$S/storage-zvol-grow"
  echo available > "$STATE/keystatus"
  echo "lab/enc/vm/s1-cnh-d0 $((20 << 30))" > "$STATE/zvols"
  echo "lab/enc/vm" > "$STATE/datasets"
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

@test "grows: zfs set volsize after the keystatus check, read back, both sizes reported" {
  run --separate-stderr bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 64G
  [ "$status" -eq 0 ]
  grep -qxF 'zfs set volsize=64G lab/enc/vm/s1-cnh-d0' "$SHIM_LOG"
  [ "$output" = "ZVOL lab/enc/vm/s1-cnh-d0 volsize=$((64 << 30)) was=$((20 << 30))" ]
  [[ "$stderr" == *"+ zfs set volsize=64G lab/enc/vm/s1-cnh-d0"* ]]
  local k s
  k=$(grep -n 'keystatus' "$SHIM_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n '^zfs set' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$k" -lt "$s" ]
  grep -q "lab/enc/vm/s1-cnh-d0 $((64 << 30))" "$STATE/zvols"
}

@test "the same size is nothing to do (0), no set" {
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 20G
  [ "$status" -eq 0 ]
  [[ "$output" == *"already 20G; nothing to do"* ]]
  run ! grep -q '^zfs set' "$SHIM_LOG"
}

@test "a smaller size is refused (3): a zvol is never shrunk" {
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 19G
  [ "$status" -eq 3 ]
  [[ "$output" == *"would shrink it"* ]]
  run ! grep -q '^zfs set' "$SHIM_LOG"
  grep -q "lab/enc/vm/s1-cnh-d0 $((20 << 30))" "$STATE/zvols"
}

@test "an unknown dataset, or one that is not a zvol, is refused (3)" {
  run bash "$SCRIPT" lab/enc/vm/nosuch 64G
  [ "$status" -eq 3 ]
  [[ "$output" == *"does not exist"* ]]
  echo "lab/enc/fs0" >> "$STATE/datasets"
  run bash "$SCRIPT" lab/enc/fs0 64G
  [ "$status" -eq 3 ]
  [[ "$output" == *"is a filesystem, not a zvol"* ]]
  run ! grep -q '^zfs set' "$SHIM_LOG"
}

@test "a locked parent is refused (3) before anything is read or set" {
  echo unavailable > "$STATE/keystatus"
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 64G
  [ "$status" -eq 3 ]
  [[ "$output" == *"not unlocked"* ]]
  run ! grep -q 'volsize' "$SHIM_LOG"
}

@test "datasets and sizes are checked like storage-zvol-create, before any command" {
  local d
  for d in lab lab/enc lab/t0 lab/enc/a/b Lab/enc/t0 'lab/enc/t0;x' lab/other/t0 /lab/enc/t0 'lab/enc/../x'; do
    run bash "$SCRIPT" "$d" 64G
    [ "$status" -eq 3 ]
  done
  for d in 0G 64g 1.5G 64 8K; do
    run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 "$d"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 64G extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force lab/enc/vm/s1-cnh-d0 64G
  [ "$status" -eq 2 ]
}

@test "a failing zfs set fails the run (1)" {
  export FAKE_ZFS_SET_RC=1
  run bash "$SCRIPT" lab/enc/vm/s1-cnh-d0 64G
  [ "$status" -eq 1 ]
}
