#!/usr/bin/env bats
#
# Tests for the node-side ctrl-exec lifecycle (node-manager/base/n_ctrl-exec.sh):
# config generation and the hands-free pairing flow. The agent CLI, API client
# and filesystem locations are all stubbed, so the test needs no ctrl-exec, no
# PXE environment and no network.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/n-ce.XXXXXX")"
  export CTRL_EXEC_AGENT_ETC="$TEST_DIR/etc"
  export CTRL_EXEC_AGENT_LIB="$TEST_DIR/lib"
  export CTRL_EXEC_PAIR_TIMEOUT=6

  # Node helper stubs.
  n_remote_log() { :; }
  n_get_provisioning_node() { echo "10.99.1.1"; }
  export -f n_remote_log n_get_provisioning_node

  # Records of the pairing report the node sends to the IPS.
  export API_LOG="$TEST_DIR/api.log"
  n_api_request() { echo "$*" >> "$API_LOG"; return "${FAKE_API_RC:-0}"; }
  export -f n_api_request

  # Fake ctrl-exec-agent CLI: prints a reqid for request-pairing.
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/ctrl-exec-agent" <<'EOF'
#!/bin/bash
case "$1" in
  request-pairing) echo "${FAKE_REQID:-deadbeef}" ;;
  *) : ;;
esac
EOF
  chmod +x "$TEST_DIR/bin/ctrl-exec-agent"

  source "${BATS_TEST_DIRNAME}/../../node-manager/base/n_ctrl-exec.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "write_config produces agent.conf and a single-entry allowlist" {
  run n_ctrl_exec_write_config
  [ "$status" -eq 0 ]
  [ -f "$CTRL_EXEC_AGENT_ETC/agent.conf" ]
  grep -q "listen_port = 7443" "$CTRL_EXEC_AGENT_ETC/agent.conf"
  grep -q "^hps-node = /usr/local/sbin/hps-node$" "$CTRL_EXEC_AGENT_ETC/scripts.conf"
  # The allowlist exposes exactly one script name.
  run grep -c "=" "$CTRL_EXEC_AGENT_ETC/scripts.conf"
  [ "$output" -eq 1 ]
}

@test "pair reports a sanitised reqid then succeeds when the cert appears" {
  mkdir -p "$CTRL_EXEC_AGENT_ETC"
  export FAKE_REQID="ab12cd"
  # Simulate the background pairing writing the cert shortly after.
  ( sleep 1; echo "cert" > "$CTRL_EXEC_AGENT_ETC/agent.crt" ) &

  run n_ctrl_exec_pair
  [ "$status" -eq 0 ]
  grep -q "ctrl_exec_pair_request reqid=ab12cd" "$API_LOG"
}

@test "pair strips non-hex characters from the reqid before reporting" {
  mkdir -p "$CTRL_EXEC_AGENT_ETC"
  export FAKE_REQID=$'ab12cd\n; rm -rf /'
  ( sleep 1; echo "cert" > "$CTRL_EXEC_AGENT_ETC/agent.crt" ) &

  run n_ctrl_exec_pair
  [ "$status" -eq 0 ]
  # Only the hex survives; no shell metacharacters reach the report.
  grep -q "ctrl_exec_pair_request reqid=ab12cd" "$API_LOG"
  ! grep -q "rm -rf" "$API_LOG"
}

@test "pair is a no-op when a certificate already exists" {
  mkdir -p "$CTRL_EXEC_AGENT_ETC"
  echo "existing" > "$CTRL_EXEC_AGENT_ETC/agent.crt"

  run n_ctrl_exec_pair
  [ "$status" -eq 0 ]
  # No report sent - already paired.
  [ ! -f "$API_LOG" ]
}

@test "pair fails when the IPS declines the report" {
  mkdir -p "$CTRL_EXEC_AGENT_ETC"
  export FAKE_API_RC=1

  run n_ctrl_exec_pair
  [ "$status" -ne 0 ]
}

@test "pair times out when no cert ever appears" {
  mkdir -p "$CTRL_EXEC_AGENT_ETC"
  export CTRL_EXEC_PAIR_TIMEOUT=4

  run n_ctrl_exec_pair
  [ "$status" -ne 0 ]
}
