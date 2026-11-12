#!/usr/bin/env bats
#
# Shutdown order on a compute host (incident 2026-11-12): vm-start records a
# guest's priority and role, hps-shutdown-storage (the poweroff/reboot path,
# node-poweroff included) stops guests priority 5 first and 1 last, and at one
# priority the storage consumers before the providers.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-212.XXXXXX")"
  export TEST_DIR
  export HPS_GUEST_ORDER_DIR="$TEST_DIR/guests"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "1: vm-start records <priority> <provides storage> once the guest runs" {
  p3_20_setup
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1 --priority 1 --provides-storage
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_GUEST_ORDER_DIR/vm1")" = "1 1" ]
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_GUEST_ORDER_DIR/vm1")" = "3 0" ]
}

@test "2: vm-start refuses a bad --priority or an unknown option (2), and records nothing" {
  p3_20_setup
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-start" vm1 --priority 7
  [ "$status" -eq 2 ]
  run bash "$S/vm-start" vm1 --bogus
  [ "$status" -eq 2 ]
  [ ! -e "$HPS_GUEST_ORDER_DIR/vm1" ]
}

shutdown_rig() {
  SCRIPT="$ROOT/node-manager/nixos-26/boot/hps-shutdown-storage.sh"
  export SHIM_LOG="$TEST_DIR/shim.log"
  : > "$SHIM_LOG"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/scripts" "$TEST_DIR/mirrors" "$TEST_DIR/iscsi" "$HPS_GUEST_ORDER_DIR"
  export PATH="$TEST_DIR/bin:$PATH"
  export HPS_SCRIPTS_DIR="$TEST_DIR/scripts" HPS_MIRROR_DIR="$TEST_DIR/mirrors" HPS_CONFIGFS_ISCSI="$TEST_DIR/iscsi"
  export HPS_SHUTDOWN_STEP_TIMEOUT=2 HPS_SHUTDOWN_GUEST_TIMEOUT=1
  for n in vm-stop mirror-stop iscsi-unexport; do
    printf '#!/usr/bin/env bash\necho "$(basename "$0") $*" >> "$SHIM_LOG"\n' > "$TEST_DIR/scripts/$n"
  done
  # virsh lists the providers first (alphabetical): the incident's order
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$*" > "$TEST_DIR/bin/virsh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/zpool"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/iscsiadm"
  chmod +x "$TEST_DIR"/bin/* "$TEST_DIR"/scripts/*
}

stops() {
  grep '^vm-stop ' "$SHIM_LOG" | cut -d' ' -f2 | paste -sd' ' -
}

@test "3: at one priority the consumers stop before the providers (s1: TCH before SCH)" {
  shutdown_rig s1-ips s1-sch-001 s1-sch-002 s1-tch-001 s1-tch-002
  for g in s1-ips s1-sch-001 s1-sch-002; do echo "4 1" > "$HPS_GUEST_ORDER_DIR/$g"; done
  for g in s1-tch-001 s1-tch-002; do echo "4 0" > "$HPS_GUEST_ORDER_DIR/$g"; done
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stops)" = "s1-tch-001 s1-tch-002 s1-ips s1-sch-001 s1-sch-002" ]
  [[ "$output" == *"guest stop order: s1-tch-001 s1-tch-002 s1-ips s1-sch-001 s1-sch-002"* ]]
}

@test "4: priority decides first: 5 stops first, 1 last; a guest without a record counts as 3, a consumer" {
  shutdown_rig a-one b-five c-none d-three-provider
  echo "1 0" > "$HPS_GUEST_ORDER_DIR/a-one"
  echo "5 1" > "$HPS_GUEST_ORDER_DIR/b-five"
  echo "3 1" > "$HPS_GUEST_ORDER_DIR/d-three-provider"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(stops)" = "b-five c-none d-three-provider a-one" ]
}

@test "5: an unreadable or malformed record falls back to 3 / consumer" {
  shutdown_rig x y
  echo "nine yes" > "$HPS_GUEST_ORDER_DIR/x"
  echo "2 1" > "$HPS_GUEST_ORDER_DIR/y"
  run bash "$SCRIPT"
  [ "$(stops)" = "x y" ]
}

@test "6: node-poweroff goes through this ordering (systemctl poweroff runs hps-shutdown-storage)" {
  grep -q 'systemctl poweroff' "$ROOT/node-manager/nixos-26/scripts/node-poweroff"
  grep -q 'hps-shutdown-storage' "$ROOT/nix/modules/hps-common.nix"
}
