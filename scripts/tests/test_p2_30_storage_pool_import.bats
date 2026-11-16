#!/usr/bin/env bats
#
# CS-2.1: node-manager/nixos-26/scripts/storage-pool-import with zpool shims.
# Proves: the plain "import -N -d /dev/disk/by-id" and nothing else (never -f,
# never -m, never create), the already-imported path, the absent-pool refusal
# with the listing on stderr, argument validation before any command.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-30.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zpool
  SCRIPT="$S/storage-pool-import"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "no argument and a second pool are usage errors (2) and run nothing" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab other
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" -f lab
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a bad pool name is refused (3) before any command" {
  run bash "$SCRIPT" 'Lab;x'
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "imports with -N -d /dev/disk/by-id, then status and health/size/allocated" {
  printf '   pool: lab\n     id: 1\n' > "$STATE/import-listing"
  run bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  grep -qxF 'zpool import -N -d /dev/disk/by-id lab' "$SHIM_LOG"
  grep -qxF 'zpool status lab' "$SHIM_LOG"
  grep -qxF 'zpool get -H health,size,allocated lab' "$SHIM_LOG"
}

@test "never forces, never discards a log, never creates" {
  printf '   pool: lab\n' > "$STATE/import-listing"
  run bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  run ! grep -E 'zpool import .*( -f| -m)' "$SHIM_LOG"
  run ! grep -E '^(zpool create|zfs create|zpool destroy|zpool labelclear|wipefs)' "$SHIM_LOG"
}

@test "an import that fails is not retried with force" {
  printf '   pool: lab\n' > "$STATE/import-listing"
  touch "$STATE/import-fail"
  run bash "$SCRIPT" lab
  [ "$status" -ne 0 ]
  [ "$(grep -c '^zpool import -N' "$SHIM_LOG")" -eq 1 ]
  run ! grep -E 'zpool import .*( -f| -m)' "$SHIM_LOG"
}

@test "already imported: status, exit 0, no import" {
  touch "$STATE/pool-imported"
  run bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  grep -qxF 'zpool status lab' "$SHIM_LOG"
  run ! grep -q '^zpool import' "$SHIM_LOG"
}

@test "pool absent: exit 3 with the zpool import listing on stderr" {
  printf '   pool: other\n     id: 9\n' > "$STATE/import-listing"
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"pool: other"* ]]
  run ! grep -q '^zpool import -N' "$SHIM_LOG"
}

@test "every command is logged as it runs" {
  printf '   pool: lab\n' > "$STATE/import-listing"
  run --separate-stderr bash "$SCRIPT" lab
  [[ "$stderr" == *"+ zpool import -N -d /dev/disk/by-id lab"* ]]
  [[ "$stderr" == *"+ zpool status lab"* ]]
}
