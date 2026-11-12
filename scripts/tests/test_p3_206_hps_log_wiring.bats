#!/usr/bin/env bats
#
# Wiring of hps-log (docs/LOGGING.md): an ips-admin tool, open in the gate for
# its two read verbs only, named by hps-op and OPERATOR.md. The reading itself
# is t/206-hps-log.t.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-206.XXXXXX")"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  printf 'HPS_SYSTEM_BASE=%s\n' "$TEST_DIR/sys" > "$TEST_DIR/hps.conf"
  printf '#!/bin/bash\necho "tool=${0##*/} args=$*"\n' > "$TEST_DIR/sys/bin/hps-log"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/sys/bin/hps-log" "$TEST_DIR/bin/logger"
}

teardown() {
  rm -rf "$TEST_DIR"
}

gate() {
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-log" "$@"
}

@test "hps-log is an ips-admin tool: allowlisted, a wrapper, named by hps-op and OPERATOR.md" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [[ " ${IPS_ADMIN_SCRIPTS[*]} " == *" hps-log "* ]]
  [[ " ${IPS_ADMIN_RAW_SCRIPTS[*]} " != *" hps-log "* ]]
  [ -x "$ROOT/ips-admin/hps-log" ]
  grep -qxF 'exec "${0%/*}/ips-admin-exec" hps-log "$@"' "$ROOT/ips-admin/hps-log"
  grep -q 'hps-log' "$ROOT/bin/hps-op"
  grep -q '^| `hps-log` | `bin/hps-log` | `host`, `ips`' "$ROOT/docs/OPERATOR.md"
  [ -x "$ROOT/bin/hps-log" ]
}

@test "the ips-admin gate: hps-log host and ips pass with their options" {
  gate host 52:54:00:02:d3:ca --lines 50 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-log args=host 52:54:00:02:d3:ca --lines 50 --json"* ]]
  gate host cnh-001 --since 60 --grep space
  [ "$status" -eq 0 ]
  gate ips --lines 500
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-log args=ips --lines 500"* ]]
}

@test "the ips-admin gate: any other hps-log verb, or a path, is refused" {
  gate
  [ "$status" -eq 2 ]
  gate tail cnh-001
  [ "$status" -eq 2 ]
  [[ "$output" == *"only host and ips"* ]]
  gate --json host cnh-001
  [ "$status" -eq 2 ]
  gate host ../../etc/passwd
  [ "$status" -eq 2 ]
  gate host 'a b'
  [ "$status" -eq 2 ]
  [[ "$output" != *"tool="* ]]
}
