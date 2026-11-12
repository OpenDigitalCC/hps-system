#!/usr/bin/env bats
#
# Wiring of hps-metrics (docs/MONITORING.md): an ips-admin tool, open in the
# gate for its two read verbs only, named by hps-op and OPERATOR.md. The reading
# itself is t/213-hps-metrics.t.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-213.XXXXXX")"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  printf 'HPS_SYSTEM_BASE=%s\n' "$TEST_DIR/sys" > "$TEST_DIR/hps.conf"
  printf '#!/bin/bash\necho "tool=${0##*/} args=$*"\n' > "$TEST_DIR/sys/bin/hps-metrics"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/sys/bin/hps-metrics" "$TEST_DIR/bin/logger"
}

teardown() {
  rm -rf "$TEST_DIR"
}

gate() {
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-metrics" "$@"
}

@test "hps-metrics is an ips-admin tool: allowlisted, a wrapper, named by hps-op and OPERATOR.md" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [[ " ${IPS_ADMIN_SCRIPTS[*]} " == *" hps-metrics "* ]]
  [[ " ${IPS_ADMIN_RAW_SCRIPTS[*]} " != *" hps-metrics "* ]]
  [ -x "$ROOT/ips-admin/hps-metrics" ]
  grep -qxF 'exec "${0%/*}/ips-admin-exec" hps-metrics "$@"' "$ROOT/ips-admin/hps-metrics"
  grep -q 'hps-metrics' "$ROOT/bin/hps-op"
  grep -q '^| `hps-metrics` | `bin/hps-metrics` | `last`, `series`' "$ROOT/docs/OPERATOR.md"
  [ -x "$ROOT/bin/hps-metrics" ]
}

@test "the ips-admin gate: hps-metrics last and series pass with their options" {
  gate last all --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-metrics args=last all --json"* ]]
  gate last 52:54:00:02:d3:ca
  [ "$status" -eq 0 ]
  gate series cnh-001 --hours 168 --step 300 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-metrics args=series cnh-001 --hours 168 --step 300 --json"* ]]
  gate series ips --hours 6 --step 60
  [ "$status" -eq 0 ]
}

@test "the ips-admin gate: any other hps-metrics verb, or a path, is refused" {
  gate
  [ "$status" -eq 2 ]
  gate tail all
  [ "$status" -eq 2 ]
  [[ "$output" == *"only last and series"* ]]
  gate --json last all
  [ "$status" -eq 2 ]
  gate last ../../etc/passwd
  [ "$status" -eq 2 ]
  gate series 'a b'
  [ "$status" -eq 2 ]
  [[ "$output" != *"tool="* ]]
}
