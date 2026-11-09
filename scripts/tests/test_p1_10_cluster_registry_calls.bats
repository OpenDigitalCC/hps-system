#!/usr/bin/env bats
#
# CS-1.1 item 1, 3: cluster_registry callers pass the active cluster
# (cluster_registry takes "<cluster> <op> ..."), and the os_config_select
# fallback receives the host type in its stored (upper) case.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-10.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  export CLUSTER_DB="$TEST_DIR/cluster.db"
  : > "$CALL_LOG"
  : > "$CLUSTER_DB"

  # Source first; the stubs below replace the real helpers they would call.
  source "$ROOT/lib/functions.d/host-functions.sh"
  source "$ROOT/lib/functions.d/network-functions.sh"
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"

  hps_log() { :; }
  hps_get_config() { [[ "$1" == active_cluster ]] && echo "c1"; }
  # Real contract: first argument is the cluster name. "get" as a cluster fails.
  cluster_registry() {
    [[ "$1" == "c1" ]] || return 1
    [[ "$2" == "get" ]] || return 1
    sed -n "s/^$3=//p" "$CLUSTER_DB"
  }
  host_registry() {
    local mac=$1 op=$2 key=${3:-} val=${4:-}
    if [[ "$op" == get ]]; then
      case "$key" in
        TYPE) echo "TCH" ;;
        arch) echo "x86_64" ;;
        HOST_PROFILE) echo "DEFAULT" ;;
        storage0_ip) echo "${FAKE_STORAGE_IP:-}" ;;
      esac
    else
      echo "host_registry $mac $op $key $val" >> "$CALL_LOG"
    fi
  }
  os_registry() { return 0; }
  os_config_select() { echo "select $*" >> "$CALL_LOG"; echo "x86_64:alpine:3.20.2"; }
  host_network_configure() { :; }
  ipxe_reboot() { :; }
  ipxe_network_boot() { :; }
  normalise_mac() { echo "$1"; }
  export -f hps_log hps_get_config cluster_registry host_registry os_registry \
    os_config_select host_network_configure ipxe_reboot ipxe_network_boot normalise_mac
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "get_host_os_id reads the OS key from the active cluster" {
  echo "os_tch_x86_64=x86_64:alpine:3.20.2" > "$CLUSTER_DB"
  run get_host_os_id "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64:alpine:3.20.2" ]
}

@test "get_host_os_id falls back to the non-arch key" {
  echo "os_tch=alpine" > "$CLUSTER_DB"
  run get_host_os_id "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  [ "$output" = "x86_64:alpine" ]
}

@test "ips_allocate_storage_ip reads storage settings from the active cluster" {
  cat > "$CLUSTER_DB" <<'DB'
network_storage_base_vlan=31
network_storage_count=2
network_storage_vlan31_subnet=10.31.0.0/24
network_storage_vlan31_netmask=255.255.255.0
network_storage_vlan31_gateway=10.31.0.1
network_storage_mtu=9000
DB
  export FAKE_STORAGE_IP="10.31.0.7"
  run ips_allocate_storage_ip 0 "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  [ "$output" = "31:10.31.0.7:255.255.255.0:10.31.0.1:9000" ]
}

@test "ipxe_boot_installer takes the OS from the cluster key" {
  echo "os_tch_x86_64=x86_64:alpine:3.20.2" > "$CLUSTER_DB"
  run ipxe_boot_installer "00:11:22:33:44:55"
  grep -q "host_registry 00:11:22:33:44:55 set os_id x86_64:alpine:3.20.2" "$CALL_LOG"
  ! grep -q '^select' "$CALL_LOG"
}

@test "ipxe_boot_installer fallback passes the type in its stored case" {
  : > "$CLUSTER_DB"
  run ipxe_boot_installer "00:11:22:33:44:55"
  grep -q "^select x86_64 TCH$" "$CALL_LOG"
}
