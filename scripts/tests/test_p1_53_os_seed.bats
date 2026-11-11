#!/usr/bin/env bats
#
# CS-1.5 item 4: os_seed_nixos creates x86_64:nixos:26.05 once, and runs in
# the pre-start sequence.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-53.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  load p1_50_helpers
  source "$ROOT/lib/hps-registry.sh"
  source "$ROOT/lib/functions.d/os-functions.sh"
  source "$ROOT/lib/functions.d/supervisor-functions.sh"
  p1_50_stubs
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  OSDIR="$HPS_CONFIG_BASE/os.db/x86_64_nixos_26.05.os"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "creates the entry with the manifest boot key" {
  run os_seed_nixos
  [ "$status" -eq 0 ]
  [ "$(jq -r . "$OSDIR/hps_types.json")" = "SCH,TCH,DRH,CNH" ]
  [ "$(jq -r . "$OSDIR/arch.json")" = "x86_64" ]
  [ "$(jq -r . "$OSDIR/name.json")" = "nixos" ]
  [ "$(jq -r . "$OSDIR/version.json")" = "26.05" ]
  [ "$(jq -r . "$OSDIR/status.json")" = "prod" ]
  [ "$(jq -r . "$OSDIR/boot.json")" = "manifest" ]
  [ "$(cat "$OSDIR/.os_id")" = "x86_64:nixos:26.05" ]
}

@test "is idempotent and leaves operator edits alone" {
  os_seed_nixos
  os_config_set x86_64:nixos:26.05 status test
  run os_seed_nixos
  [ "$status" -eq 0 ]
  [ "$(jq -r . "$OSDIR/status.json")" = "test" ]
  [ "$(os_registry list | grep -c nixos)" -eq 1 ]
}

@test "supervisor_prepare_services seeds nixos" {
  supervisor_populate_tftp() { :; }
  create_config_lighttpd() { :; }
  create_config_dnsmasq() { :; }
  update_dns_dhcp_files() { :; }
  create_config_rsyslog() { :; }
  osvc_prepare_cluster() { :; }
  run supervisor_prepare_services
  [ "$status" -eq 0 ]
  [ -f "$OSDIR/boot.json" ]
}
