#!/usr/bin/env bats
#
# CS-1.2: supervisor_populate_tftp copies the shipped boot loaders into the
# TFTP root, only when missing or different.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-21.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/sys/tftp"
  for f in undionly.kpxe ipxe.efi snponly.efi; do
    echo "image-$f" > "$TEST_DIR/sys/tftp/$f"
  done
  export LOG="$TEST_DIR/log"
  hps_log() { echo "$*" >> "$LOG"; }
  hps_get_config() {
    case "$1" in
      system_base) echo "$TEST_DIR/sys" ;;
      tftp)        echo "$TEST_DIR/config/tftp" ;;
    esac
  }
  export -f hps_log hps_get_config
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/supervisor-functions.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "populate copies the three loaders into a new TFTP root" {
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  for f in undionly.kpxe ipxe.efi snponly.efi; do
    cmp "$TEST_DIR/sys/tftp/$f" "$TEST_DIR/config/tftp/$f"
  done
  grep -q '3 file(s) copied' "$LOG"
}

@test "populate is idempotent" {
  supervisor_populate_tftp
  : > "$LOG"
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  grep -q '0 file(s) copied' "$LOG"
}

@test "populate refreshes a differing file and leaves the rest alone" {
  supervisor_populate_tftp
  echo stale > "$TEST_DIR/config/tftp/snponly.efi"
  : > "$LOG"
  run supervisor_populate_tftp
  [ "$status" -eq 0 ]
  cmp "$TEST_DIR/sys/tftp/snponly.efi" "$TEST_DIR/config/tftp/snponly.efi"
  grep -q '1 file(s) copied' "$LOG"
}

@test "populate fails when the source directory is missing" {
  rm -rf "$TEST_DIR/sys/tftp"
  run supervisor_populate_tftp
  [ "$status" -eq 1 ]
}

@test "prepare_services runs the populate step" {
  create_config_nginx() { :; }
  create_config_dnsmasq() { :; }
  update_dns_dhcp_files() { :; }
  create_config_rsyslog() { :; }
  create_config_chrony() { :; }
  osvc_prepare_cluster() { :; }
  run supervisor_prepare_services
  [ "$status" -eq 0 ]
  [ -f "$TEST_DIR/config/tftp/snponly.efi" ]
}
