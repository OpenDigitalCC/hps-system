#!/usr/bin/env bats
#
# CS-1.9: the IPS time server. create_config_chrony output, the chronyd
# supervisor program block, and that service preparation generates the config.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-90.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  mkdir -p "$TEST_DIR/services"

  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster)   echo "lab" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    # cluster_registry <cluster> get <key>
    case "$3" in
      network_dhcp_ip)       echo "${FAKE_IP-192.0.2.1}" ;;
      network_cidr)          echo "192.0.2.0/24" ;;
      network_time_upstream) echo "${FAKE_UPSTREAM-}" ;;
    esac
  }
  export -f hps_log hps_get_config cluster_registry
  source "$ROOT/lib/functions.d/create-config-chrony.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "chrony.conf serves the cluster network from the IPS address" {
  run create_config_chrony
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/chrony.conf"
  grep -qx 'allow 192.0.2.0/24' "$conf"
  grep -qx 'bindaddress 192.0.2.1' "$conf"
  grep -qx 'local stratum 10' "$conf"
  grep -qx "driftfile $TEST_DIR/services/chrony.drift" "$conf"
}

@test "chrony.conf has no upstream by default" {
  run create_config_chrony
  [ "$status" -eq 0 ]
  if grep -qE '^(pool|server) ' "$TEST_DIR/services/chrony.conf"; then return 1; fi
}

@test "network_time_upstream adds one server line per name" {
  export FAKE_UPSTREAM="2.debian.pool.ntp.org time.example.net"
  run create_config_chrony
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/chrony.conf"
  grep -qx 'server 2.debian.pool.ntp.org iburst' "$conf"
  grep -qx 'server time.example.net iburst' "$conf"
}

@test "a malformed upstream name is refused and nothing is written" {
  export FAKE_UPSTREAM='bad;name'
  run create_config_chrony
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_DIR/services/chrony.conf" ]
}

@test "no network_dhcp_ip is refused" {
  export FAKE_IP=""
  run create_config_chrony
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_DIR/services/chrony.conf" ]
}

@test "supervisord gets one chronyd program in the foreground on the generated config" {
  export HPS_LOG="$TEST_DIR/log"
  mkdir -p "$HPS_LOG"
  : > "$TEST_DIR/supervisord.conf"
  hps_get_config() {
    case "$1" in
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster)   echo "lab" ;;
    esac
  }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  run supervisor_configure_core_services
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/supervisord.conf"
  run grep -c '^\[program:chronyd\]' "$conf"
  [ "$output" -eq 1 ]
  grep -qx "command=/usr/sbin/chronyd -d -x -u root -f $TEST_DIR/services/chrony.conf" "$conf"
}

@test "service preparation generates the chrony config" {
  source "$ROOT/lib/functions.d/supervisor-functions.sh"
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  supervisor_populate_tftp() { :; }
  os_seed_nixos() { :; }
  create_config_nginx() { :; }
  create_config_dnsmasq() { :; }
  update_dns_dhcp_files() { :; }
  create_config_rsyslog() { :; }
  osvc_prepare_cluster() { :; }
  create_config_chrony() { echo chrony >> "$CALLS"; }
  run supervisor_prepare_services
  [ "$status" -eq 0 ]
  grep -qx chrony "$CALLS"
}

@test "cluster-bootstrap writes network_time_upstream: empty by default, the given servers with --time-upstream" {
  export HPS_SYSTEM_PATH="$ROOT"
  mkdir -p "$TEST_DIR/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/bin/logger"
  export PATH="$TEST_DIR/bin:$PATH"
  export HPS_RESOLV_CONF="$TEST_DIR/resolv.conf"
  export HPS_BASE="$TEST_DIR/base"
  args=(--name lab --dhcp-iface ens9 --network 10.100.1.0/24 --ips-ip 10.100.1.1
        --dhcp-range 10.100.1.100-10.100.1.199)
  run "$ROOT/scripts/cluster-bootstrap.sh" "${args[@]}"
  [ "$status" -eq 0 ]
  db="$HPS_BASE/hps-config/clusters/lab/cluster.db"
  [ "$(jq -r . "$db/network_time_upstream.json")" = "" ]
  [ "$(jq -r . "$db/network_time_server.json")" = "10.100.1.1" ]
  [[ "$output" == *network_time_upstream* ]]
  run "$ROOT/scripts/cluster-bootstrap.sh" "${args[@]}" --force --time-upstream "0.pool.example.net ntp2.example.net"
  [ "$status" -eq 0 ]
  [ "$(jq -r . "$db/network_time_upstream.json")" = "0.pool.example.net ntp2.example.net" ]
  run "$ROOT/scripts/cluster-bootstrap.sh" "${args[@]}" --force --time-upstream "bad;name"
  [ "$status" -eq 1 ]
}
