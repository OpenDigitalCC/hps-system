#!/usr/bin/env bats
#
# CS-1.1 item 2, 4: STATE=CONFIGURED reaches a function that exists
# (ipxe_boot_installer), and force_install_on writes the STATE key.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-11.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"

  # Source first; the stubs below replace the real helpers they would call.
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"

  hps_log() { :; }
  host_registry() {
    local mac=$1 op=$2 key=${3:-} val=${4:-}
    case "$op" in
      exists) return 0 ;;
      get) [[ "$key" == STATE ]] && echo "${FAKE_STATE:-CONFIGURED}" ;;
      set) echo "set $key $val" >> "$CALL_LOG" ;;
    esac
    return 0
  }
  ipxe_boot_installer() { echo "installer $1" >> "$CALL_LOG"; }
  ipxe_goto_menu() { echo "goto" >> "$CALL_LOG"; }
  export -f hps_log host_registry ipxe_boot_installer ipxe_goto_menu

}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "CONFIGURED state starts the installer" {
  FAKE_STATE=CONFIGURED run ipxe_init_handler "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  grep -q "^installer 00:11:22:33:44:55$" "$CALL_LOG"
}

@test "ipxe_host_install_menu is not referenced any more" {
  ! grep -rn "ipxe_host_install_menu" "$ROOT/lib" "$ROOT/http"
}

@test "force_install_on resets STATE, not STATUS" {
  run handle_menu_item force_install_on "00:11:22:33:44:55"
  [ "$status" -eq 0 ]
  grep -q "^set FORCE_INSTALL YES$" "$CALL_LOG"
  grep -q "^set STATE UNCONFIGURED$" "$CALL_LOG"
  ! grep -q "STATUS" "$CALL_LOG"
}
