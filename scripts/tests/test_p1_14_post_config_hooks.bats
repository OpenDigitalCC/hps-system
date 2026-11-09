#!/usr/bin/env bats
#
# CS-1.1 item 8: host_network_configure rebuilds the DHCP/DNS files through
# host_post_config_hooks, and a hook failure does not abort it.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-14.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"

  # Source first; the stubs below replace the real helpers they would call.
  source "$ROOT/lib/functions.d/host-functions.sh"

  hps_log() { :; }
  hps_get_config() { echo "c1"; }
  cluster_registry() {
    case "$3" in
      network_dhcp_ip) echo "10.99.1.1" ;;
      network_dhcp_rangesize) echo "20" ;;
      network_cidr) echo "24" ;;
    esac
  }
  host_registry() {
    local op=$2 key=${3:-} val=${4:-}
    case "$op" in
      get) [[ "$key" == TYPE ]] && echo "TCH"; return 0 ;;
      exists) return 1 ;;
      set) echo "set $key $val" >> "$CALL_LOG" ;;
    esac
    return 0
  }
  validate_ip_address() { return 0; }
  validate_hostname() { return 0; }
  cidr_to_netmask() { echo "255.255.255.0"; }
  _find_available_ip() { echo "10.99.1.8"; }
  _find_available_hostname() { echo "tch-001"; }
  update_dns_dhcp_files() { echo "rebuild" >> "$CALL_LOG"; return "${FAKE_REBUILD_RC:-0}"; }
  export -f hps_log hps_get_config cluster_registry host_registry validate_ip_address \
    validate_hostname cidr_to_netmask _find_available_ip _find_available_hostname \
    update_dns_dhcp_files
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "host_network_configure rebuilds DHCP and DNS files once" {
  run host_network_configure "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  grep -q "^set STATE CONFIGURED$" "$CALL_LOG"
  [ "$(grep -c '^rebuild$' "$CALL_LOG")" -eq 1 ]
}

@test "a failing rebuild does not fail host_network_configure" {
  FAKE_REBUILD_RC=1 run host_network_configure "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  grep -q "^rebuild$" "$CALL_LOG"
}

@test "a throwing hook function does not fail host_network_configure" {
  host_post_config_hooks() { return 1; }
  run host_network_configure "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
}
