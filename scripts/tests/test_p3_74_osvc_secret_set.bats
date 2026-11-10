#!/usr/bin/env bats
#
# CS-3.5: osvc-secret-set - the cluster secret arrives on stdin, is stored
# root-only in RAM, is never argument or output, and restarts the daemon.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-74.XXXXXX")"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/osvc-secret-set"
  export HPS_RUN_DIR="$T/run/hps"
  export SHIM_LOG="$T/shim.log"
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\necho "systemctl $*" >> "$SHIM_LOG"\nexit "${FAKE_SYSTEMCTL_RC:-0}"\n' > "$T/bin/systemctl"
  chmod +x "$T/bin/systemctl"
  export PATH="$T/bin:$PATH"
  SECRET="$(printf 'cd%.0s' {1..16})"
}

teardown() {
  rm -rf "$T"
}

@test "the secret is stored mode 0600 and opensvc-daemon is restarted" {
  run -0 bash "$SCRIPT" <<< "$SECRET"
  [ "$(cat "$HPS_RUN_DIR/osvc-cluster-secret")" = "$SECRET" ]
  [ "$(stat -c %a "$HPS_RUN_DIR/osvc-cluster-secret")" = 600 ]
  grep -qx 'systemctl restart opensvc-daemon.service' "$SHIM_LOG"
}

@test "the secret is in no output and no logged command" {
  run -0 bash "$SCRIPT" <<< "$SECRET"
  [[ "$output" != *"$SECRET"* ]]
  run ! grep -q "$SECRET" "$SHIM_LOG"
}

@test "anything but exactly 32 lower-case hex digits (a 64-digit value is not an AES key size) is refused (3) and stores nothing" {
  local v
  for v in "" "abc" "ABCDEF0123456789ABCDEF0123456789" "$SECRET;rm" "$SECRET$SECRET" "${SECRET:1}" "${SECRET}a"; do
    run -3 bash "$SCRIPT" <<< "$v"
    [ ! -e "$HPS_RUN_DIR/osvc-cluster-secret" ]
  done
  [ ! -e "$SHIM_LOG" ]
}

@test "an argument is a usage error (2)" {
  run -2 bash "$SCRIPT" "$SECRET" <<< "$SECRET"
  [ ! -e "$HPS_RUN_DIR/osvc-cluster-secret" ]
}

@test "a unit that fails to restart is exit 1" {
  FAKE_SYSTEMCTL_RC=1 run -1 bash "$SCRIPT" <<< "$SECRET"
}

@test "a second delivery replaces the first" {
  run -0 bash "$SCRIPT" <<< "$SECRET"
  run -0 bash "$SCRIPT" <<< "$(printf 'ef%.0s' {1..16})"
  [ "$(cat "$HPS_RUN_DIR/osvc-cluster-secret")" = "$(printf 'ef%.0s' {1..16})" ]
}
