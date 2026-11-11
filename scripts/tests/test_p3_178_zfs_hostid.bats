#!/usr/bin/env bats
#
# Scale test phase 2: a ZFS hostid per node. The IPS derives it from the host
# key MAC (first 8 hex digits of sha256 of the 12 lower-case hex digits), passes
# it as spl.spl_hostid=0x<id> on the kernel command line and records it as host
# key zfs_hostid. Real registry in a temp directory (as test_p3_162).

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-178.XXXXXX")"
  export TEST_DIR
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  HOSTS="$TEST_DIR/cfg/clusters/lab/hosts"
  export HOSTS
  mkdir -p "$HOSTS" "$TEST_DIR/cfg/ck" "$TEST_DIR/res/nixos/pin1/audit" "$TEST_DIR/res/nixos/pin1/node-base"
  export HPS_LOG="$TEST_DIR/hps.log"
  : > "$HPS_LOG"
  hps_log() { echo "$*" >> "$HPS_LOG"; }
  cgi_header_plain() { printf 'Content-Type: text/plain\n\n'; }
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
  export -f hps_log cgi_header_plain cgi_auto_fail make_timestamp hps_get_config
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
  cluster_registry() {
    [[ "$2" == get && -f "$TEST_DIR/cfg/ck/$3" ]] || return 1
    cat "$TEST_DIR/cfg/ck/$3"
  }
  list_cluster_hosts() { host_registry list_all; }
  export -f cluster_registry list_cluster_hosts
  local p
  for p in audit node-base; do
    printf '{"kernel":"bzImage","initrd":"initrd","init":"/x/init","cmdline":"console=ttyS0","profile":"%s","pin":"pin1"}\n' "$p" \
      > "$TEST_DIR/res/nixos/pin1/$p/boot.json"
  done
  printf 'pin1' > "$TEST_DIR/cfg/ck/nixos_default_pin"
  printf '10.0.0.1' > "$TEST_DIR/cfg/ck/network_dhcp_ip"
  A=52:54:00:00:00:01
  B=52:54:00:00:00:02
  C=52:54:00:00:00:03
  host_registry "$A" set STATE HELD
  host_registry "$C" set STATE HELD
}

teardown() {
  rm -rf "$TEST_DIR"
}

hostid_of() {
  grep -o 'spl\.spl_hostid=0x[0-9a-f]*' <<< "$1" | cut -d= -f2
}

@test "the hostid is the first 8 hex digits of sha256 of the 12 hex digits of the key MAC" {
  run nixos_zfs_hostid "$A"
  [ "$status" -eq 0 ]
  expect="$(printf '525400000001' | sha256sum | cut -c1-8)"
  [ "$output" = "$expect" ]
  [[ "$output" =~ ^[0-9a-f]{8}$ ]]
}

@test "the hostid does not depend on how the MAC is written" {
  run nixos_zfs_hostid "52:54:00:00:00:0A"
  a="$output"
  run nixos_zfs_hostid "52-54-00-00-00-0a"
  [ "$output" = "$a" ]
  run nixos_zfs_hostid 52540000000a
  [ "$output" = "$a" ]
}

@test "different hosts get different hostids" {
  a="$(nixos_zfs_hostid "$A")"
  c="$(nixos_zfs_hostid "$C")"
  [ "$a" != "$c" ]
}

@test "a malformed MAC gives no hostid" {
  run nixos_zfs_hostid "not-a-mac"
  [ "$status" -ne 0 ]
}

@test "the boot line carries spl.spl_hostid=0x<id> and records zfs_hostid on the host" {
  run nixos_boot_lines "$A" node-base pin1
  [ "$status" -eq 0 ]
  id="$(nixos_zfs_hostid "$A")"
  [[ "$output" == *" spl.spl_hostid=0x${id} "* || "$output" == *" spl.spl_hostid=0x${id}"$'\n'* ]]
  run host_registry "$A" get zfs_hostid
  [ "$output" = "$id" ]
}

@test "the audit image gets the same hostid as the role image" {
  audit="$(nixos_boot_lines "$A" audit pin1)"
  role="$(nixos_boot_lines "$A" node-base pin1)"
  [ "$(hostid_of "$audit")" = "$(hostid_of "$role")" ]
  [ -n "$(hostid_of "$role")" ]
}

@test "the hostid is the same on every boot (stable, nothing to store)" {
  one="$(nixos_boot_lines "$A" node-base pin1)"
  host_registry "$A" delete zfs_hostid
  two="$(nixos_boot_lines "$A" node-base pin1)"
  [ "$(hostid_of "$one")" = "$(hostid_of "$two")" ]
}

@test "two hosts get different hostids on the kernel line" {
  a="$(hostid_of "$(nixos_boot_lines "$A" node-base pin1)")"
  c="$(hostid_of "$(nixos_boot_lines "$C" node-base pin1)")"
  [ -n "$a" ]
  [ -n "$c" ]
  [ "$a" != "$c" ]
}

@test "a boot from an alias MAC (IPS-15) gets the host key MAC's hostid, hps.mac stays the booted MAC" {
  host_registry "$A" set macs "[{\"mac\":\"$A\"},{\"mac\":\"$B\"}]"
  run ipxe_init_handler "$B"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hps.mac=${B}"* ]]
  id="$(nixos_zfs_hostid "$A")"
  [[ "$output" == *"spl.spl_hostid=0x${id}"* ]]
  [ "$id" != "$(nixos_zfs_hostid "$B")" ]
  [ "$(host_registry "$A" get zfs_hostid)" = "$id" ]
}

@test "wiring: the registry key is catalogued, the image keeps a placeholder hostId" {
  run prove -I "$ROOT/lib/perl" "$ROOT/t/83-registry-keys.t"
  [ "$status" -eq 0 ]
  run perl -I "$ROOT/lib/perl" "$ROOT/bin/hps-registry-keys" --type host zfs_hostid
  [ "$output" = "string" ]
  grep -q 'networking.hostId = "[0-9a-f]\{8\}";' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'spl.spl_hostid' "$ROOT/nix/modules/hps-common.nix"
}
