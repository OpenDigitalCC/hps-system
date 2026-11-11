#!/usr/bin/env bats
#
# IPS-15: every MAC of a machine identifies the same host.
#
# Runs against the real registry (lib/hps-registry.sh) in a temp directory, so
# the host keys, the scan for a recorded MAC and the written files are the ones
# the IPS uses. Stubbed: logging, CGI replies, the clock, the boot-script
# emitters (their output is the MAC they were called with).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-162.XXXXXX")"
  export TEST_DIR
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  HOSTS="$TEST_DIR/cfg/clusters/lab/hosts"
  export HOSTS
  mkdir -p "$HOSTS" "$TEST_DIR/res/nixos"
  export HPS_LOG="$TEST_DIR/hps.log"
  : > "$HPS_LOG"

  hps_log() { echo "$*" >> "$HPS_LOG"; }
  cgi_header_plain() { printf 'Content-Type: text/plain\n\n'; }
  cgi_fail() { cgi_header_plain; printf '%s' "$1"; }
  cgi_success() { cgi_header_plain; printf '%s' "$1"; }
  cgi_auto_fail() { cgi_header_plain; printf 'FAIL: %s\n' "$1"; }
  make_timestamp() { echo "2026-11-11 12:00:00 UTC"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo lab ;;
      cluster_hosts)  echo "$HOSTS" ;;
      config_base)    echo "$TEST_DIR/cfg" ;;
      resources)      echo "$TEST_DIR/res" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() { return 1; }
  list_cluster_hosts() { host_registry list_all; }
  export -f hps_log cgi_header_plain cgi_fail cgi_success cgi_auto_fail make_timestamp hps_get_config cluster_registry list_cluster_hosts

  # shellcheck disable=SC1091
  source "$ROOT/lib/hps-registry.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/network-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/host-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  # shellcheck disable=SC1091
  source "$ROOT/lib/functions.d/dns-dhcp-functions.sh"
  # emitters: record the MAC they were handed
  ipxe_boot_audit() { echo "audit-boot $1"; }
  ipxe_boot_from_disk() { echo "disk-boot"; }
  ipxe_network_boot() { echo "network-boot $1"; }
  ipxe_boot_installer() { echo "installer $1"; }
  ipxe_configure_main_menu() { echo "MENU"; }

  A=52:54:00:00:00:01
  A12=525400000001
  B=52:54:00:00:00:02
  B12=525400000002
  export REQUEST_METHOD=POST
  unset CONTENT_LENGTH
  # one registered host with a 2-port machine behind it
  host_registry "$A" set STATE HELD
  host_registry "$A" set HOSTNAME sch-001
  host_registry "$A" set IP 10.100.1.10
}

teardown() {
  rm -rf "$TEST_DIR"
}

# audit_file <name> <json>
audit_file() {
  printf '%s' "$2" > "$TEST_DIR/$1"
}

# A bare-metal audit: two real 1 GbE ports, a 10 GbE port, a bridge, a veth
# and a bond (virtual, the bond with a locally administered address).
BARE='{"schema":"hps-audit/1","net":{"link":[],"addr":[],"nics":[
 {"ifname":"eno1","mac":"52:54:00:00:00:01","physical":true,"driver":"tg3","speed":1000},
 {"ifname":"eno2","mac":"52:54:00:00:00:02","physical":true,"driver":"tg3","speed":null},
 {"ifname":"eno49","mac":"38:EA:A7:36:03:D8","physical":true,"driver":"bnx2x","speed":10000},
 {"ifname":"br0","mac":"52:54:00:00:00:01","physical":false,"driver":null,"speed":null},
 {"ifname":"veth1","mac":"0a:11:22:33:44:55","physical":false,"driver":null,"speed":null},
 {"ifname":"bond0","mac":"02:11:22:33:44:55","physical":false,"driver":null,"speed":null}]}}'

# The same machine without the second port in conflict: A's own three ports.
BARE_NO_B='{"schema":"hps-audit/1","net":{"nics":[
 {"ifname":"eno1","mac":"52:54:00:00:00:01","physical":true,"driver":"tg3","speed":1000},
 {"ifname":"eno49","mac":"38:EA:A7:36:03:D8","physical":true,"driver":"bnx2x","speed":10000}]}}'

# ------------------------------------------------------------------ intake

@test "intake records the physical MACs, key MAC first, and leaves out virtual ones" {
  audit_file a.json "$BARE"
  # B is not a host here, so its MAC is free
  run host_audit_intake "$A" < "$TEST_DIR/a.json"
  [ "$status" -eq 0 ]
  run host_registry "$A" get macs
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.mac) | join(",")' <<< "$output")" = "52:54:00:00:00:01,52:54:00:00:00:02,38:ea:a7:36:03:d8" ]
  [ "$(jq -r '.[0] | "\(.ifname) \(.driver) \(.speed)"' <<< "$output")" = "eno1 tg3 1000" ]
  [ "$(jq -r '.[1].speed' <<< "$output")" = "null" ]
}

@test "the loopback never counts, bridges and veths and vlans and taps and enslaved ports are left out of an older audit without nics" {
  audit_file a.json '{"schema":"hps-audit/1","net":{"link":[
    {"ifname":"lo","link_type":"loopback","address":"00:00:00:00:00:00"},
    {"ifname":"eno1","link_type":"ether","address":"52:54:00:00:00:01"},
    {"ifname":"eno2","link_type":"ether","address":"30:e1:71:53:c7:49"},
    {"ifname":"br0","link_type":"ether","address":"30:e1:71:53:c7:4a"},
    {"ifname":"veth9","link_type":"ether","address":"ae:11:22:33:44:55"},
    {"ifname":"eno2.100","link_type":"ether","address":"30:e1:71:53:c7:49"},
    {"ifname":"tap0","link_type":"ether","address":"fe:11:22:33:44:55"},
    {"ifname":"eno3","link_type":"ether","address":"30:e1:71:53:c7:4b","master":"bond0"}]}}'
  run host_audit_macs "$TEST_DIR/a.json" "$A12"
  [ "$status" -eq 0 ]
  [ "$(jq -r 'map(.mac) | join(",")' <<< "$output")" = "52:54:00:00:00:01,30:e1:71:53:c7:49" ]
}

@test "a VM's virtio NIC is kept although 52:54:00 is locally administered" {
  audit_file a.json '{"schema":"hps-audit/1","net":{"nics":[
    {"ifname":"enp1s0","mac":"52:54:00:4b:b4:10","physical":true,"driver":"virtio_net","speed":null}]}}'
  run host_audit_macs "$TEST_DIR/a.json" 5254004bb410
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].mac' <<< "$output")" = "52:54:00:4b:b4:10" ]
  [ "$(jq -r 'length' <<< "$output")" -eq 1 ]
}

@test "the real sch-001 audit of the lab gives its six MACs" {
  f="$ROOT/lab/ips/srv/hps-config/clusters/lab/hosts/38eaa73603d8.db/audit.json"
  [ -r "$f" ] || skip "lab fixture not present"
  run host_audit_macs "$f" 38eaa73603d8
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' <<< "$output")" -eq 6 ]
  [ "$(jq -r '.[0].mac' <<< "$output")" = "38:ea:a7:36:03:d8" ]
}

@test "the index finds the second port of a recorded host and an unknown MAC resolves to itself" {
  audit_file a.json "$BARE"
  host_audit_intake "$A" < "$TEST_DIR/a.json" > /dev/null
  run host_resolve_mac 38:ea:a7:36:03:d8
  [ "$status" -eq 0 ]
  [ "$output" = "$A12" ]
  run host_resolve_mac "38-EA-A7-36-03-D8"
  [ "$output" = "$A12" ]
  run host_resolve_mac "$A"
  [ "$status" -eq 0 ]
  [ "$output" = "$A" ]
  run host_resolve_mac 11:22:33:44:55:66
  [ "$status" -eq 1 ]
  [ "$output" = "11:22:33:44:55:66" ]
  run host_resolve_mac 10.100.1.99
  [ "$status" -eq 2 ]
  [ "$output" = "10.100.1.99" ]
}

@test "a MAC held by another host refuses the audit, logs it and stores nothing" {
  # B is a separate HELD host (booted from the second port first)
  host_registry "$B" set STATE HELD
  audit_file a.json "$BARE"
  run host_audit_intake "$A" < "$TEST_DIR/a.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 409"* ]]
  [[ "$output" == *"$B12"* ]]
  grep -q "node_audit refused: MAC already held by another host: $B12 $B12" "$HPS_LOG"
  run ! host_registry "$A" exists audit
  run ! host_registry "$A" exists macs
}

@test "a MAC another host lists among its recorded MACs is refused too" {
  host_registry "$B" set STATE HELD
  host_registry "$B" set macs '[{"mac":"38:ea:a7:36:03:d8","ifname":"eno49"}]'
  audit_file a.json "$BARE_NO_B"
  run host_audit_intake "$A" < "$TEST_DIR/a.json"
  [ "$status" -eq 1 ]
  [[ "$output" == "Status: 409"* ]]
  [[ "$output" == *"38eaa73603d8 $B12"* ]]
}

@test "forgetting the other host frees the MAC and the audit is then accepted" {
  host_registry "$B" set STATE HELD
  audit_file a.json "$BARE"
  run host_audit_intake "$A" < "$TEST_DIR/a.json"
  [ "$status" -eq 1 ]
  # forget removes the registry host (HPS::Registry::host_remove); the index is
  # computed from the registry, so there is nothing to rebuild
  host_registry "$B" destroy
  run host_resolve_mac "$B"
  [ "$status" -eq 1 ]
  run host_audit_intake "$A" < "$TEST_DIR/a.json"
  [ "$status" -eq 0 ]
}

@test "after forget a recorded MAC resolves to nothing and no longer conflicts" {
  audit_file a.json "$BARE_NO_B"
  host_audit_intake "$A" < "$TEST_DIR/a.json" > /dev/null
  run host_resolve_mac 38:ea:a7:36:03:d8
  [ "$output" = "$A12" ]
  host_registry "$A" destroy
  run host_resolve_mac 38:ea:a7:36:03:d8
  [ "$status" -eq 1 ]
  [ "$output" = "38:ea:a7:36:03:d8" ]
  run host_mac_conflicts "$B12" 38eaa73603d8
  [ -z "$output" ]
}

# ------------------------------------------------------------- iPXE handler

@test "the iPXE handler resolves a second MAC to the first host's record and state" {
  host_registry "$A" set STATE NETWORK_BOOT
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"}]'
  run ipxe_init_handler 38:ea:a7:36:03:d8
  [ "$status" -eq 0 ]
  [[ "$output" == "network-boot $A12" ]]
  # no new host was made for the second port
  [ ! -d "$HOSTS/38eaa73603d8.db" ]
  [ "$(host_registry list_all | wc -l)" -eq 1 ]
}

@test "boot_mac_last follows the port that booted" {
  host_registry "$A" set STATE NETWORK_BOOT
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"}]'
  ipxe_init_handler "$A" > /dev/null
  [ "$(host_registry "$A" get boot_mac_last)" = "$A12" ]
  ipxe_init_handler 38:ea:a7:36:03:d8 > /dev/null
  [ "$(host_registry "$A" get boot_mac_last)" = "38eaa73603d8" ]
  ipxe_init_handler "$A" > /dev/null
  [ "$(host_registry "$A" get boot_mac_last)" = "$A12" ]
}

@test "an unknown MAC still becomes a new HELD host" {
  run ipxe_init_handler 11:22:33:44:55:66
  [ "$status" -eq 0 ]
  [ "$(host_registry 112233445566 get STATE)" = "HELD" ]
  [[ "$output" == "audit-boot 11:22:33:44:55:66" ]]
}

@test "hps.mac on the kernel line is the MAC that booted, the host record is the first host's" {
  mkdir -p "$TEST_DIR/res/nixos/pin1/audit"
  printf '{"init":"/nix/store/abc/init","cmdline":"console=ttyS0"}\n' > "$TEST_DIR/res/nixos/pin1/audit/boot.json"
  source "$ROOT/lib/functions.d/nixos-boot-functions.sh"
  host_registry "$A" set STATE HELD
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"}]'
  nixos_ips_address() { echo 10.0.0.1; }
  nixos_resolve_pin() { echo pin1; }
  nixos_manifest_path() { echo "$TEST_DIR/res/nixos/$2/$1/boot.json"; }
  nixos_open_pairing_window() { :; }
  nixos_emit_boot() { nixos_boot_lines "$1" "$2" pin1; }
  run ipxe_init_handler 38:ea:a7:36:03:d8
  [ "$status" -eq 0 ]
  [[ "$output" == *"hps.mac=38:ea:a7:36:03:d8"* ]]
  [[ "$output" == *"hps.hostname=sch-001"* ]]
}

# ------------------------------------------------------------- boot_manager CGI

@test "boot_manager turns the request MAC into the host before any command" {
  grep -q 'mac="$(host_resolve_mac "$boot_mac")"' "$ROOT/http/cgi-bin/boot_manager.sh"
  # init keeps the booted MAC, the other commands use the host's
  grep -q 'ipxe_init_handler "$boot_mac"' "$ROOT/http/cgi-bin/boot_manager.sh"
}

@test "the node_audit command reaches the first host when it comes from a second port" {
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"52:54:00:00:00:02"}]'
  # what boot_manager does with the request MAC, then the command
  boot_mac="$B"
  mac="$(host_resolve_mac "$boot_mac")"
  [ "$mac" = "$A12" ]
  audit_file a.json '{"schema":"hps-audit/1","net":{"nics":[
    {"ifname":"eno1","mac":"52:54:00:00:00:01","physical":true,"driver":"tg3","speed":1000},
    {"ifname":"eno2","mac":"52:54:00:00:00:02","physical":true,"driver":"tg3","speed":1000}]}}'
  run host_audit_intake "$mac" < "$TEST_DIR/a.json"
  [ "$status" -eq 0 ]
  host_registry "$A" exists audit
  [ ! -d "$HOSTS/$B12.db" ]
}

# --------------------------------------------------------------------- DHCP

@test "the dhcp_addresses line of a host lists every MAC, key first" {
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"},{"mac":"38:ea:a7:36:03:d9"}]'
  run build_dhcp_addresses_file lab
  [ "$status" -eq 0 ]
  F="$TEST_DIR/cfg/clusters/lab/services/dhcp_addresses"
  [ "$(cat "$F")" = "52:54:00:00:00:01,38:ea:a7:36:03:d8,38:ea:a7:36:03:d9,10.100.1.10,sch-001" ]
}

@test "a host with no recorded MACs keeps the one-MAC line" {
  run build_dhcp_addresses_file lab
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/cfg/clusters/lab/services/dhcp_addresses")" = "52:54:00:00:00:01,10.100.1.10,sch-001" ]
}

@test "a MAC already on an earlier host's line is left off the later line, not moved" {
  host_registry "$B" set STATE HELD
  host_registry "$B" set HOSTNAME tch-001
  host_registry "$B" set IP 10.100.1.11
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"}]'
  host_registry "$B" set macs '[{"mac":"52:54:00:00:00:02"},{"mac":"38:ea:a7:36:03:d8"}]'
  run build_dhcp_addresses_file lab
  [ "$status" -eq 0 ]
  F="$TEST_DIR/cfg/clusters/lab/services/dhcp_addresses"
  grep -qx "52:54:00:00:00:01,38:ea:a7:36:03:d8,10.100.1.10,sch-001" "$F"
  grep -qx "52:54:00:00:00:02,10.100.1.11,tch-001" "$F"
  grep -q "already assigned" "$HPS_LOG"
}

@test "dns_hosts is per host and has one line however many MACs it has" {
  host_registry "$A" set macs '[{"mac":"52:54:00:00:00:01"},{"mac":"38:ea:a7:36:03:d8"}]'
  cluster_registry() {
    case "$3" in
      network_dns_domain) echo lab.hps ;;
      network_dhcp_ip) echo 10.100.1.1 ;;
    esac
  }
  run build_dns_hosts_file lab
  [ "$status" -eq 0 ]
  [ "$(grep -c sch-001 "$TEST_DIR/cfg/clusters/lab/services/dns_hosts")" -eq 1 ]
}

# ---------------------------------------------- audit collector and catalogue

@test "the audit collector writes net.nics from sysfs" {
  d="$TEST_DIR/sys/class/net"
  mkdir -p "$d/lo" "$d/eno1/device" "$d/br0"
  echo 00:00:00:00:00:00 > "$d/lo/address"
  echo 52:54:00:00:00:01 > "$d/eno1/address"
  echo 1000 > "$d/eno1/speed"
  echo 0a:00:00:00:00:09 > "$d/br0/address"
  mkdir -p "$TEST_DIR/sys/bus/pci/drivers/tg3"
  ln -s "$TEST_DIR/sys/bus/pci/drivers/tg3" "$d/eno1/device/driver"
  WORK="$TEST_DIR/work"
  mkdir -p "$WORK"
  HPS_SYS="$TEST_DIR/sys"
  log() { :; }
  eval "$(sed -n '/^read_attr() {/,/^}/p;/^collect_nics() {/,/^}/p' "$ROOT/node-manager/nixos-26/audit/hps-audit.sh")"
  run collect_nics
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' "$WORK/nics.json")" -eq 2 ]
  [ "$(jq -r '.[] | select(.ifname=="eno1") | "\(.physical) \(.driver) \(.speed)"' "$WORK/nics.json")" = "true tg3 1000" ]
  [ "$(jq -r '.[] | select(.ifname=="br0") | .physical' "$WORK/nics.json")" = "false" ]
}

@test "the API resolves the caller's MAC through the index before the known-host check (lab 2026-11-11)" {
  api="$BATS_TEST_DIRNAME/../../http/api/api.sh"
  r=$(grep -n 'resolved="$(host_resolve_mac "$CLIENT_MAC"' "$api" | head -1 | cut -d: -f1)
  k=$(grep -n 'if ! host_config_exists "$CLIENT_MAC"' "$api" | head -1 | cut -d: -f1)
  [ -n "$r" ] && [ -n "$k" ] && [ "$r" -lt "$k" ]
}
