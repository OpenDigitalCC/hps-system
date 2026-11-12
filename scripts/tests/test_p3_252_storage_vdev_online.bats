#!/usr/bin/env bats
#
# storage-vdev-online: onlines a returned disk of a pool (zpool online, then
# zpool clear) and reports POOL and VDEV lines. Proves: argument checks before
# any command; ONLINE is a no-op; a device that is not present is exit 3
# "not present" with nothing changed; REMOVED/OFFLINE/FAULTED/UNAVAIL with the
# device back are onlined and cleared, the resilver reported; DEGRADED and an
# unknown vdev are refused; never replace, detach, remove, labelclear or create.

bats_require_minimum_version 1.5.0
load p2_30_helpers

V=virtio-s1-sch-001-d3

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-252.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_disks
  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
case "$1" in
  list)
    [[ -e "$STATE/pool-imported" ]] || exit 1
    if [[ "$*" == *health* ]]; then
      if [[ -e "$STATE/onlined" && -e "$STATE/health-after" ]]; then cat "$STATE/health-after"; else cat "$STATE/health"; fi
    fi
    exit 0 ;;
  status)
    if [[ -e "$STATE/onlined" ]]; then cat "$STATE/status-after"; else cat "$STATE/status"; fi
    exit 0 ;;
  online) touch "$STATE/onlined"; exit "${FAKE_ONLINE_RC:-0}" ;;
  clear) exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/zpool"
  touch "$STATE/pool-imported"
  echo DEGRADED > "$STATE/health"
  echo ONLINE > "$STATE/health-after"
  status_with REMOVED "" > "$STATE/status"
  status_with ONLINE "  scan: resilver in progress since Thu Nov 12 15:20:01 2026" > "$STATE/status-after"
  SCRIPT="$S/storage-vdev-online"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# status_with <state of d3> <scan line>: a zpool status of a three-way mirror.
status_with() {
  printf '  pool: s1\n state: DEGRADED\n'
  [[ -n "$2" ]] && printf '%s\n' "$2"
  printf 'config:\n\n\tNAME                      STATE     READ WRITE CKSUM\n'
  printf '\ts1                        DEGRADED     0     0     0\n'
  printf '\t  mirror-0                DEGRADED     0     0     0\n'
  printf '\t    virtio-s1-sch-001-d1  ONLINE       0     0     0\n'
  printf '\t    virtio-s1-sch-001-d2  ONLINE       0     0     0\n'
  printf '\t    virtio-s1-sch-001-d3  %s      0     0     0\n' "$1"
  printf '\nerrors: No known data errors\n'
}

no_destruction() {
  run ! grep -E '^zpool (replace|detach|remove|labelclear|create|destroy|export|import|attach|split|offline)' "$SHIM_LOG"
}

@test "is executable, env shebang, set -euo pipefail, run() logger, shellcheck clean, allowlisted" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
  local ctrl="$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  [ "$(grep -c '^      storage-vdev-online\.source = mkScript "storage-vdev-online" (scriptsDir + "/storage-vdev-online");' "$ctrl")" -eq 1 ]
  [ "$(grep -c '^      storage-vdev-online\.options\.profile = "node";' "$ctrl")" -eq 1 ]
  run ! grep -q '^      storage-vdev-online\.options\.input' "$ctrl"
  run ! grep -qE 'zpool (replace|detach|remove|labelclear)' "$SCRIPT"
}

@test "usage: wrong argument counts and options exit 2; bad names exit 3; nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1 "$V" extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" -f "$V"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1 --force
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
  for v in "/dev/disk/by-id/$V" "../$V" "a..b" "$V;id" "$V x" '$(id)' "_x" "$(printf 'a%.0s' $(seq 1 129))"; do
    run bash "$SCRIPT" s1 "$v"
    [ "$status" -eq 3 ] || { echo "accepted: [$v]"; false; }
  done
  run bash "$SCRIPT" 'S1;x' "$V"
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a pool that is not imported is refused (3)" {
  rm "$STATE/pool-imported"
  run bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 3 ]
  [[ "$output" == *"not imported"* ]]
  no_destruction
}

@test "a name that is not a vdev of the pool is refused (3), nothing changed" {
  run --separate-stderr bash "$SCRIPT" s1 virtio-other-d9
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"is not a vdev of pool 's1'"* ]]
  run ! grep -q '^zpool online' "$SHIM_LOG"
}

@test "an ONLINE vdev is a no-op: exit 0, reported, nothing onlined" {
  status_with ONLINE "" > "$STATE/status"
  echo ONLINE > "$STATE/health"
  run --separate-stderr bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VDEV s1 $V ONLINE resilver=no" ]
  [ "${lines[-2]}" = "POOL s1 ONLINE" ]
  run ! grep -qE '^zpool (online|clear)' "$SHIM_LOG"
}

@test "REMOVED with the device absent: exit 3 not present, nothing changed" {
  touch "$STATE/missing.$V"
  run --separate-stderr bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not present: /dev/disk/by-id/$V does not exist"* ]]
  [ "${lines[-1]}" = "VDEV s1 $V REMOVED resilver=no" ]
  run ! grep -qE '^zpool (online|clear)' "$SHIM_LOG"
  no_destruction
}

@test "REMOVED with the device back: zpool online then clear, ONLINE with a resilver" {
  run --separate-stderr bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VDEV s1 $V ONLINE resilver=yes" ]
  [ "${lines[-2]}" = "POOL s1 ONLINE" ]
  [ "$(grep -nE '^zpool (online|clear)' "$SHIM_LOG" | cut -d: -f2-)" = "$(printf 'zpool online s1 %s\nzpool clear s1 %s' "$V" "$V")" ]
  grep -qxF "readlink -e /dev/disk/by-id/$V" "$SHIM_LOG"
  [[ "$stderr" == *"+ zpool online s1 $V"* ]]
  no_destruction
}

@test "OFFLINE, FAULTED and UNAVAIL are onlined too; resilver=no when none runs" {
  status_with ONLINE "" > "$STATE/status-after"
  for st in OFFLINE FAULTED UNAVAIL; do
    rm -f "$STATE/onlined"
    status_with "$st" "" > "$STATE/status"
    run bash "$SCRIPT" s1 "$V"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "VDEV s1 $V ONLINE resilver=no" ]
  done
}

@test "DEGRADED is refused (3): online does not apply" {
  status_with DEGRADED "" > "$STATE/status"
  run --separate-stderr bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"online does not apply"* ]]
  [[ "$stderr" != *"not present"* ]]
  run ! grep -q '^zpool online' "$SHIM_LOG"
}

@test "still not ONLINE after zpool online: exit 1; a failing zpool online: exit 1" {
  status_with UNAVAIL "" > "$STATE/status-after"
  run --separate-stderr bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "VDEV s1 $V UNAVAIL resilver=no" ]
  rm -f "$STATE/onlined"
  : > "$SHIM_LOG"
  FAKE_ONLINE_RC=1 run bash "$SCRIPT" s1 "$V"
  [ "$status" -eq 1 ]
  run ! grep -q '^zpool clear' "$SHIM_LOG"
}
