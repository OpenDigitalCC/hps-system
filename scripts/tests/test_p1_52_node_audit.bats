#!/usr/bin/env bats
#
# CS-1.5 item 3: cmd=node_audit intake (host_audit_intake).

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-52.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/functions.d/host-functions.sh"
  p1_50_stubs
  MAC=52:54:00:aa:bb:01
  p1_50_host "$MAC" STATE HELD
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH
  GOOD="$TEST_DIR/good.json"
  cat > "$GOOD" <<'EOF'
{"schema":"hps-audit/1","collected_at":"2026-11-09T10:00:00Z",
 "storage_controllers":{"scsi_hosts":[{"host":"host0","driver":"hpsa","hba_mode_enabled":1}],"raid_mode_indicator":false},
 "block":{"blockdevices":[{"name":"sda","type":"disk"},{"name":"sdb","type":"disk"},{"name":"sr0","type":"rom"}]}}
EOF
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "valid POST from a HELD host is stored and answered ok" {
  run host_audit_intake "$MAC" < "$GOOD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok" ]]
  [ "$(jq -r .schema "$TEST_DIR/hosts/525400aabb01/audit")" = "hps-audit/1" ]
  [ "$(jq -r '.block.blockdevices | length' "$TEST_DIR/hosts/525400aabb01/audit")" -eq 3 ]
  [ "$(cat "$TEST_DIR/hosts/525400aabb01/audit_at")" = "2026-11-09 12:00:00 UTC" ]
}

@test "the log line carries MAC, size, controller mode and disk count" {
  run host_audit_intake "$MAC" < "$GOOD"
  [ "$status" -eq 0 ]
  grep -q "\[$MAC\] node_audit stored: .* bytes controllers=1 disks=2" "$TEST_DIR/hps.log"
}

@test "GET is refused with 405 and nothing stored" {
  REQUEST_METHOD=GET run host_audit_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 405"* ]]
  [ ! -e "$TEST_DIR/hosts/525400aabb01/audit" ]
}

@test "a host that is not HELD is refused and logged" {
  p1_50_host "$MAC" STATE NETWORK_BOOT
  run host_audit_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 403"* ]]
  grep -q "node_audit refused: STATE is 'NETWORK_BOOT'" "$TEST_DIR/hps.log"
  [ ! -e "$TEST_DIR/hosts/525400aabb01/audit" ]
}

@test "an unknown caller is refused and not created" {
  run host_audit_intake 52:54:00:00:00:99 < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 403"* ]]
  [ ! -e "$TEST_DIR/hosts/525400000099" ]
}

@test "a wrong schema is refused with 400" {
  echo '{"schema":"other/2"}' > "$TEST_DIR/bad.json"
  run host_audit_intake "$MAC" < "$TEST_DIR/bad.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 400"* ]]
  [ ! -e "$TEST_DIR/hosts/525400aabb01/audit" ]
}

@test "a body that is not JSON is refused with 400" {
  echo 'not json at all' > "$TEST_DIR/bad.json"
  run host_audit_intake "$MAC" < "$TEST_DIR/bad.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 400"* ]]
}

@test "a body over the cap is refused with 413 even when Content-Length lies" {
  export HPS_AUDIT_MAX_BYTES=200
  head -c 4000 /dev/zero | tr '\0' 'x' > "$TEST_DIR/big.json"
  run host_audit_intake "$MAC" < "$TEST_DIR/big.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 413"* ]]
  [ ! -e "$TEST_DIR/hosts/525400aabb01/audit" ]
}

@test "a declared Content-Length over the cap is refused before reading" {
  export HPS_AUDIT_MAX_BYTES=200
  export CONTENT_LENGTH=5000
  run host_audit_intake "$MAC" < "$GOOD"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 413"* ]]
}

@test "the default cap is 256 KiB" {
  head -c 262145 /dev/zero | tr '\0' 'x' > "$TEST_DIR/big.json"
  run host_audit_intake "$MAC" < "$TEST_DIR/big.json"
  [[ "$output" == "Status: 413"* ]]
}

@test "boot_manager.sh routes cmd=node_audit to host_audit_intake" {
  grep -q 'cmd" == "node_audit"' "$ROOT/http/cgi-bin/boot_manager.sh"
  grep -q 'host_audit_intake "\$mac"' "$ROOT/http/cgi-bin/boot_manager.sh"
}
