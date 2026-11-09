#!/usr/bin/env bats
#
# CS-2.0b: _find_available_ip allocates only from the declared static pool,
# skipping reserved addresses and every IP already in a host registry, and
# refuses (no fallback) when the pool is missing or full.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-11.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TEST_DIR
  : > "$TEST_DIR/used"
  : > "$TEST_DIR/log"

  source "$ROOT/lib/functions.d/network-functions.sh"
  source "$ROOT/lib/functions.d/host-functions.sh"

  hps_log() { echo "$*" >> "$TEST_DIR/log"; }
  get_cluster_host_ips() { cat "$TEST_DIR/used"; }
  host_registry() { return 1; }
  export -f hps_log get_cluster_host_ips host_registry
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "returns the first pool address, never IPS+1" {
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.99 "" 10.100.1.1
  [ "$status" -eq 0 ]
  [ "$output" = "10.100.1.10" ]
}

@test "skips reserved addresses" {
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.99 "10.100.1.10 10.100.1.11" 10.100.1.1
  [ "$status" -eq 0 ]
  [ "$output" = "10.100.1.12" ]
}

@test "skips addresses already in a host registry" {
  printf '10.100.1.10\n10.100.1.11\n10.100.1.30\n' > "$TEST_DIR/used"
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.99 "10.100.1.12" 10.100.1.1
  [ "$status" -eq 0 ]
  [ "$output" = "10.100.1.13" ]
}

@test "an address of a host outside the pool does not matter" {
  printf '10.100.1.2\n10.100.1.150\n' > "$TEST_DIR/used"
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.99 "" 10.100.1.1
  [ "$output" = "10.100.1.10" ]
}

@test "a host's own current IP stays allocatable" {
  printf '10.100.1.10\n' > "$TEST_DIR/used"
  host_registry() { echo 10.100.1.10; }
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.99 "" 10.100.1.1
  [ "$output" = "10.100.1.10" ]
}

@test "skips the IPS address when the pool contains it" {
  run _find_available_ip aabbccddeeff 10.100.1.1 10.100.1.3 "" 10.100.1.1
  [ "$output" = "10.100.1.2" ]
}

@test "a full pool is refused with a log line and no output" {
  printf '10.100.1.10\n' > "$TEST_DIR/used"
  run _find_available_ip aabbccddeeff 10.100.1.10 10.100.1.12 "10.100.1.11 10.100.1.12" 10.100.1.1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "exhausted" "$TEST_DIR/log"
}

@test "missing or invalid pool keys are refused, with no fallback" {
  run _find_available_ip aabbccddeeff "" "" "" 10.100.1.1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q "static pool not declared" "$TEST_DIR/log"
  run _find_available_ip aabbccddeeff 10.100.1.50 10.100.1.10 "" 10.100.1.1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run _find_available_ip aabbccddeeff nonsense 10.100.1.10 "" 10.100.1.1
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "host_network_configure reads the pool keys and refuses when they are missing" {
  hps_get_config() { echo c1; }
  cluster_registry() {
    case "$3" in
      network_dhcp_ip) echo 10.100.1.1 ;;
      network_cidr) echo 10.100.1.0/24 ;;
      network_static_start) [[ -n "${NO_POOL:-}" ]] || echo 10.100.1.10 ;;
      network_static_end) [[ -n "${NO_POOL:-}" ]] || echo 10.100.1.99 ;;
      network_reserved) echo 10.100.1.10 ;;
    esac
  }
  host_registry() {
    case "$2" in
      get) [[ "$3" == TYPE ]] && echo TCH; return 0 ;;
      exists) return 1 ;;
      set) echo "set $3 $4" >> "$TEST_DIR/sets" ;;
    esac
    return 0
  }
  validate_ip_address() { return 0; }
  validate_hostname() { return 0; }
  cidr_to_netmask() { echo 255.255.255.0; }
  _find_available_hostname() { echo tch-001; }
  update_dns_dhcp_files() { return 0; }
  export -f hps_get_config cluster_registry host_registry validate_ip_address \
    validate_hostname cidr_to_netmask _find_available_hostname update_dns_dhcp_files

  run host_network_configure aabbccddeeff
  [ "$status" -eq 0 ]
  grep -qx "set IP 10.100.1.11" "$TEST_DIR/sets"

  rm -f "$TEST_DIR/sets"
  NO_POOL=1 run host_network_configure aabbccddeeff
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_DIR/sets" ]
}
