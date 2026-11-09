#!/usr/bin/env bats
#
# CS-1.2: dnsmasq and lighttpd config generators (lib/functions.d/create-config-*.sh).
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
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/create-config-lighttpd.sh"
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

@test "lighttpd binds to the IPS address only, never 0.0.0.0 (shared host)" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qE '^server.bind +=+ "192.0.2.1"$' "$conf"
  grep -qE '^server.port +=+ 80$' "$conf"
  ! grep -q '0\.0\.0\.0' "$conf"
}

@test "lighttpd serves the http tree as document root with the CGI modules" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qF "server.document-root = \"$TEST_DIR/sys/http\"" "$conf"
  for m in mod_alias mod_cgi mod_accesslog; do
    grep -q "\"$m\"" "$conf"
  done
}

@test "lighttpd aliases every resource tree to the resources dir" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  for t in distros packages nixos nix-cache; do
    grep -qF "\"/$t/\"" "$conf"
    grep -qF "\"$TEST_DIR/res/$t/\"" "$conf"
  done
}

@test "lighttpd serves nix-cache-info as text/plain, lists nix-cache never" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qF '$HTTP["url"] =~ "^/nix-cache/nix-cache-info$" {' "$conf"
  grep -qF 'mimetype.assign = ( "" => "text/plain" )' "$conf"
  run awk '/=~ "\^\/nix-cache\/" \{/{f=1;next} f&&/dir-listing.activate = "disable"/{print "ok";exit} /^\}/{f=0}' "$conf"
  [ "$output" = "ok" ]
}

@test "lighttpd assigns .sh under /cgi-bin/ and /api/ to bash" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qF '$HTTP["url"] =~ "^/(cgi-bin|api)/" {' "$conf"
  grep -qF 'cgi.assign = ( ".sh" => "/bin/bash" )' "$conf"
}

@test "lighttpd enables ranges, a 256 KiB-capable request size and an upload dir" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qE '^server.range-requests += "enable"$' "$conf"
  size="$(sed -n 's/^server.max-request-size *= *\([0-9]*\)$/\1/p' "$conf")"
  [ "$size" -ge 256 ]
  grep -qF "server.upload-dirs   = ( \"$TEST_DIR/services/lighttpd-upload\" )" "$conf"
  [ -d "$TEST_DIR/services/lighttpd-upload" ]
  ! grep -q 'pid-file' "$conf"
}

@test "lighttpd sends access and error log to syslog only" {
  run create_config_lighttpd
  [ "$status" -eq 0 ]
  conf="$TEST_DIR/services/lighttpd.conf"
  grep -qE '^server.errorlog-use-syslog += "enable"$' "$conf"
  grep -qE '^accesslog.use-syslog +=+ "enable"$' "$conf"
  grep -qE '^accesslog.syslog-level +=+ [0-9]+$' "$conf"
  ! grep -qE '(accesslog.filename|server.errorlog) *=' "$conf"
}

@test "lighttpd generation fails clearly without network_dhcp_ip" {
  cluster_registry() { return 1; }
  export -f cluster_registry
  run create_config_lighttpd
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_DIR/services/lighttpd.conf" ]
}
