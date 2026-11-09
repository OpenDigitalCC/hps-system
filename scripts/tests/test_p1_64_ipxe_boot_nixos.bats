#!/usr/bin/env bats
#
# CS-1.6 items 4 and 6: ipxe_init_handler stamps last_boot_at on every
# boot-script issue; ipxe_boot_nixos reads the pinned boot.json, starts a new
# enrolment cycle (clears ctrl_exec_paired), opens the dispatcher pairing
# window and emits the kernel/initrd boot with the hps.* arguments.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-64.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"
  export RES="$TEST_DIR/resources"
  MAC="00:11:22:33:44:55"

  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  source "$ROOT/lib/functions.d/ipxe-nixos-functions.sh"

  hps_log() { echo "log $*" >> "$CALL_LOG"; }
  hps_get_config() {
    case "$1" in
      resources) echo "$RES" ;;
      active_cluster) echo lab ;;
    esac
  }
  cluster_registry() {
    case "$3" in
      network_dhcp_ip) echo "10.0.0.1" ;;
      nixos_default_pin) echo "${FAKE_CLUSTER_PIN:-}" ;;
    esac
  }
  host_registry() {
    local op=$2 key=${3:-} val=${4:-}
    case "$op" in
      exists) return 0 ;;
      get)
        case "$key" in
          STATE) echo "${FAKE_STATE:-NETWORK_BOOT}" ;;
          system_pin) [[ -n "${FAKE_PIN:-}" ]] && echo "$FAKE_PIN" ;;
          HOST_PROFILE) echo "${FAKE_PROFILE:-converged}" ;;
          *) return 1 ;;
        esac
        ;;
      set) echo "set $key $val" >> "$CALL_LOG" ;;
      delete) echo "delete $key" >> "$CALL_LOG" ;;
    esac
    return 0
  }
  ce_pairing_window_open() { echo "window_open $*" >> "$CALL_LOG"; return "${FAKE_OPEN_RC:-0}"; }
  _do_pxe_boot() { echo "boot kernel=[$1] initrd=[$2]" >> "$CALL_LOG"; }
  ipxe_cgi_fail() { echo "fail $*" >> "$CALL_LOG"; }
  ipxe_network_boot() { echo "network_boot $1" >> "$CALL_LOG"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

write_manifest() {
  local pin="$1" image="$2"
  mkdir -p "$RES/nixos/$pin/$image"
  cat > "$RES/nixos/$pin/$image/boot.json" <<EOT
{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/x/init","cmdline":"initrd=initrd console=ttyS0,115200n8","pin":"$pin"}
EOT
}

@test "ipxe_init_handler records last_boot_at as an epoch on every issue" {
  run ipxe_init_handler "$MAC"
  [ "$status" -eq 0 ]
  grep -Eq "^set last_boot_at [0-9]{10,}$" "$CALL_LOG"
  grep -q "^network_boot $MAC" "$CALL_LOG"
}

@test "last_boot_at is stamped before the state is dispatched" {
  run ipxe_init_handler "$MAC"
  stamp=$(grep -n "^set last_boot_at" "$CALL_LOG" | cut -d: -f1)
  dispatch=$(grep -n "^network_boot" "$CALL_LOG" | cut -d: -f1)
  [ "$stamp" -lt "$dispatch" ]
}

@test "ipxe_boot_nixos boots the pinned image with the hps arguments" {
  export FAKE_PIN="nixos-26.05-20261109-abc1234"
  write_manifest "$FAKE_PIN" node-converged
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  grep -q "boot kernel=\[http://10.0.0.1/nixos/$FAKE_PIN/node-converged/bzImage initrd=initrd console=ttyS0,115200n8 hps.ips=10.0.0.1 hps.mac=$MAC hps.profile=converged\] initrd=\[http://10.0.0.1/nixos/$FAKE_PIN/node-converged/initrd\]" "$CALL_LOG"
}

@test "ipxe_boot_nixos clears ctrl_exec_paired and opens the pairing window first" {
  export FAKE_PIN="nixos-26.05-20261109-abc1234"
  write_manifest "$FAKE_PIN" node-converged
  run ipxe_boot_nixos "$MAC"
  grep -q "^delete ctrl_exec_paired" "$CALL_LOG"
  grep -q "^window_open 300" "$CALL_LOG"
  win=$(grep -n "^window_open" "$CALL_LOG" | cut -d: -f1)
  boot=$(grep -n "^boot " "$CALL_LOG" | cut -d: -f1)
  [ "$win" -lt "$boot" ]
}

@test "a failed window open is logged and the boot script is still issued" {
  export FAKE_PIN="nixos-26.05-20261109-abc1234"
  export FAKE_OPEN_RC=1
  write_manifest "$FAKE_PIN" node-converged
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  grep -q "pairing window not opened" "$CALL_LOG"
  grep -q "^boot " "$CALL_LOG"
}

@test "ipxe_boot_nixos falls back to the cluster default pin" {
  export FAKE_CLUSTER_PIN="nixos-26.05-20261109-def5678"
  write_manifest "$FAKE_CLUSTER_PIN" node-converged
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 0 ]
  grep -q "/nixos/$FAKE_CLUSTER_PIN/node-converged/bzImage" "$CALL_LOG"
}

@test "ipxe_boot_nixos fails visibly with no pin" {
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 1 ]
  grep -q "^fail No NixOS version pin" "$CALL_LOG"
  ! grep -q "^window_open" "$CALL_LOG"
}

@test "ipxe_boot_nixos fails visibly with no manifest and does not open the window" {
  export FAKE_PIN="nixos-26.05-20261109-abc1234"
  run ipxe_boot_nixos "$MAC"
  [ "$status" -eq 1 ]
  grep -q "^fail NixOS boot manifest missing" "$CALL_LOG"
  ! grep -q "^window_open" "$CALL_LOG"
}

@test "ipxe_network_boot routes a nixos host to ipxe_boot_nixos" {
  unset -f ipxe_network_boot
  source "$ROOT/lib/functions.d/ipxe-menu-functions.sh"
  get_os_name() { echo nixos; }
  get_host_os_id() { echo "x86_64:nixos:26.05"; }
  ipxe_boot_nixos() { echo "routed" >> "$CALL_LOG"; }
  run ipxe_network_boot "$MAC"
  grep -q "^routed" "$CALL_LOG"
}
