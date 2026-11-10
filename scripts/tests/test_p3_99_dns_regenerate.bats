#!/usr/bin/env bats
#
# IPS-10: dns_hosts and dhcp_addresses are generated from the registry (a host
# with IP and HOSTNAME resolves, forward and reverse, powered on or not),
# regenerated through one entry point (dns_regenerate), dnsmasq is reloaded
# once, and the IPS resolver carries no search domain.
#
# The registry, services and supervisor are stubbed; the written files are read.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-99.XXXXXX")"
  export TEST_DIR
  export CFG="$TEST_DIR/cfg"
  export CALLS="$TEST_DIR/calls.log"
  export HPS_RESOLV_CONF="$TEST_DIR/resolv.conf"
  : > "$CALLS"
  mkdir -p "$CFG"
  # host table: mac|key=value
  export REG="$TEST_DIR/reg"
  cat > "$REG" <<'R'
aabbccddee01|HOSTNAME=sch-001
aabbccddee01|IP=10.100.1.10
aabbccddee02|HOSTNAME=TCH-001
aabbccddee02|IP=10.100.1.11
aabbccddee02|storage0_ip=10.200.1.11
aabbccddee03|HOSTNAME=tch-002.other.example
aabbccddee03|IP=10.100.1.12
aabbccddee04|HOSTNAME=noip-001
aabbccddee05|IP=10.100.1.15
R
  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo "${FAKE_ACTIVE-lab}" ;;
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
  supervisor_reload_services() { echo "reload $*" >> "$CALLS"; return "${FAKE_RELOAD_RC:-0}"; }
  export -f hps_log hps_get_config cluster_registry list_cluster_hosts host_registry supervisor_reload_services
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/dns-dhcp-functions.sh"
  DNS="$CFG/clusters/lab/services/dns_hosts"
  DHCP="$CFG/clusters/lab/services/dhcp_addresses"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "dns_hosts carries the IPS line first, FQDN then label" {
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  [ "$(head -n1 "$DNS")" = "10.100.1.1 ips.lab.hps ips ntp syslog dhcp dns" ]
}

@test "every registry host with IP and HOSTNAME gets FQDN first and the short label" {
  run dns_regenerate lab false
  [ "$status" -eq 0 ]
  grep -qx '10.100.1.10 sch-001.lab.hps sch-001' "$DNS"
  grep -qx '10.100.1.11 tch-001.lab.hps tch-001' "$DNS"
}

@test "a HOSTNAME that already holds a dot is the FQDN" {
  run dns_regenerate lab false
  grep -qx '10.100.1.12 tch-002.other.example tch-002' "$DNS"
}

@test "hosts without an IP or without a HOSTNAME are left out" {
  run dns_regenerate lab false
  run ! grep -q 'noip-001' "$DNS"
  run ! grep -q '10.100.1.15' "$DNS"
}

@test "storage addresses recorded in the registry survive regeneration" {
  run dns_regenerate lab false
  grep -qx '10.200.1.11 tch-001-storage1.lab.hps tch-001-storage1' "$DNS"
}

@test "an off host and a hand-edited file: the file is rebuilt from the registry alone" {
  mkdir -p "$(dirname "$DNS")"
  echo "10.9.9.9 stale.lab.hps stale" > "$DNS"
  run dns_regenerate lab false
  run ! grep -q stale "$DNS"
}

@test "a key change is picked up by the next regeneration, a removed host disappears" {
  dns_regenerate lab false
  echo "aabbccddee01|IP=10.100.1.20" >> "$REG"
  dns_regenerate lab false
  grep -qx '10.100.1.20 sch-001.lab.hps sch-001' "$DNS"
  run ! grep -q '^10.100.1.10 ' "$DNS"
  grep -v '^aabbccddee02|' "$REG" > "$REG.new"
  mv "$REG.new" "$REG"
  dns_regenerate lab false
  run ! grep -q 'tch-001' "$DNS"
}

@test "a repeated name or address is skipped, the first line wins" {
  echo "aabbccddee06|HOSTNAME=sch-001" >> "$REG"
  echo "aabbccddee06|IP=10.100.1.30" >> "$REG"
  echo "aabbccddee07|HOSTNAME=dup-ip" >> "$REG"
  echo "aabbccddee07|IP=10.100.1.10" >> "$REG"
  run dns_regenerate lab false
  [ "$(grep -c 'sch-001.lab.hps' "$DNS")" -eq 1 ]
  run ! grep -q 'dup-ip' "$DNS"
}

@test "dhcp_addresses carries the bare label, never a dotted name" {
  run dns_regenerate lab false
  grep -qx 'aa:bb:cc:dd:ee:01,10.100.1.10,sch-001' "$DHCP"
  grep -qx 'aa:bb:cc:dd:ee:03,10.100.1.12,tch-002' "$DHCP"
}

@test "dns_regenerate reloads dnsmasq exactly once for the active cluster" {
  run dns_regenerate lab
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "reload dnsmasq" ]
}

@test "no reload when asked not to, or for a cluster that is not the active one" {
  dns_regenerate lab false
  FAKE_ACTIVE=other dns_regenerate lab true
  [ ! -s "$CALLS" ]
}

@test "a failed reload is not an error: the files are written" {
  FAKE_RELOAD_RC=2 run dns_regenerate lab
  [ "$status" -eq 0 ]
  [ -s "$DNS" ]
}

@test "update_dns_dhcp_files is the same entry point" {
  run update_dns_dhcp_files lab
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "reload dnsmasq" ]
  grep -qx '10.100.1.10 sch-001.lab.hps sch-001' "$DNS"
}

@test "no entry point failure when the domain is missing: nothing is reloaded" {
  cluster_registry() { [[ "$3" == network_dhcp_ip ]] && echo 10.100.1.1; return 0; }
  run dns_regenerate lab
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
}

@test "the IPS resolv.conf has the nameserver and no search line" {
  run dns_regenerate lab false
  grep -qx 'nameserver 10.100.1.1' "$HPS_RESOLV_CONF"
  run ! grep -q '^search' "$HPS_RESOLV_CONF"
}

@test "supervisor_reload_services reports a failing supervisorctl" {
  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/bash\necho "ERROR: no such process"\nexit 2\n' > "$TEST_DIR/bin/supervisorctl"
  chmod +x "$TEST_DIR/bin/supervisorctl"
  printf 'x\n' > "$TEST_DIR/sv.conf"
  hps_get_config() { echo "$TEST_DIR/sv.conf"; }
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/supervisor-functions.sh"
  PATH="$TEST_DIR/bin:$PATH" run supervisor_reload_services dnsmasq
  [ "$status" -eq 2 ]
}

@test "allocating a storage address keeps the host's primary line and adds the -storageN line" {
  mkdir -p "$TEST_DIR/hosts"
  normalise_mac() { echo "$1"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      config_base) echo "$CFG" ;;
      cluster_hosts) echo "$TEST_DIR/hosts" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    case "$3" in
      network_dns_domain) echo "lab.hps" ;;
      network_dhcp_ip) echo "10.100.1.1" ;;
      network_storage_base_vlan) echo 31 ;;
      network_storage_count) echo 2 ;;
      network_storage_vlan31_subnet) echo "10.31.0.0/24" ;;
      network_storage_vlan31_netmask) echo "255.255.255.0" ;;
      network_storage_vlan31_gateway) echo "10.31.0.1" ;;
      network_storage_mtu) echo 9000 ;;
    esac
  }
  host_registry() {
    if [[ "$2" == set ]]; then
      printf '%s|%s=%s\n' "$1" "$3" "$4" >> "$REG"
      return 0
    fi
    local line
    line=$(grep -F "${1}|${3}=" "$REG" | tail -n1) || return 1
    printf '%s\n' "${line#*=}"
  }
  run ips_allocate_storage_ip 0 aabbccddee01
  [ "$status" -eq 0 ]
  [ "$output" = "31:10.31.0.100:255.255.255.0:10.31.0.1:9000" ]
  grep -qx '10.100.1.10 sch-001.lab.hps sch-001' "$DNS"
  grep -qx '10.31.0.100 sch-001-storage1.lab.hps sch-001-storage1' "$DNS"
  [ "$(grep -c 'sch-001.lab.hps' "$DNS")" -eq 1 ]
  [ "$(cat "$CALLS")" = "reload dnsmasq" ]
}

@test "dns_host_add has no caller outside dns-dhcp-functions.sh" {
  run grep -rln "dns_host_add" "$ROOT/lib" "$ROOT/http" "$ROOT/bin"
  [ "$output" = "$ROOT/lib/functions.d/dns-dhcp-functions.sh" ]
}
