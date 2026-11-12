#!/usr/bin/env bats
#
# CS-3.2: mirror-status, mirror-rejoin, mirror-stop, mirror-detach-leg.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-13.XXXXXX")"
  export TEST_DIR
  p3_setup
  p3_make_local
  p3_make_remote
  echo "tcp: [1] 10.99.1.2:3260,1 iqn.2026-01.hps.example:vm1-disk0 (non-flash)" > "$STATE/sessions"
  # a running mirror, built the way a workload builds it
  bash "$S/mirror-create" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" 2> /dev/null > /dev/null
  : > "$SHIM_LOG"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# the remote leg has dropped out
p3_degraded() {
  printf '           State : clean, degraded\n   Active Devices : 1\n   %s\n' "$LOCDEV" > "$STATE/detail.vm1-disk0"
}

@test "all four scripts: executable, env shebang, set -euo pipefail, shellcheck clean" {
  local s
  for s in mirror-status mirror-rejoin mirror-stop mirror-detach-leg; do
    [ -x "$S/$s" ]
    [ "$(head -1 "$S/$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$S/$s"
    shellcheck -S warning "$S/$s"
  done
}

@test "usage errors exit 2" {
  run bash "$S/mirror-status" a b
  [ "$status" -eq 2 ]
  run bash "$S/mirror-rejoin" vm1-disk0
  [ "$status" -eq 2 ]
  run bash "$S/mirror-stop"
  [ "$status" -eq 2 ]
  run bash "$S/mirror-detach-leg" vm1-disk0
  [ "$status" -eq 2 ]
}

@test "status: clean mirror, legs with kinds, last line MIRROR <name> clean" {
  run --separate-stderr bash "$S/mirror-status" vm1-disk0
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "MIRROR vm1-disk0 clean" ]
  [[ "$output" == *"LEG $P3_LOC_SPEC kind=local dev=$LOCDEV write_mostly=0"* ]]
  [[ "$output" == *"LEG $P3_REM_SPEC kind=remote dev=$REMDEV write_mostly=1"* ]]
  [[ "$output" == *"Intent Bitmap : Internal"* ]]
}

@test "status: degraded, resyncing, absent, unknown mirror, and no argument lists all" {
  p3_degraded
  run --separate-stderr bash "$S/mirror-status" vm1-disk0
  [ "${lines[-1]}" = "MIRROR vm1-disk0 degraded" ]
  printf '           State : clean, degraded, recovering\n Rebuild Status : 12%% complete\n' > "$STATE/detail.vm1-disk0"
  run --separate-stderr bash "$S/mirror-status" vm1-disk0
  [ "${lines[-1]}" = "MIRROR vm1-disk0 resyncing" ]
  rm "$STATE/detail.vm1-disk0"
  run --separate-stderr bash "$S/mirror-status" vm1-disk0
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "MIRROR vm1-disk0 absent" ]
  run bash "$S/mirror-status" nosuch
  [ "$status" -eq 3 ]
  run --separate-stderr bash "$S/mirror-status"
  [ "${lines[-1]}" = "MIRROR vm1-disk0 absent" ]
  rm "$HPS_MIRROR_DIR/vm1-disk0.json"
  run --separate-stderr bash "$S/mirror-status"
  [ "$output" = "no mirrors" ]
}

@test "status changes nothing" {
  bash "$S/mirror-status" vm1-disk0 > /dev/null 2>&1
  p3_no_state_change
}

@test "rejoin: --re-add of the returning leg, never --add, never --force; resync reported; sidecar kept" {
  p3_degraded
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 55 "$P3_T1" 1 AA
  run --separate-stderr bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qxF "mdadm /dev/md/vm1-disk0 --re-add --failfast $REMDEV" "$SHIM_LOG"
  run ! grep -E -- '--add|--force|--create|--assemble' "$SHIM_LOG"
  [[ "$stderr" == *"resync of $P3_REM_SPEC from the bitmap started"* ]]
  [ "$(jq -r '.legs[1].dev' "$HPS_MIRROR_DIR/vm1-disk0.json")" = "$REMDEV" ]
}

@test "rejoin of a diverged leg is refused with the DIVERGED line and nothing changes" {
  p3_degraded
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 58 "$P3_T1" 1 '.A'
  run --separate-stderr bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  [[ "$output" == "DIVERGED vm1-disk0 legA events=60 "*" legB events=58 "* ]]
  p3_no_state_change
}

@test "rejoin: a failed re-add is exit 1 and is not retried as --add" {
  p3_degraded
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 55 "$P3_T1" 1 AA
  FAKE_READD_RC=1 run bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 1 ]
  run ! grep -E -- ' --add' "$SHIM_LOG"
}

@test "rejoin: not assembled, no sidecar, unknown leg -> refused" {
  rm "$STATE/detail.vm1-disk0"
  run bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  p3_degraded
  run bash "$S/mirror-rejoin" vm1-disk0 --leg "iscsi:10.99.1.9:iqn.2026-01.hps.example:zzz"
  [ "$status" -eq 3 ]
  rm "$HPS_MIRROR_DIR/vm1-disk0.json"
  run bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  p3_no_state_change
}

@test "rejoin is idempotent: a leg that is already a member changes nothing" {
  run --separate-stderr bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  p3_no_state_change
}

@test "stop: mdadm --stop and the sidecar is gone; second run exits 0 and does nothing" {
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -qxF 'mdadm --stop /dev/md/vm1-disk0' "$SHIM_LOG"
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
  : > "$SHIM_LOG"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  run ! grep -- '--stop' "$SHIM_LOG"
}

@test "stop refuses while in use: a holder, or a mount" {
  mkdir -p "$HPS_SYS/block/vm1-disk0/holders/dm-3"
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
  rm -r "$HPS_SYS/block/vm1-disk0/holders/dm-3"
  echo "/dev/md/vm1-disk0 /var/lib/x ext4 rw 0 0" > "$HPS_PROC_MOUNTS"
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"mounted"* ]]
  run ! grep -- '--stop' "$SHIM_LOG"
  [ -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "stop refuses while a running libvirt guest lists the device; no guest -> stops" {
  cat > "$TEST_DIR/bin/virsh" <<'V'
#!/usr/bin/env bash
case "$1" in
  list) printf 'vm1\n' ;;
  domblklist) printf 'Target Source\n---\nvda /dev/md/vm1-disk0\n' ;;
esac
V
  chmod +x "$TEST_DIR/bin/virsh"
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"running guest vm1"* ]]
  run ! grep -- '--stop' "$SHIM_LOG"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/bin/virsh"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -q -- '--stop' "$SHIM_LOG"
}

@test "detach-leg: --fail then --remove of the leg's device" {
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qxF "mdadm /dev/md/vm1-disk0 --fail $REMDEV" "$SHIM_LOG"
  grep -qxF "mdadm /dev/md/vm1-disk0 --remove $REMDEV" "$SHIM_LOG"
  local f r
  f=$(grep -n -- '--fail' "$SHIM_LOG" | head -1 | cut -d: -f1)
  r=$(grep -n -- '--remove' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$f" -lt "$r" ]
}

@test "detach-leg is idempotent and refuses the last active leg, unknown legs and a stopped mirror" {
  bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC" > /dev/null 2>&1
  : > "$SHIM_LOG"
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  p3_no_state_change
  printf '   Active Devices : 1\n   %s\n   %s\n' "$LOCDEV" "$REMDEV" > "$STATE/detail.vm1-disk0"
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_LOC_SPEC"
  [ "$status" -eq 3 ]
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "iscsi:10.99.1.9:iqn.2026-01.hps.example:zzz"
  [ "$status" -eq 3 ]
  rm "$STATE/detail.vm1-disk0"
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  p3_no_state_change
}
