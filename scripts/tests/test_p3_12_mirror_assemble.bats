#!/usr/bin/env bats
#
# CS-3.2: mirror-assemble. Plain assemble (never --force), degraded assembly
# only under a valid peer-gone declaration, divergence refused with the DIVERGED
# line and no state-changing call, idempotency.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-12.XXXXXX")"
  export TEST_DIR
  p3_setup
  SCRIPT="$S/mirror-assemble"
  p3_make_local
  p3_make_remote
  echo "tcp: [1] 10.99.1.2:3260,1 iqn.2026-01.hps.example:vm1-disk0 (non-flash)" > "$STATE/sessions"
}

teardown() {
  rm -rf "$TEST_DIR"
}

assemble() {
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" "$@"
}

assemble_decl() {
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" --declaration-file - <<< "$1"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" vm1-disk0 --leg a --leg b --bogus
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "both legs present and agreeing: plain mdadm --assemble of the two devices" {
  p3_sb_agreeing
  assemble
  [ "$status" -eq 0 ]
  grep -qxF "mdadm --assemble /dev/md/vm1-disk0 $LOCDEV $REMDEV" "$SHIM_LOG"
  run ! grep -E -- '--force|--run' "$SHIM_LOG"
  [ "$(jq -r '.legs | length' "$HPS_MIRROR_DIR/vm1-disk0.json")" = 2 ]
}

@test "--force appears nowhere in any shim call across every assemble path" {
  p3_sb_agreeing
  assemble
  rm -f "$STATE/detail.vm1-disk0"
  rm -f "$REMDEV"
  assemble_decl "$(p3_declaration)"
  [ "$status" -eq 0 ]
  rm -f "$STATE/detail.vm1-disk0"
  p3_make_remote
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 58 "$P3_T1" 1 '.A'
  assemble
  [ "$status" -eq 3 ]
  run ! grep -e '--force' "$SHIM_LOG"
  run ! grep -e '-f ' "$SHIM_LOG"
}

@test "a lagging leg (the other left it, lower events) is not divergence: plain assemble" {
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 55 "$P3_T1" 1 AA
  assemble
  [ "$status" -eq 0 ]
  grep -qxF "mdadm --assemble /dev/md/vm1-disk0 $LOCDEV $REMDEV" "$SHIM_LOG"
}

@test "both legs left each other: DIVERGED line on stdout, exit 3, nothing changed" {
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 58 "$P3_T1" 1 '.A'
  assemble
  [ "$status" -eq 3 ]
  [ "$output" = "DIVERGED vm1-disk0 legA events=60 time=$(date -d "$P3_T2" +%s) legB events=58 time=$(date -d "$P3_T1" +%s)" ]
  p3_no_state_change
  [ ! -e "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "one leg left the other but the other has more events: DIVERGED" {
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 70 "$P3_T2" 1 AA
  assemble
  [ "$status" -eq 3 ]
  [[ "$output" == "DIVERGED vm1-disk0 legA events=60 "*" legB events=70 "* ]]
  p3_no_state_change
}

@test "a declaration cannot override divergence (both legs present)" {
  p3_sb "$LOCDEV" "$P3_UUID" 60 "$P3_T2" 0 'A.'
  p3_sb "$REMDEV" "$P3_UUID" 58 "$P3_T1" 1 '.A'
  assemble_decl "$(p3_declaration)"
  [ "$status" -eq 3 ]
  [[ "$output" == DIVERGED* ]]
  p3_no_state_change
}

@test "different arrays, no superblock, or a spare role are refused" {
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  p3_sb "$REMDEV" "other:uuid" 50 "$P3_T1" 1 AA
  assemble
  [ "$status" -eq 3 ]
  rm "$STATE/examine.$P3_REM_NAME"
  assemble
  [ "$status" -eq 3 ]
  p3_sb "$REMDEV" "$P3_UUID" 50 "$P3_T1" 1 AA
  sed -i 's/Active device 1/spare/' "$STATE/examine.$P3_REM_NAME"
  assemble
  [ "$status" -eq 3 ]
  p3_no_state_change
}

@test "one leg missing, no declaration: refused, nothing assembled" {
  rm -f "$REMDEV"
  touch "$STATE/nolun"
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  assemble
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"peer-gone declaration"* ]]
  p3_no_state_change
}

@test "one leg missing, valid peer-gone declaration: mdadm --assemble --run of the present leg, no --force" {
  rm -f "$REMDEV"
  touch "$STATE/nolun"
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  assemble_decl "$(p3_declaration)"
  [ "$status" -eq 0 ]
  grep -qxF "mdadm --assemble --run /dev/md/vm1-disk0 $LOCDEV" "$SHIM_LOG"
  run ! grep -e '--force' "$SHIM_LOG"
  [ "$(jq -r '.legs[1].dev' "$HPS_MIRROR_DIR/vm1-disk0.json")" = "" ]
}

@test "the local leg missing is assembled from the remote under a declaration" {
  rm -f "$LOCDEV"
  p3_sb "$REMDEV" "$P3_UUID" 50 "$P3_T1" 1 AA
  assemble_decl "$(p3_declaration)"
  [ "$status" -eq 0 ]
  grep -qxF "mdadm --assemble --run /dev/md/vm1-disk0 $REMDEV" "$SHIM_LOG"
}

@test "the Perl-issued peer-gone fixture is accepted by the Bash verifier" {
  rm -f "$REMDEV"
  touch "$STATE/nolun"
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  local doc
  doc=$(jq -n -c --slurpfile a "$FIX/approval-peer-gone.json" --rawfile h "$FIX/approval-peer-gone.hmac" --rawfile s "$FIX/approval-canonical.secret.hex" \
    '{approval:($a[0] + {hmac:($h | rtrimstr("\n"))}),secret:($s | rtrimstr("\n"))}')
  assemble_decl "$doc"
  [ "$status" -eq 0 ]
}

@test "declarations that are wrong are refused: mirror, node, legs, action, expiry, HMAC, garbage" {
  rm -f "$REMDEV"
  touch "$STATE/nolun"
  p3_sb "$LOCDEV" "$P3_UUID" 50 "$P3_T1" 0 AA
  local bad=(
    "$(p3_declaration peer-gone vm2-disk0)"
    "$(p3_declaration peer-gone vm1-disk0 4102444800 112233445566)"
    "$(p3_declaration peer-gone vm1-disk0 4102444800 aabbccddeeff '["local:lab/enc/vm/vm1-disk0","iscsi:10.99.1.9:iqn.2026-01.hps.example:other"]')"
    "$(p3_declaration mirror-create vm1-disk0)"
    "$(p3_declaration pool-destroy vm1-disk0)"
    "$(p3_declaration peer-gone vm1-disk0 1000000000)"
    "$(p3_declaration | jq -c '.approval.hmac = ("0" * 64)')"
    "$(p3_declaration | jq -c '.secret = ("1" * 64)')"
    "nonsense"
    ""
  )
  local doc
  for doc in "${bad[@]}"; do
    assemble_decl "$doc"
    [ "$status" -eq 3 ]
  done
  p3_no_state_change
}

@test "both legs missing is refused even with a declaration" {
  rm -f "$REMDEV" "$LOCDEV"
  touch "$STATE/nolun"
  assemble_decl "$(p3_declaration)"
  [ "$status" -eq 3 ]
  p3_no_state_change
}

@test "idempotent: already assembled -> exit 0 and no mdadm change; twice with both legs" {
  p3_sb_agreeing
  assemble
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  assemble
  [ "$status" -eq 0 ]
  p3_no_state_change
  # sidecar rebuilt if /run was cleared by a reboot while md autoassembled the array
  rm -f "$HPS_MIRROR_DIR/vm1-disk0.json"
  assemble
  [ "$status" -eq 0 ]
  [ -s "$HPS_MIRROR_DIR/vm1-disk0.json" ]
  p3_no_state_change
}

@test "a failing mdadm --assemble is exit 1" {
  p3_sb_agreeing
  FAKE_ASSEMBLE_RC=1 assemble
  [ "$status" -eq 1 ]
}
