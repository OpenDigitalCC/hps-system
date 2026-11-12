#!/usr/bin/env bats
#
# hps-workload console through the operator API: hps-workload is an ips-admin
# tool, so the gate passes the console verb and its options as plain tokens
# (the scale board reads the probes' serial lines this way). The reading itself
# is t/221-workload-console.t.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-221.XXXXXX")"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  printf 'HPS_SYSTEM_BASE=%s\n' "$TEST_DIR/sys" > "$TEST_DIR/hps.conf"
  printf '#!/bin/bash\necho "tool=${0##*/} args=$*"\n' > "$TEST_DIR/sys/bin/hps-workload"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/sys/bin/hps-workload" "$TEST_DIR/bin/logger"
}

teardown() {
  rm -rf "$TEST_DIR"
}

gate() {
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-workload" "$@"
}

@test "the ips-admin gate passes hps-workload console with --vm and --lines" {
  gate console probe-tch-001 --vm probe-tch-001 --lines 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-workload args=console probe-tch-001 --vm probe-tch-001 --lines 20"* ]]
  gate console probe-tch-001 --json
  [ "$status" -eq 0 ]
}

@test "the ips-admin gate refuses a path or a shell word in a console argument" {
  gate console ../../etc/passwd
  [ "$status" -eq 2 ]
  gate console probe-tch-001 --vm 'a;b'
  [ "$status" -eq 2 ]
  gate console probe-tch-001 --lines '20 30'
  [ "$status" -eq 2 ]
  [[ "$output" != *"tool="* ]]
}

@test "console is named in the CLI usage and the operator docs" {
  grep -q 'hps-workload console <name> \[--vm <vm>\] \[--lines N\]' "$ROOT/bin/hps-workload"
  grep -q 'hps-workload console' "$ROOT/docs/OPERATOR.md"
  grep -q 'hps-workload console' "$ROOT/docs/WORKLOADS.md"
  grep -q 'vm-seed-write <vm> --disk <boot disk>' "$ROOT/docs/WORKLOADS.md"
}
