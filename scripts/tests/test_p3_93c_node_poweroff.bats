#!/usr/bin/env bats
#
# IPS-04: node-poweroff queues a poweroff; systemd-run and systemctl are shims.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/node-poweroff"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-93c.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  : > "$SHIM_LOG"
  mkdir -p "$TEST_DIR/bin"
  export PATH="$TEST_DIR/bin:$PATH"
  cat > "$TEST_DIR/bin/systemd-run" <<'SHIM'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$SHIM_LOG"
exit "${FAKE_RUN_RC:-0}"
SHIM
  cat > "$TEST_DIR/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SHIM_LOG"
exit "${FAKE_CTL_RC:-0}"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "queues a timed systemctl poweroff, does not power off inline" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "poweroff queued" ]
  grep -qxF 'systemd-run --unit=hps-node-poweroff --on-active=3s systemctl poweroff' "$SHIM_LOG"
  run ! grep -q '^systemctl' "$SHIM_LOG"
}

@test "--delay sets the timer" {
  run bash "$SCRIPT" --delay 10
  [ "$status" -eq 0 ]
  grep -q -- '--on-active=10s' "$SHIM_LOG"
}

@test "bad arguments are usage errors (2) and queue nothing" {
  run bash "$SCRIPT" --delay abc
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --delay 61
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --delay
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" now
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "when the timer cannot be made it falls back to a non-blocking poweroff" {
  FAKE_RUN_RC=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF 'systemctl poweroff --no-block' "$SHIM_LOG"
}

@test "when both fail the exit is non-zero" {
  FAKE_RUN_RC=1 FAKE_CTL_RC=1 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
