#!/usr/bin/env bats
#
# CS-3.2: mirror-create. Exact mdadm flags, write-mostly on the remote leg only,
# no wipe without a mirror-create approval, idempotency.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-11.XXXXXX")"
  export TEST_DIR
  p3_setup
  SCRIPT="$S/mirror-create"
  p3_make_local
  p3_make_remote
  echo "tcp: [1] 10.99.1.2:3260,1 iqn.2026-01.hps.example:vm1-disk0 (non-flash)" > "$STATE/sessions"
}

teardown() {
  rm -rf "$TEST_DIR"
}

create() {
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" "$@"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2, bad name or spec 3, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" vm1-disk0 --leg a --leg b --remote-index 2
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 'x;y' --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC"
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg bogus
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_LOC_SPEC"
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "clean devices, no approval: exact mdadm --create, local first, --write-mostly then the remote" {
  create
  [ "$status" -eq 0 ]
  grep -qxF "mdadm --create /dev/md/vm1-disk0 --run --level=1 --raid-devices=2 --metadata=1.2 --bitmap=internal --name=vm1-disk0 $LOCDEV --write-mostly $REMDEV" "$SHIM_LOG"
  grep -qxF 'mdadm --detail /dev/md/vm1-disk0' "$SHIM_LOG"
  run ! grep -E 'wipefs|--zero-superblock|--force|--assume-clean' "$SHIM_LOG"
}

@test "the order of --leg does not move the write-mostly flag off the remote" {
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_REM_SPEC" --leg "$P3_LOC_SPEC"
  [ "$status" -eq 0 ]
  grep -qF -- "$LOCDEV --write-mostly $REMDEV" "$SHIM_LOG"
}

@test "sidecar records legs, kinds and the remote index" {
  create
  [ "$status" -eq 0 ]
  [ "$(jq -r '.remote_index' "$HPS_MIRROR_DIR/vm1-disk0.json")" = 1 ]
  [ "$(jq -r '.legs[0].kind + "," + .legs[1].kind' "$HPS_MIRROR_DIR/vm1-disk0.json")" = "local,remote" ]
  [ "$(jq -r '.legs[1].write_mostly' "$HPS_MIRROR_DIR/vm1-disk0.json")" = 1 ]
  [ "$(jq -r '.legs[0].dev' "$HPS_MIRROR_DIR/vm1-disk0.json")" = "$LOCDEV" ]
}

@test "--remote-index must not name a local leg" {
  create --remote-index 0
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a signature without approval is refused and nothing is changed" {
  touch "$STATE/blkid.vm1-disk0"
  create
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not clean"* ]]
  run ! grep -E -- '--create|wipefs|--zero-superblock' "$SHIM_LOG"
}

@test "an md superblock without approval is refused" {
  p3_sb_agreeing
  create
  [ "$status" -eq 3 ]
  run ! grep -E -- '--create|wipefs|--zero-superblock' "$SHIM_LOG"
}

@test "a signature with a valid wipe approval: announced, wiped, then created" {
  touch "$STATE/blkid.vm1-disk0"
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" --approval-file - <<< "$(p3_declaration mirror-create vm1-disk0 4102444800 aabbccddeeff "$P3_LEGS_JSON" 1)"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WILL WIPE: $P3_LOC_SPEC"* ]]
  grep -qxF "wipefs -a $LOCDEV" "$SHIM_LOG"
  run ! grep -F "wipefs -a $REMDEV" "$SHIM_LOG"
  grep -q '^mdadm --create' "$SHIM_LOG"
}

@test "approvals that are wrong are refused: wipe=0, other action, mirror, node, legs, expiry, HMAC" {
  touch "$STATE/blkid.vm1-disk0"
  local bad=(
    "$(p3_declaration mirror-create vm1-disk0 4102444800 aabbccddeeff "$P3_LEGS_JSON" 0)"
    "$(p3_declaration peer-gone vm1-disk0 4102444800 aabbccddeeff "$P3_LEGS_JSON" 1)"
    "$(p3_declaration mirror-create vm2-disk0 4102444800 aabbccddeeff "$P3_LEGS_JSON" 1)"
    "$(p3_declaration mirror-create vm1-disk0 4102444800 112233445566 "$P3_LEGS_JSON" 1)"
    "$(p3_declaration mirror-create vm1-disk0 4102444800 aabbccddeeff '["local:lab/enc/vm/vm1-disk0","local:lab/enc/vm/other"]' 1)"
    "$(p3_declaration mirror-create vm1-disk0 1000000000 aabbccddeeff "$P3_LEGS_JSON" 1)"
    "$(p3_declaration mirror-create vm1-disk0 4102444800 aabbccddeeff "$P3_LEGS_JSON" 1 | jq -c '.approval.hmac = ("0" * 64)')"
    "nonsense"
    ""
  )
  local doc
  for doc in "${bad[@]}"; do
    run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" --approval-file - <<< "$doc"
    [ "$status" -eq 3 ]
  done
  run ! grep -E -- '--create|wipefs|--zero-superblock' "$SHIM_LOG"
}

@test "the Perl-issued fixture document verifies in the Bash verifier" {
  touch "$STATE/blkid.vm1-disk0"
  local doc
  doc=$(jq -n -c --slurpfile a "$FIX/approval-mirror-create.json" --rawfile h "$FIX/approval-mirror-create.hmac" --rawfile s "$FIX/approval-canonical.secret.hex" \
    '{approval:($a[0] + {hmac:($h | rtrimstr("\n"))}),secret:($s | rtrimstr("\n"))}')
  run bash "$SCRIPT" vm1-disk0 --leg "$P3_LOC_SPEC" --leg "$P3_REM_SPEC" --approval-file - <<< "$doc"
  [ "$status" -eq 0 ]
}

@test "idempotent: the array exists with these legs -> exit 0, no second create" {
  create
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  create
  [ "$status" -eq 0 ]
  run ! grep -E -- '--create|wipefs|blkid' "$SHIM_LOG"
  [ -s "$HPS_MIRROR_DIR/vm1-disk0.json" ]
}

@test "the array exists with other members -> refused" {
  printf '   State : clean\n   /dev/other1\n   /dev/other2\n' > "$STATE/detail.vm1-disk0"
  create
  [ "$status" -eq 3 ]
  run ! grep -- '--create' "$SHIM_LOG"
}

@test "a failing mdadm --create is exit 1" {
  FAKE_CREATE_RC=1 create
  [ "$status" -eq 1 ]
}

@test "both legs remote: no write-mostly unless --remote-index says which" {
  touch "$HPS_DEV/disk/by-path/ip-10.99.1.3:3260-iscsi-iqn.2026-01.hps.example:other-lun-0"
  echo "tcp: [2] 10.99.1.3:3260,1 iqn.2026-01.hps.example:other (non-flash)" >> "$STATE/sessions"
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_REM_SPEC" --leg iscsi:10.99.1.3:iqn.2026-01.hps.example:other
  [ "$status" -eq 0 ]
  run ! grep -- '--write-mostly' "$SHIM_LOG"
  rm -f "$STATE/detail.vm1-disk0"
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SCRIPT" vm1-disk0 --leg "$P3_REM_SPEC" --leg iscsi:10.99.1.3:iqn.2026-01.hps.example:other --remote-index 1
  [ "$status" -eq 0 ]
  grep -qF -- "$REMDEV --write-mostly $HPS_DEV/disk/by-path/ip-10.99.1.3:3260-iscsi-iqn.2026-01.hps.example:other-lun-0" "$SHIM_LOG"
}
