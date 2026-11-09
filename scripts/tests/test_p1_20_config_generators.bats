#!/usr/bin/env bats
#
# CS-1.2: dnsmasq and nginx config generators (lib/functions.d/create-config-*.sh).
# Registry, path lookup and range maths are stubbed; the generated files are
# inspected.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-20.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/sys" "$TEST_DIR/res" "$TEST_DIR/config/tftp"

  hps_log() { :; }
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster)   echo "lab" ;;
      system_base)      echo "$TEST_DIR/sys" ;;
      resources)        echo "$TEST_DIR/res" ;;
      tftp)             echo "$TEST_DIR/config/tftp" ;;
      *) return 1 ;;
    esac
  }
  cluster_registry() {
    # cluster_registry <cluster> get <key>
    case "$3" in
      network_dhcp_ip)        echo "192.0.2.1" ;;
      network_dhcp_iface)     echo "${FAKE_IFACE-ens9}" ;;
      network_cidr)           echo "192.0.2.0/24" ;;
      network_dhcp_rangesize) echo "20" ;;
      network_dns_domain)     echo "lab.test" ;;
    esac
  }
  generate_dhcp_range_simple() { echo "192.0.2.100,192.0.2.119,12h"; }
  export -f hps_log hps_get_config cluster_registry generate_dhcp_range_simple

  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/create-config-dnsmasq.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/create-config-nginx.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "dnsmasq splits UEFI x86-64 clients to snponly.efi" {
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/dnsmasq.conf"
  grep -qx 'dhcp-match=set:efi64,option:client-arch,7' "$conf"
  grep -qx 'dhcp-match=set:efi64,option:client-arch,9' "$conf"
  grep -qx 'dhcp-boot=tag:efi64,tag:!ipxe,snponly.efi' "$conf"
  grep -qx 'dhcp-boot=tag:!efi64,tag:!ipxe,undionly.kpxe' "$conf"
}

@test "dnsmasq keeps the iPXE chain to boot_manager" {
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/dnsmasq.conf"
  grep -qx 'dhcp-match=set:ipxe,175' "$conf"
  grep -qx 'dhcp-boot=tag:ipxe,http://192.0.2.1/cgi-bin/boot_manager.sh?cmd=init' "$conf"
}

@test "dnsmasq binds to the configured interface exactly once" {
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/dnsmasq.conf"
  grep -qx 'interface=ens9' "$conf"
  grep -qx 'bind-interfaces' "$conf"
  run grep -c '^interface=' "$conf"
  [ "$output" -eq 1 ]
}

@test "dnsmasq refuses to run without a configured interface" {
  export FAKE_IFACE=""
  run create_config_dnsmasq
  [ "$status" -eq 1 ]
  [ ! -f "$TEST_DIR/services/dnsmasq.conf" ]
}

@test "dnsmasq TFTP root is the hps_get_config tftp directory" {
  run create_config_dnsmasq
  [ "$status" -eq 0 ]
  grep -qx "tftp-root=$TEST_DIR/config/tftp" "$TEST_DIR/services/dnsmasq.conf"
}

@test "nginx serves /nixos/ and /nix-cache/ from the resources tree" {
  run create_config_nginx
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/nginx.conf"
  grep -q 'location /nixos/ {' "$conf"
  grep -q "alias $TEST_DIR/res/nixos/;" "$conf"
  grep -q 'location /nix-cache/ {' "$conf"
  grep -q "alias $TEST_DIR/res/nix-cache/;" "$conf"
}

@test "nginx serves nix-cache-info as text/plain with no cache listing" {
  run create_config_nginx
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/nginx.conf"
  grep -q 'location = /nix-cache/nix-cache-info {' "$conf"
  grep -q 'default_type text/plain;' "$conf"
  # autoindex off sits inside the /nix-cache/ block
  run awk '/location \/nix-cache\/ \{/{f=1} f&&/autoindex off;/{print "ok"; exit}' "$conf"
  [ "$output" = "ok" ]
}
