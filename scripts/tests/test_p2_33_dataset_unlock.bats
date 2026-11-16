#!/usr/bin/env bats
#
# CS-2.1: dataset-unlock. Proves the key reaches zfs on stdin only (never an
# argument, never a file), a different loaded key is refused, the same key is a
# no-op exit 0, and bad input is refused before zfs is asked anything.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-33.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_xxd
  p2_shim_zfs
  SCRIPT="$S/dataset-unlock"
  echo lab/enc > "$STATE/datasets"
  OTHER=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
}

teardown() {
  rm -rf "$TEST_DIR"
}

unlock() {
  run --separate-stderr bash "$SCRIPT" lab/enc <<< "{\"key_hex\":\"$1\"}"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2, a bad dataset name 3; zfs is not asked" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 'lab;x/enc' <<< '{}'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" lab <<< '{}'
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "bad or missing key input is refused (3) before zfs is asked" {
  unlock "abcd"
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$SCRIPT" lab/enc <<< 'not json'
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$SCRIPT" lab/enc <<< ''
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a dataset that does not exist is refused" {
  : > "$STATE/datasets"
  unlock "$P2_KEY"
  [ "$status" -eq 3 ]
  run ! grep -q 'load-key' "$SHIM_LOG"
}

@test "locked: load-key -L prompt with the raw key on stdin, then mount -a" {
  echo unavailable > "$STATE/keystatus"
  unlock "$P2_KEY"
  [ "$status" -eq 0 ]
  grep -qxF 'zfs load-key -L prompt lab/enc' "$SHIM_LOG"
  grep -qxF 'zfs mount -a' "$SHIM_LOG"
  [ "$(perl -0777 -ne 'print unpack("H*",$_)' < "$STATE/stdin.load-key")" = "$P2_KEY" ]
}

@test "a different key already loaded is refused (3) and nothing is mounted" {
  unlock "$P2_KEY"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  unlock "$OTHER"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different key"* ]]
  grep -qxF 'zfs load-key -n -L prompt lab/enc' "$SHIM_LOG"
  run ! grep -qxF 'zfs load-key -L prompt lab/enc' "$SHIM_LOG"
  run ! grep -q 'mount' "$SHIM_LOG"
}

@test "the same key already loaded is exit 0 (dry-run check, no second load)" {
  unlock "$P2_KEY"
  : > "$SHIM_LOG"
  unlock "$P2_KEY"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already unlocked"* ]]
  grep -qxF 'zfs load-key -n -L prompt lab/enc' "$SHIM_LOG"
  run ! grep -qxF 'zfs load-key -L prompt lab/enc' "$SHIM_LOG"
}

@test "an unencrypted dataset (keystatus -) is refused" {
  echo - > "$STATE/keystatus"
  unlock "$P2_KEY"
  [ "$status" -eq 3 ]
}

@test "the key is never on a command line, in a log, in stderr or in any file the script wrote" {
  unlock "$P2_KEY"
  [ "$status" -eq 0 ]
  run ! grep -F "$P2_KEY" "$SHIM_LOG"
  [[ "$stderr" != *"$P2_KEY"* ]]
  [[ "$output" != *"$P2_KEY"* ]]
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
  run ! grep -rlF "$P2_KEY" "$TMPDIR" "$WORK"
}
