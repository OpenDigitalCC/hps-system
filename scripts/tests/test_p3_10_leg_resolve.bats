#!/usr/bin/env bats
#
# CS-3.2: leg-resolve. Local vs remote legs, idempotent login, the timeout.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-10.XXXXXX")"
  export TEST_DIR
  p3_setup
  SCRIPT="$S/leg-resolve"
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

@test "usage errors exit 2; bad specs exit 3; nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" a b
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" nonsense
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 'local:lab/vm/x'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 'local:lab/enc/vm/../x'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 'iscsi:not-an-ip:iqn.2026-01.x:y'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 'iscsi:10.0.0.1:nonsense'
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "local leg: prints the zvol path, touches nothing" {
  p3_make_local
  run --separate-stderr bash "$SCRIPT" "$P3_LOC_SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "$LOCDEV" ]
  [ ! -s "$SHIM_LOG" ]
}

@test "local leg: a missing zvol is refused" {
  run bash "$SCRIPT" "$P3_LOC_SPEC"
  [ "$status" -eq 3 ]
}

@test "remote leg: discovery, login, settle, then the by-path device; stdout is the path only" {
  run --separate-stderr bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMDEV" ]
  grep -qxF 'iscsiadm -m discovery -t sendtargets -p 10.99.1.2' "$SHIM_LOG"
  grep -qxF 'iscsiadm -m node -T iqn.2026-01.hps.example:vm1-disk0 -p 10.99.1.2 --login' "$SHIM_LOG"
  grep -q '^udevadm settle' "$SHIM_LOG"
  [[ "$stderr" == *"+ iscsiadm -m discovery"* ]]
}

@test "remote leg: a second run logs in no second time" {
  run bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [ "$output" = "$REMDEV" ]
  run ! grep -E 'discovery|--login' "$SHIM_LOG"
}

@test "remote leg: a live session without the device is not logged in again, then waits" {
  echo "tcp: [1] 10.99.1.2:3260,1 iqn.2026-01.hps.example:vm1-disk0 (non-flash)" > "$STATE/sessions"
  touch "$STATE/nolun"
  run bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  run ! grep -E 'discovery|--login' "$SHIM_LOG"
}

@test "remote leg: the LUN never appears -> refused after the timeout" {
  touch "$STATE/nolun"
  run --separate-stderr bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"did not appear within 2s"* ]]
}

@test "remote leg: a failing login is a failed command" {
  FAKE_LOGIN_RC=8 run bash "$SCRIPT" "$P3_REM_SPEC"
  [ "$status" -eq 8 ]
}
