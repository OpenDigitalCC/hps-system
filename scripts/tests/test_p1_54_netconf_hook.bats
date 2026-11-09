#!/usr/bin/env bats
#
# CS-1.5 item 5: scripts/hps-netconf-hook.sh runs host_network_configure;
# hps-onboard defaults its hook to the script; a CSV TYPE names the host by
# its first element.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-54.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/scripts/hps-netconf-hook.sh"
  # A fake system tree whose function library records the calls.
  mkdir -p "$TEST_DIR/sys/lib"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOF
hps_log() { :; }
host_network_configure() { echo "host_network_configure \$1" >> "$TEST_DIR/calls.log"; return "\${FAKE_NETCONF_RC:-0}"; }
EOF
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "hook is executable and starts with the env shebang" {
  [ -x "$HOOK" ]
  [ "$(head -1 "$HOOK")" = "#!/usr/bin/env bash" ]
}

@test "hook runs host_network_configure with the MAC" {
  run "$HOOK" 525400aabb01
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/calls.log")" = "host_network_configure 525400aabb01" ]
}

@test "hook passes a failure through" {
  FAKE_NETCONF_RC=1 run "$HOOK" 525400aabb01
  [ "$status" -eq 1 ]
}

@test "hook needs exactly one argument" {
  run "$HOOK"
  [ "$status" -eq 2 ]
}

@test "hook fails clearly when the function library is missing" {
  HPS_SYSTEM_PATH="$TEST_DIR/none" run "$HOOK" 525400aabb01
  [ "$status" -eq 1 ]
  [[ "$output" == *"function library not found"* ]]
}

@test "hps-onboard defaults the hook to the script, env override wins" {
  grep -q 'scripts/hps-netconf-hook.sh' "$ROOT/bin/hps-onboard"
  grep -q 'defined \$ENV{HPS_ONBOARD_NETCONF_CMD}' "$ROOT/bin/hps-onboard"
}

@test "a CSV TYPE names the host from its first element" {
  source "$ROOT/lib/functions.d/host-functions.sh"
  get_cluster_host_hostnames() { printf 'sch-001\nsch-002\ntch-004\n'; }
  run _find_available_hostname "SCH,TCH"
  [ "$output" = "sch-003" ]
}
