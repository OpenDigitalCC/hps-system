#!/usr/bin/env bats
#
# IPS-42 row 5: the DHCP reservations of workload NICs reach dnsmasq through the
# generators the registered hosts use (dns_regenerate): dhcp_addresses gets
# "MAC,IP,label" and dns_hosts "IP FQDN label" from services/workload_hosts,
# which hps-workload publishes. A MAC, address or name a registered host holds
# is never given twice; a destroyed workload keeps its reservation but its name
# stops resolving. The registry, services and supervisor are stubbed.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ips42-05.XXXXXX")"
  export TEST_DIR
  export CFG="$TEST_DIR/cfg"
  export CALLS="$TEST_DIR/calls.log"
  export HPS_RESOLV_CONF="$TEST_DIR/resolv.conf"
  : > "$CALLS"
  mkdir -p "$CFG/clusters/lab/services"
  export REG="$TEST_DIR/reg"
  cat > "$REG" <<'R'
aabbccddee01|HOSTNAME=sch-001
aabbccddee01|IP=10.100.1.10
aabbccddee02|HOSTNAME=tch-001
aabbccddee02|IP=10.100.1.11
R
  hps_log() { echo "$*" >> "$TEST_DIR/log"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      config_base) echo "$CFG" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    case "$3" in
      network_dns_domain) echo "lab.hps" ;;
      network_dhcp_ip) echo "10.100.1.1" ;;
    esac
  }
  list_cluster_hosts() { cut -d'|' -f1 "$REG" | sort -u; }
  host_registry() {
    local line
    line=$(grep -F "${1}|${3}=" "$REG" | tail -n1) || return 1
    printf '%s\n' "${line#*=}"
  }
  supervisor_reload_services() { echo "reload $*" >> "$CALLS"; }
  export -f hps_log hps_get_config cluster_registry list_cluster_hosts host_registry supervisor_reload_services
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/dns-dhcp-functions.sh"
  DNS="$CFG/clusters/lab/services/dns_hosts"
  DHCP="$CFG/clusters/lab/services/dhcp_addresses"
  WH="$CFG/clusters/lab/services/workload_hosts"
  cat > "$WH" <<'W'
# written by hps-workload
host 52:54:00:00:00:01 10.100.1.162 odoo-clustertest dns
host 52:54:00:00:00:02 10.100.1.163 odoo-clustertest-nic1 dns
host 52:54:00:00:00:03 10.100.1.170 gone-vm -
W
}

teardown() { rm -rf "$TEST_DIR"; }

@test "dhcp_addresses carries a MAC,IP,label line per workload NIC after the registered hosts" {
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  grep -qx 'aa:bb:cc:dd:ee:01,10.100.1.10,sch-001' "$DHCP"
  grep -qx '52:54:00:00:00:01,10.100.1.162,odoo-clustertest' "$DHCP"
  grep -qx '52:54:00:00:00:02,10.100.1.163,odoo-clustertest-nic1' "$DHCP"
  [ "$(tail -n1 "$DHCP")" = '52:54:00:00:00:03,10.100.1.170,gone-vm' ]
}

@test "dns_hosts resolves a workload that exists, FQDN first, and leaves out a destroyed one" {
  run dns_regenerate lab false
  grep -qx '10.100.1.162 odoo-clustertest.lab.hps odoo-clustertest' "$DNS"
  grep -qx '10.100.1.163 odoo-clustertest-nic1.lab.hps odoo-clustertest-nic1' "$DNS"
  run ! grep -q 'gone-vm' "$DNS"
}

@test "no workload_hosts file: the output is the registered hosts alone" {
  rm -f "$WH"
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DHCP")" -eq 2 ]
  [ "$(wc -l < "$DNS")" -eq 3 ]
}

@test "an address, MAC or name a registered host holds is not given again" {
  cat >> "$WH" <<'W'
host 52:54:00:00:00:04 10.100.1.10 same-ip dns
host aa:bb:cc:dd:ee:01 10.100.1.171 same-mac dns
host 52:54:00:00:00:05 10.100.1.172 sch-001 dns
host 52:54:00:00:00:01 10.100.1.173 dup-mac dns
W
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  run ! grep -E 'same-ip|same-mac|dup-mac|10.100.1.172' "$DHCP"
  run ! grep -E 'same-ip|same-mac|dup-mac|10.100.1.172' "$DNS"
  [ "$(grep -c 'sch-001' "$DHCP")" -eq 1 ]
}

@test "a row that does not check is dropped: bad MAC, address, label, flag or a stray column" {
  cat > "$WH" <<'W'
host zz:54:00:00:00:01 10.100.1.162 a dns
host 52:54:00:00:00:02 10.100.1.999 b dns
host 52:54:00:00:00:03 10.100.1.164 C_d dns
host 52:54:00:00:00:04 10.100.1.165 e maybe
host 52:54:00:00:00:05 10.100.1.166 f dns extra
wild odoo 10.100.1.167
host 52:54:00:00:00:06 10.100.1.168 good dns
W
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$DHCP")" -eq 3 ]
  grep -qx '52:54:00:00:00:06,10.100.1.168,good' "$DHCP"
}

@test "the files are rebuilt from the registry and the published rows alone" {
  echo "52:54:00:00:00:09,10.100.1.99,stale" > "$DHCP"
  run dns_regenerate lab false
  run ! grep -q stale "$DHCP"
}
