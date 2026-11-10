#!/usr/bin/env bats
#
# CS-3.5: osvc-status - om daemon status / om mon output, the summary line and
# the exit status (0 healthy, 1 om failed, 2 a peer is stale, 3 usage).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-70.XXXXXX")"
  SCRIPT="$ROOT/node-manager/nixos-26/scripts/osvc-status"
  mkdir -p "$T/bin"
  export SHIM_LOG="$T/shim.log"
  # om shim: "daemon status" prints $STATUS_JSON, "mon" prints {"mon":true};
  # FAKE_OM_RC is the exit status of both.
  cat > "$T/bin/om" <<'SH'
#!/usr/bin/env bash
echo "om $*" >> "$SHIM_LOG"
if [[ "${FAKE_OM_RC:-0}" -ne 0 ]]; then exit "$FAKE_OM_RC"; fi
case "$1" in
  daemon) cat "$STATUS_JSON" ;;
  mon) echo '{"mon":true}' ;;
esac
SH
  chmod +x "$T/bin/om"
  export PATH="$T/bin:$PATH"
  export STATUS_JSON="$T/status.json"
}

teardown() {
  rm -rf "$T"
}

# status_json <frozen> <peer:beating|peer:beating-in-stream2>...
write_status() {
  cat > "$STATUS_JSON" <<JSON
{"cluster":{"status":{"is_frozen":$1}},
 "daemon":{"nodename":"sch-001","heartbeat":{"streams":[
   {"id":"hb#1.rx","peers":{"sch-002":{"is_beating":$2},"tch-001":{"is_beating":$3}}},
   {"id":"hb#1.tx","peers":{"sch-002":{"is_beating":$2},"tch-001":{"is_beating":$3}}}]}}}
JSON
}

@test "healthy: both om calls logged, both outputs printed, summary line, exit 0" {
  write_status false true true
  run -0 bash "$SCRIPT"
  [[ "$output" == *"== om daemon status --format json"* ]]
  [[ "$output" == *"== om mon --format json"* ]]
  [[ "$output" == *"OSVC sch-001 peers=2 beating=2 stale=- frozen=no"* ]]
  grep -qx 'om daemon status --format json' "$SHIM_LOG"
  grep -qx 'om mon --format json' "$SHIM_LOG"
  [[ "$output" == *"+ om daemon status --format json"* ]]
}

@test "a peer that no stream sees beating is stale: exit 2, named" {
  write_status false true false
  run -2 bash "$SCRIPT"
  [[ "$output" == *"OSVC sch-001 peers=2 beating=1 stale=tch-001 frozen=no"* ]]
}

@test "frozen node is reported" {
  write_status true true true
  run -0 bash "$SCRIPT"
  [[ "$output" == *"frozen=yes"* ]]
}

@test "a node alone in its cluster (no peers) is healthy" {
  echo '{"cluster":{"status":{"is_frozen":false}},"daemon":{"nodename":"sch-001","heartbeat":{"streams":[]}}}' > "$STATUS_JSON"
  run -0 bash "$SCRIPT"
  [[ "$output" == *"peers=0 beating=0 stale=- frozen=no"* ]]
}

@test "om failing (daemon down) is exit 1" {
  write_status false true true
  FAKE_OM_RC=1 run -1 bash "$SCRIPT"
  [[ "$output" == *"daemon is not running"* ]]
}

@test "an argument is a usage error, exit 3, and om is not called" {
  write_status false true true
  run -3 bash "$SCRIPT" extra
  [ ! -e "$SHIM_LOG" ]
}

@test "read-only: only status and mon are ever run" {
  write_status false true true
  run -0 bash "$SCRIPT"
  [ "$(wc -l < "$SHIM_LOG")" -eq 2 ]
}
