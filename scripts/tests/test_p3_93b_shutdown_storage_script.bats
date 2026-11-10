#!/usr/bin/env bats
#
# IPS-04: hps-shutdown-storage.sh with shimmed virsh, zpool, iscsiadm and the
# ctrl-exec scripts it reuses. Every command is recorded in $SHIM_LOG.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$ROOT/node-manager/nixos-26/boot/hps-shutdown-storage.sh"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-93b.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  : > "$SHIM_LOG"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/scripts" "$TEST_DIR/mirrors" "$TEST_DIR/iscsi/iqn.2026-11.hps.lab:a" "$TEST_DIR/iscsi/iqn.2026-11.hps.lab:b"
  export PATH="$TEST_DIR/bin:$PATH"
  export HPS_SCRIPTS_DIR="$TEST_DIR/scripts"
  export HPS_MIRROR_DIR="$TEST_DIR/mirrors"
  export HPS_CONFIGFS_ISCSI="$TEST_DIR/iscsi"
  export HPS_SHUTDOWN_STEP_TIMEOUT=2
  export HPS_SHUTDOWN_GUEST_TIMEOUT=1
  touch "$TEST_DIR/mirrors/m0.json"
  for n in vm-stop mirror-stop iscsi-unexport; do
    cat > "$TEST_DIR/scripts/$n" <<'SHIM'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$SHIM_LOG"
[[ -z "${FAKE_HANG:-}" || "$(basename "$0")" != "$FAKE_HANG" ]] || sleep 30
[[ "${FAKE_FAIL:-}" != "$(basename "$0")" ]] || exit 1
exit 0
SHIM
    chmod +x "$TEST_DIR/scripts/$n"
  done
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
echo "virsh $*" >> "$SHIM_LOG"
printf 'g1\ng2\n\n'
SHIM
  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
case "$1" in
  list) printf 'lab\nother\n' ;;
  export) [[ "${FAKE_ZPOOL_EXPORT_RC:-0}" -eq 0 ]] || exit "$FAKE_ZPOOL_EXPORT_RC" ;;
esac
SHIM
  cat > "$TEST_DIR/bin/iscsiadm" <<'SHIM'
#!/usr/bin/env bash
echo "iscsiadm $*" >> "$SHIM_LOG"
exit "${FAKE_ISCSIADM_RC:-0}"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "shellcheck clean" {
  shellcheck -S warning "$SCRIPT"
}

@test "clean run: every layer is stopped, in order, and the exit is 0" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  expected="vm-stop g1 --timeout 1 --force
vm-stop g2 --timeout 1 --force
mirror-stop m0
iscsi-unexport iqn.2026-11.hps.lab:a
iscsi-unexport iqn.2026-11.hps.lab:b
iscsiadm -m node --logoutall=all
zpool export lab
zpool export other"
  actual="$(grep -v -e '^virsh' -e '^zpool list' "$SHIM_LOG")"
  [ "$actual" = "$expected" ]
  [[ "$output" == *"done: storage quiesced"* ]]
}

@test "each step is logged as it is run" {
  run bash "$SCRIPT"
  [[ "$output" == *"stopping guest g1"* ]]
  [[ "$output" == *"stopping mirror m0"* ]]
  [[ "$output" == *"removing iSCSI target iqn.2026-11.hps.lab:a"* ]]
  [[ "$output" == *"exporting pool lab"* ]]
  [[ "$output" == *"+ timeout 2 zpool export lab"* ]]
}

@test "pools are exported only after the mirrors, targets and sessions" {
  run bash "$SCRIPT"
  p=$(grep -n '^zpool export lab' "$SHIM_LOG" | cut -d: -f1)
  for pat in '^mirror-stop' '^iscsi-unexport' '^iscsiadm'; do
    n=$(grep -n "$pat" "$SHIM_LOG" | tail -1 | cut -d: -f1)
    [ "$n" -lt "$p" ]
  done
}

@test "a failing step is a fault, the sequence goes on, the exit is 1" {
  FAKE_FAIL=mirror-stop run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAULT: mirror m0 did not stop"* ]]
  grep -q '^zpool export lab' "$SHIM_LOG"
}

@test "a pool that will not export is a fault and the next pool is still tried" {
  FAKE_ZPOOL_EXPORT_RC=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAULT: pool lab was not exported"* ]]
  grep -q '^zpool export other' "$SHIM_LOG"
}

@test "a hung step is cut off by its timeout and logged, then the rest runs" {
  export HPS_SHUTDOWN_STEP_TIMEOUT=1
  FAKE_HANG=iscsi-unexport run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout after 1 s"* ]]
  grep -q '^zpool export lab' "$SHIM_LOG"
}

@test "a hung guest stop is bounded by the guest timeout plus the step timeout" {
  export HPS_SHUTDOWN_STEP_TIMEOUT=1
  export HPS_SHUTDOWN_GUEST_TIMEOUT=0
  FAKE_HANG=vm-stop run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout after 1 s"* ]]
  grep -q '^mirror-stop m0' "$SHIM_LOG"
}

@test "iSCSI logout with no sessions (exit 21) is not a fault" {
  FAKE_ISCSIADM_RC=21 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "other iSCSI logout failures are faults" {
  FAKE_ISCSIADM_RC=9 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAULT: iSCSI logout exited 9"* ]]
}

@test "a storage-only node (no virsh, no mirrors, no targets, no iscsiadm) still exports its pools" {
  rm "$TEST_DIR/bin/virsh" "$TEST_DIR/bin/iscsiadm"
  rm -rf "$TEST_DIR/mirrors" "$TEST_DIR/iscsi"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^zpool export lab' "$SHIM_LOG"
}
