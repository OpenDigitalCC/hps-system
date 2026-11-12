#!/usr/bin/env bats
#
# Mirror legs fail fast (owner ruling 2026-11-12: a lost leg is an outage after
# 15 s, never a blocking stall): iSCSI timeouts on every leg login, md failfast
# on create / assemble / rejoin, and the iSCSI logout on mirror-stop and
# mirror-detach-leg. Stateful shims (p3_10_helpers); nix is checked by grep
# here and by `nix flake check` for real.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers

IQN="iqn.2026-01.hps.example:vm1-disk0"
IP="10.99.1.2"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-240.XXXXXX")"
  export TEST_DIR
  p3_setup
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  COMPUTE="$ROOT/nix/modules/profiles/compute.nix"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# A running mirror of a local and a remote leg, logged in through leg-resolve
# (so the session and the node record exist), shim log cleared.
p240_mirror() {
  p3_make_local
  bash "$S/mirror-create" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" > /dev/null 2>&1
  : > "$SHIM_LOG"
}

# ---- leg login timeouts ---------------------------------------------------

@test "leg-resolve: the four timeouts are constants in one place, with the ruled values" {
  local f="$S/leg-resolve"
  [ "$(grep -c '^ISCSI_TIMEOUTS=(' "$f")" -eq 1 ]
  grep -qxF '  "node.session.timeo.replacement_timeout=15"' "$f"
  grep -qxF '  "node.conn[0].timeo.noop_out_interval=5"' "$f"
  grep -qxF '  "node.conn[0].timeo.noop_out_timeout=5"' "$f"
  grep -qxF '  "node.conn[0].timeo.login_timeout=15"' "$f"
  run ! grep -nE 'replacement_timeout|noop_out|login_timeout' <(grep -vE '^#|^  "node\.' "$f")
}

@test "leg-resolve: each timeout is written to the node record after discovery, before login" {
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  local k d l u
  for k in "node.session.timeo.replacement_timeout -v 15" "node.conn[0].timeo.noop_out_interval -v 5" \
    "node.conn[0].timeo.noop_out_timeout -v 5" "node.conn[0].timeo.login_timeout -v 15"; do
    grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n $k" "$SHIM_LOG"
    [[ "$stderr" == *"+ iscsiadm -m node -T $IQN -p $IP -o update -n $k"* ]]
  done
  d=$(grep -n -- '-m discovery' "$SHIM_LOG" | cut -d: -f1)
  l=$(grep -n -- '--login' "$SHIM_LOG" | cut -d: -f1)
  for u in $(grep -n -- '-o update' "$SHIM_LOG" | cut -d: -f1); do
    [ "$d" -lt "$u" ]
    [ "$u" -lt "$l" ]
  done
  [ "$(grep -c -- '-o update' "$SHIM_LOG")" -eq 4 ]
}

@test "leg-resolve: a device already present means no login and no record update" {
  p3_make_remote
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  run ! grep -E -- '-o update|--login' "$SHIM_LOG"
}

@test "leg-resolve: a local leg never touches iscsiadm" {
  p3_make_local
  run bash "$S/leg-resolve" "$P3_LOC_SPEC"
  [ "$status" -eq 0 ]
  run ! grep '^iscsiadm' "$SHIM_LOG"
}

@test "compute profile: iscsid.conf defaults carry the same four values as leg-resolve" {
  local block kv
  block="$(sed -n '/services.openiscsi = {/,/^  };/p' "$COMPUTE")"
  [[ "$block" == *"extraConfig = ''"* ]]
  while IFS= read -r kv; do
    [[ "$block" == *"${kv%%=*} = ${kv#*=}"* ]]
  done < <(sed -n '/^ISCSI_TIMEOUTS=(/,/^)/{s/^  "\(.*\)"$/\1/p}' "$S/leg-resolve")
  [ "$(sed -n '/^ISCSI_TIMEOUTS=(/,/^)/{s/^  "\(.*\)"$/\1/p}' "$S/leg-resolve" | wc -l)" -eq 4 ]
}

# ---- md failfast ----------------------------------------------------------

@test "mirror-create: --failfast before the first leg, so it covers both (one remote leg)" {
  p3_make_local
  run bash "$S/mirror-create" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qE -- "^mdadm --create .* --failfast $LOCDEV --write-mostly $REMDEV\$" "$SHIM_LOG"
}

@test "mirror-create: --failfast covers both legs when neither is write-mostly" {
  local other="iscsi:10.99.1.3:iqn.2026-01.hps.example:other"
  local odev="$HPS_DEV/disk/by-path/ip-10.99.1.3:3260-iscsi-iqn.2026-01.hps.example:other-lun-0"
  run bash "$S/mirror-create" vm1-disk0 --leg "$P3_REM_SPEC" --leg "$other"
  [ "$status" -eq 0 ]
  grep -qE -- "^mdadm --create .* --name=vm1-disk0 --failfast $REMDEV $odev\$" "$SHIM_LOG"
  run ! grep -- '--write-mostly' "$SHIM_LOG"
}

p240_sysfs_md() {
  mkdir -p "$HPS_DEV/md" "$HPS_SYS/block/md127/md/dev-zd16" "$HPS_SYS/block/md127/md/dev-sdc"
  : > "$HPS_DEV/md127"
  ln -s ../md127 "$HPS_DEV/md/vm1-disk0"
  echo in_sync > "$HPS_SYS/block/md127/md/dev-zd16/state"
  echo in_sync > "$HPS_SYS/block/md127/md/dev-sdc/state"
}

@test "mirror-assemble: every member is set failfast through sysfs, logged" {
  p3_make_local
  p3_make_remote
  p3_sb_agreeing
  p240_sysfs_md
  run --separate-stderr bash "$S/mirror-assemble" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_SYS/block/md127/md/dev-zd16/state")" = failfast ]
  [ "$(cat "$HPS_SYS/block/md127/md/dev-sdc/state")" = failfast ]
  [[ "$stderr" == *"+ echo failfast > $HPS_SYS/block/md127/md/dev-sdc/state"* ]]
  [[ "$stderr" == *"failfast set on 2 member(s) of vm1-disk0"* ]]
  grep -qxF "mdadm --assemble /dev/md/vm1-disk0 $LOCDEV $REMDEV" "$SHIM_LOG"
}

@test "mirror-assemble: degraded (--peer-gone) sets failfast on the present member too" {
  p3_make_local
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  touch "$STATE/nolun"
  p240_sysfs_md
  rm -r "$HPS_SYS/block/md127/md/dev-sdc"
  run --separate-stderr bash "$S/mirror-assemble" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" --peer-gone
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_SYS/block/md127/md/dev-zd16/state")" = failfast ]
}

@test "mirror-assemble: no sysfs md directory is a logged warning, the assembly stands (exit 0)" {
  p3_make_local
  p3_make_remote
  p3_sb_agreeing
  run --separate-stderr bash "$S/mirror-assemble" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING: no sysfs md directory for vm1-disk0"* ]]
  [ -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "mirror-assemble: an array already assembled is left alone, failfast not written" {
  p240_sysfs_md
  echo "   State : clean" > "$STATE/detail.vm1-disk0"
  run bash "$S/mirror-assemble" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_SYS/block/md127/md/dev-sdc/state")" = in_sync ]
}

@test "mirror-rejoin: --re-add --failfast, never --add" {
  p240_mirror
  printf '           State : clean, degraded\n   Active Devices : 1\n   %s\n' "$LOCDEV" > "$STATE/detail.vm1-disk0"
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 A.
  p3_sb "$REMDEV" "$P3_UUID" 50 "$P3_T1" 1 AA
  run bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qxF "mdadm /dev/md/vm1-disk0 --re-add --failfast $REMDEV" "$SHIM_LOG"
  run ! grep -E -- ' --add ' "$SHIM_LOG"
}

# ---- logout on stop / detach ----------------------------------------------

@test "mirror-stop: after --stop the iSCSI leg is logged out and its record deleted, in that order" {
  p240_mirror
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --logout" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o delete" "$SHIM_LOG"
  local s o d
  s=$(grep -n -- 'mdadm --stop' "$SHIM_LOG" | cut -d: -f1)
  o=$(grep -n -- '--logout' "$SHIM_LOG" | cut -d: -f1)
  d=$(grep -n -- '-o delete' "$SHIM_LOG" | cut -d: -f1)
  [ "$s" -lt "$o" ]
  [ "$o" -lt "$d" ]
  run ! grep -F "$IQN" "$STATE/sessions"
  run ! grep -F "$IQN" "$STATE/records"
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
  [[ "$stderr" == *"+ iscsiadm -m node -T $IQN -p $IP --logout"* ]]
}

@test "mirror-stop: the local leg is untouched (no iscsiadm names it)" {
  p240_mirror
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  [ "$(grep -c '^iscsiadm' "$SHIM_LOG")" -eq 2 ]
  run ! grep -E '^iscsiadm.*(lab/enc|zvol)' "$SHIM_LOG"
}

@test "mirror-stop: no session and no record (exit 21) is fine" {
  p3_make_local
  p3_make_remote
  bash "$S/mirror-create" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" > /dev/null 2>&1
  : > "$SHIM_LOG"
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --logout" "$SHIM_LOG"
  [[ "$stderr" == *"no matching session or record"* ]]
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "mirror-stop: not assembled, the sidecar's iSCSI legs are still logged out" {
  p240_mirror
  rm "$STATE/detail.vm1-disk0"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  run ! grep -- 'mdadm --stop' "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --logout" "$SHIM_LOG"
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "mirror-stop: both legs remote, both logged out" {
  local other="iscsi:10.99.1.3:iqn.2026-01.hps.example:other"
  bash "$S/mirror-create" vm1-disk0 --leg "$P3_REM_SPEC" --leg "$other" > /dev/null 2>&1
  : > "$SHIM_LOG"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --logout" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T iqn.2026-01.hps.example:other -p 10.99.1.3 --logout" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T iqn.2026-01.hps.example:other -p 10.99.1.3 -o delete" "$SHIM_LOG"
}

@test "mirror-stop: a failing logout exits 1 and keeps the sidecar; a second run retries it" {
  p240_mirror
  FAKE_LOGOUT_RC=8 run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"failed (exit 8)"* ]]
  [ -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
  : > "$SHIM_LOG"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --logout" "$SHIM_LOG"
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "mirror-stop: refused while in use: nothing is logged out" {
  p240_mirror
  echo "/dev/md/vm1-disk0 /var/lib/x ext4 rw 0 0" > "$HPS_PROC_MOUNTS"
  run bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 3 ]
  run ! grep -E -- '--logout|-o delete' "$SHIM_LOG"
}

@test "mirror-stop: no sidecar, no iscsiadm call" {
  run --separate-stderr bash "$S/mirror-stop" vm1-disk0
  [ "$status" -eq 0 ]
  run ! grep '^iscsiadm' "$SHIM_LOG"
}

@test "mirror-detach-leg: the detached iSCSI leg is logged out after --remove" {
  p240_mirror
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  local r o
  r=$(grep -n -- '--remove' "$SHIM_LOG" | cut -d: -f1)
  o=$(grep -n -- '--logout' "$SHIM_LOG" | cut -d: -f1)
  [ "$r" -lt "$o" ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o delete" "$SHIM_LOG"
}

@test "mirror-detach-leg: a local leg is detached without any iscsiadm call" {
  p240_mirror
  run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_LOC_SPEC"
  [ "$status" -eq 0 ]
  run ! grep '^iscsiadm' "$SHIM_LOG"
}

@test "mirror-detach-leg: a failing logout exits 1 after the detach" {
  p240_mirror
  FAKE_LOGOUT_RC=8 run bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 1 ]
  grep -qxF "mdadm /dev/md/vm1-disk0 --remove $REMDEV" "$SHIM_LOG"
}

@test "mirror-rejoin after a detach logs the leg in again through leg-resolve" {
  p240_mirror
  bash "$S/mirror-detach-leg" vm1-disk0 --leg "$P3_REM_SPEC" > /dev/null 2>&1
  rm -f "$REMDEV"
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 A.
  p3_sb "$REMDEV" "$P3_UUID" 50 "$P3_T1" 1 AA
  : > "$SHIM_LOG"
  run bash "$S/mirror-rejoin" vm1-disk0 --leg "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP --login" "$SHIM_LOG"
  grep -qxF "mdadm /dev/md/vm1-disk0 --re-add --failfast $REMDEV" "$SHIM_LOG"
}

@test "changed scripts: shellcheck clean at warning level" {
  local s
  for s in leg-resolve mirror-create mirror-assemble mirror-rejoin mirror-stop mirror-detach-leg; do
    shellcheck -S warning "$S/$s"
  done
}
