#!/usr/bin/env bats
#
# CS-2.5: storage-status and storage-zvol-list. Proves: read-only (no import,
# create, destroy, set, load-key, targetcli change), the sections shown, the
# refusal for a pool that is not imported, argument checks.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p2_70_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-72.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zpool
  p2_shim_zfs_zvol
  p2_shim_targetcli
  echo available > "$STATE/keystatus"
  echo "lab/enc/t0 1073741824" > "$STATE/zvols"
  printf '  pool: lab\n state: ONLINE\n' > "$STATE/status-pool"
  touch "$STATE/pool-imported"
}

teardown() {
  rm -rf "$TEST_DIR"
}

no_changes() {
  run ! grep -E '^(zpool (import|export|create|destroy|trim|labelclear)|zfs (create|destroy|set|load-key|unload-key|mount|rollback)|targetcli (saveconfig|/[^ ]+ (create|delete)))' "$SHIM_LOG"
}

@test "both are executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  local f
  for f in storage-status storage-zvol-list; do
    [ -x "$S/$f" ]
    [ "$(head -1 "$S/$f")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$S/$f"
    grep -q '^run() {' "$S/$f"
    shellcheck -S warning "$S/$f"
  done
}

@test "usage: wrong argument counts exit 2, a bad pool name 3, nothing runs" {
  local f
  for f in storage-status storage-zvol-list; do
    run bash "$S/$f"
    [ "$status" -eq 2 ]
    run bash "$S/$f" lab extra
    [ "$status" -eq 2 ]
    run bash "$S/$f" --all
    [ "$status" -eq 2 ]
    run bash "$S/$f" 'Lab;x'
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "storage-status shows pool, keystatus, zvols and exports, and changes nothing" {
  targetcli /backstores/block create lab_enc_t0 /dev/zvol/lab/enc/t0
  : > "$SHIM_LOG"
  run --separate-stderr bash "$S/storage-status" lab
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== pool ==="* ]]
  [[ "$output" == *"state: ONLINE"* ]]
  [[ "$output" == *"lab"*"keystatus"*"available"* ]]
  [[ "$output" == *"lab/enc/t0"* ]]
  [[ "$output" == *"=== exports ==="* ]]
  [[ "$output" == *"lab_enc_t0"* ]]
  grep -qxF 'zpool status lab' "$SHIM_LOG"
  grep -qxF 'zfs get -H keystatus lab/enc' "$SHIM_LOG"
  grep -qxF 'zfs list -t volume -r -o name,volsize,used,referenced lab' "$SHIM_LOG"
  [[ "$stderr" == *"+ zpool status lab"* ]]
  no_changes
}

@test "storage-status on a locked parent reports it (exit 0)" {
  echo unavailable > "$STATE/keystatus"
  run bash "$S/storage-status" lab
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
}

@test "a pool that is not imported is refused (3) and is not imported by the call" {
  rm -f "$STATE/pool-imported"
  local f
  for f in storage-status storage-zvol-list; do
    run --separate-stderr bash "$S/$f" lab
    [ "$status" -eq 3 ]
    [[ "$stderr" == *"not imported"* ]]
  done
  no_changes
  [ ! -e "$STATE/pool-imported" ]
}

@test "storage-zvol-list lists the volumes of the pool and changes nothing" {
  run bash "$S/storage-zvol-list" lab
  [ "$status" -eq 0 ]
  [[ "$output" == *"lab/enc/t0"* ]]
  grep -qxF 'zfs list -t volume -r -o name,volsize,used,referenced lab' "$SHIM_LOG"
  no_changes
}
