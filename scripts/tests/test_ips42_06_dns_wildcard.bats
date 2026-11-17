#!/usr/bin/env bats
#
# IPS-42 row 6: a workload whose definition says "dns": ["*"] has its VM name and
# every name below it answered by the IPS's dnsmasq with the VM's reserved
# address. hps-workload publishes "wild <label> <ip>" rows beside the host rows
# (services/workload_hosts); dns_regenerate writes them as dnsmasq address=
# lines (dns_wildcards), which dnsmasq reads only at start, so a change rewrites
# dnsmasq.conf and restarts dnsmasq and an unchanged file is a plain reload.
# The registry, services and supervisor are stubbed; the written files are read.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-06.XXXXXX")"
  export TEST_DIR
  export CFG="$TEST_DIR/cfg"
  export CALLS="$TEST_DIR/calls.log"
  export HPS_RESOLV_CONF="$TEST_DIR/resolv.conf"
  : > "$CALLS"
  mkdir -p "$CFG/clusters/lab/services" "$TEST_DIR/config/tftp"
  export REG="$TEST_DIR/reg"
  cat > "$REG" <<'R'
aabbccddee01|HOSTNAME=sch-001
aabbccddee01|IP=10.100.1.10
R
  hps_log() { echo "$*" >> "$TEST_DIR/log"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      config_base) echo "$CFG" ;;
      cluster_services) echo "$CFG/clusters/lab/services" ;;
      tftp) echo "$TEST_DIR/config/tftp" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    case "$3" in
      network_dns_domain) echo "lab.hps" ;;
      network_dhcp_ip) echo "10.100.1.1" ;;
      network_dhcp_iface) echo ens9 ;;
      network_cidr) echo "10.100.1.0/24" ;;
    esac
  }
  generate_dhcp_range_simple() { echo "10.100.1.100,10.100.1.199,1h"; }
  list_cluster_hosts() { cut -d'|' -f1 "$REG" | sort -u; }
  host_registry() {
    local line
    line=$(grep -F "${1}|${3}=" "$REG" | tail -n1) || return 1
    printf '%s\n' "${line#*=}"
  }
  supervisor_reload_services() { echo "reload $*" >> "$CALLS"; }
  supervisor_restart_service() { echo "restart $*" >> "$CALLS"; }
  export -f hps_log hps_get_config cluster_registry generate_dhcp_range_simple list_cluster_hosts host_registry supervisor_reload_services supervisor_restart_service
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/create-config-dnsmasq.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/dns-dhcp-functions.sh"
  S="$CFG/clusters/lab/services"
  WH="$S/workload_hosts"
  WILD="$S/dns_wildcards"
}

teardown() { rm -rf "$TEST_DIR"; }

put_rows() {
  cat > "$WH" <<'W'
host 52:54:00:00:00:01 10.100.1.162 odoo-clustertest dns
wild odoo-clustertest 10.100.1.162
W
}

@test "a wild row becomes an address= line for the name under the cluster domain" {
  put_rows
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  [ "$(cat "$WILD")" = "address=/odoo-clustertest.lab.hps/10.100.1.162" ]
}

@test "no wild row: an empty file and no restart" {
  run dns_regenerate lab
  [ "$status" -eq 0 ]
  [ ! -s "$WILD" ]
  [ "$(cat "$CALLS")" = "reload dnsmasq" ]
}

@test "a change restarts dnsmasq after rewriting its configuration; an unchanged file is a reload" {
  put_rows
  : > "$CALLS"
  run dns_regenerate lab
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "restart dnsmasq" ]
  [ -f "$S/dnsmasq.conf" ]
  grep -qx "conf-file=$WILD" "$S/dnsmasq.conf"
  : > "$CALLS"
  run dns_regenerate lab
  [ "$(cat "$CALLS")" = "reload dnsmasq" ]
}

@test "removing the row empties the file and restarts once more" {
  put_rows
  dns_regenerate lab false
  : > "$CALLS"
  echo "host 52:54:00:00:00:01 10.100.1.162 odoo-clustertest -" > "$WH"
  run dns_regenerate lab
  [ ! -s "$WILD" ]
  [ "$(cat "$CALLS")" = "restart dnsmasq" ]
}

@test "service start (no reload) writes the file and touches no service" {
  put_rows
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ -s "$WILD" ]
}

@test "a registered host's name, a repeat and a bad row are skipped" {
  cat > "$WH" <<'W'
wild sch-001 10.100.1.170
wild good 10.100.1.171
wild good 10.100.1.172
wild Bad_Name 10.100.1.173
wild nope 10.100.1.999
wild extra 10.100.1.174 col
host 52:54:00:00:00:01 10.100.1.162 hostrow dns
W
  run dns_regenerate lab false
  [ "$(cat "$WILD")" = "address=/good.lab.hps/10.100.1.171" ]
}

@test "dnsmasq.conf includes the wildcard file and the file exists after generation" {
  rm -f "$WILD"
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  grep -qx "conf-file=$WILD" "$S/dnsmasq.conf"
  [ -f "$WILD" ]
}
