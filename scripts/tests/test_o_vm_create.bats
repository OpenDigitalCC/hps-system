#!/usr/bin/env bats
#
# Tests for o_vm_create (lib/functions.d/o_vm-functions.sh) after the ctrl-exec
# rework: parameter validation, the retained OpenSVC health gate, and dispatch
# over ctrl-exec. o_vm_validate_node and ce_run are stubbed, so the test needs
# no OpenSVC, no ctrl-exec and no nodes.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/o-vm.XXXXXX")"
  export CE_RUN_LOG="$TEST_DIR/ce_run.log"

  o_log() { :; }
  export -f o_log

  # Health gate: return code driven by FAKE_VALIDATE_RC (0 = healthy).
  o_vm_validate_node() { return "${FAKE_VALIDATE_RC:-0}"; }
  export -f o_vm_validate_node

  # ctrl-exec exec wrapper: record the call, succeed unless FAKE_CE_RUN_RC set.
  ce_run() { echo "$*" >> "$CE_RUN_LOG"; return "${FAKE_CE_RUN_RC:-0}"; }
  export -f ce_run

  # Load only o_vm_create by sourcing the library (other o_vm_* funcs are stubs
  # above or unused here).
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/o_vm-functions.sh"
  # Re-stub after sourcing (the library defines the real o_vm_validate_node).
  o_vm_validate_node() { return "${FAKE_VALIDATE_RC:-0}"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "rejects missing parameters" {
  run o_vm_create
  [ "$status" -eq 1 ]
  run o_vm_create "vm1"
  [ "$status" -eq 1 ]
  [ ! -f "$CE_RUN_LOG" ]
}

@test "runs vm-create over ctrl-exec on a healthy node" {
  export FAKE_VALIDATE_RC=0
  run o_vm_create "vm-abc" "tch-001"
  [ "$status" -eq 0 ]
  grep -q "tch-001 hps-node vm-create vm-abc" "$CE_RUN_LOG"
}

@test "passes optional title and description through" {
  export FAKE_VALIDATE_RC=0
  run o_vm_create "vm-abc" "tch-001" "Web VM" "front end"
  [ "$status" -eq 0 ]
  grep -q "tch-001 hps-node vm-create vm-abc Web VM front end" "$CE_RUN_LOG"
}

@test "does not dispatch when the node is not in the cluster" {
  export FAKE_VALIDATE_RC=2
  run o_vm_create "vm-abc" "tch-001"
  [ "$status" -eq 2 ]
  [ ! -f "$CE_RUN_LOG" ]
}

@test "does not dispatch when the node daemon is down" {
  export FAKE_VALIDATE_RC=3
  run o_vm_create "vm-abc" "tch-001"
  [ "$status" -eq 3 ]
  [ ! -f "$CE_RUN_LOG" ]
}

@test "returns 5 when ctrl-exec execution fails" {
  export FAKE_VALIDATE_RC=0
  export FAKE_CE_RUN_RC=1
  run o_vm_create "vm-abc" "tch-001"
  [ "$status" -eq 5 ]
}
