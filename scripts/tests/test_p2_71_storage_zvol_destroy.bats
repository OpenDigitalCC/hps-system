#!/usr/bin/env bats
#
# CS-2.5: storage-zvol-destroy. Proves: nothing without a valid approval (HMAC,
# expiry, action, mac, dataset, exact member set), byte-compatibility with the
# HPS::Approval fixture for action zvol-destroy (t/fixtures, pinned by
# t/50-zvol-approval.t), the refusals (not a zvol, exported, in use), the exact
# destroy, and that nothing else is destroyed.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p2_70_helpers

DS=lab/enc/t0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-71.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_xxd
  p2_shim_zfs_zvol
  p2_shim_disks
  p2_shim_targetcli
  SCRIPT="$S/storage-zvol-destroy"
  echo "$DS 1073741824" > "$STATE/zvols"
}

teardown() {
  rm -rf "$TEST_DIR"
}

destroy() {
  run --separate-stderr bash "$SCRIPT" "$DS" --approval-file - <<< "$1"
}

nothing_destroyed() {
  run ! grep -E '^zfs destroy' "$SHIM_LOG"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage errors exit 2, bad names exit 3, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$DS"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$DS" lab/enc/t1 --approval-file -
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force "$DS" --approval-file -
  [ "$status" -eq 2 ]
  local d
  for d in lab lab/enc lab/t0 lab/enc/a/b 'lab/enc/t0;x' Lab/enc/t0; do
    run bash "$SCRIPT" "$d" --approval-file - <<< '{}'
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "bad HMAC, expired, wrong mac, wrong dataset, pool-destroy action: all refuse, no zfs call at all" {
  local p
  p=$(p2_zvol_payload "$DS" | jq -c '.approval.hmac = ("0" * 64)')
  destroy "$p"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"HMAC"* ]]
  destroy "$(p2_zvol_payload "$DS" zvol-destroy 1000000000)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"expired"* ]]
  destroy "$(p2_zvol_payload "$DS" zvol-destroy 4102444800 112233445566)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different node"* ]]
  destroy "$(p2_zvol_payload lab/enc/other)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"different dataset"* ]]
  destroy "$(p2_zvol_payload "$DS" pool-destroy)"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not zvol-destroy"* ]]
  [ ! -s "$SHIM_LOG" ]
}

@test "an approval for the pool itself does not approve a zvol" {
  destroy "$(p2_zvol_payload lab zvol-destroy)"
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a ninth or missing member, garbage and empty input are refused" {
  destroy "$(p2_zvol_payload "$DS" | jq -c '.approval.extra = 1')"
  [ "$status" -eq 3 ]
  destroy "$(p2_zvol_payload "$DS" | jq -c 'del(.approval.wipe)')"
  [ "$status" -eq 3 ]
  destroy "nonsense"
  [ "$status" -eq 3 ]
  destroy ""
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

fixture_payload() {
  jq -n -c --slurpfile a "$FIX/approval-zvol-destroy.json" --rawfile h "$FIX/approval-zvol-destroy.hmac" --rawfile s "$FIX/approval-zvol-destroy.secret.hex" \
    '{approval:($a[0] + {hmac:($h|rtrimstr("\n"))}),secret:($s|rtrimstr("\n"))}'
}

@test "the HPS::Approval fixture for zvol-destroy verifies and destroys" {
  echo "hps.mac=52:54:00:00:00:01" > "$HPS_CMDLINE"
  destroy "$(fixture_payload)"
  [ "$status" -eq 0 ]
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
}

@test "the fixture with one byte changed is refused" {
  echo "hps.mac=52:54:00:00:00:01" > "$HPS_CMDLINE"
  destroy "$(fixture_payload | sed 's/"issued_by":"operator"/"issued_by":"operatoR"/')"
  [ "$status" -eq 3 ]
  destroy "$(fixture_payload | sed 's/"pool":"lab\/enc\/t0"/"pool":"lab\/enc\/t1"/')"
  [ "$status" -eq 3 ]
  destroy "$(fixture_payload | sed 's/f9604d9c/f9604d9d/')"
  [ "$status" -eq 3 ]
  nothing_destroyed
}

@test "the fixture bytes are canonical (jq -S -c identical) and have the eight members with the hmac" {
  run jq -S -c . "$FIX/approval-zvol-destroy.json"
  [ "$output" = "$(cat "$FIX/approval-zvol-destroy.json")" ]
  run jq -c '.approval | keys' <<< "$(fixture_payload)"
  [ "$output" = '["action","disks","expires","hmac","issued_by","mac","pool","wipe"]' ]
}

@test "a valid approval destroys exactly that zvol, announced and logged" {
  echo "other/enc/keep 1073741824" >> "$STATE/zvols"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WILL DESTROY: zvol $DS"* ]]
  [[ "$stderr" == *"+ zfs destroy $DS"* ]]
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
  [ "$(grep -c '^zfs destroy' "$SHIM_LOG")" -eq 1 ]
  run ! grep -E 'zfs destroy .*(-r|-R|-f)|zpool' "$SHIM_LOG"
  grep -q '^other/enc/keep' "$STATE/zvols"
}

@test "a dataset that is not there: approval checked, exit 0, nothing destroyed" {
  : > "$STATE/zvols"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing to do"* ]]
  nothing_destroyed
}

@test "a filesystem is not a zvol: refused (3)" {
  : > "$STATE/zvols"
  echo "$DS" > "$STATE/datasets"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not a zvol"* ]]
  nothing_destroyed
}

@test "an exported zvol is refused (3) and stays" {
  targetcli /backstores/block create lab_enc_t0 /dev/zvol/$DS
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"exported"* ]]
  nothing_destroyed
}

@test "a backstore of the same name for another device still blocks (3)" {
  targetcli /backstores/block create lab_enc_t0 /dev/zvol/lab/enc/other
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 3 ]
  nothing_destroyed
}

@test "an unreadable LIO configuration fails closed (1)" {
  cat > "$TEST_DIR/bin/targetcli" <<'SHIM'
#!/usr/bin/env bash
echo "targetcli $*" >> "$SHIM_LOG"
exit 1
SHIM
  chmod +x "$TEST_DIR/bin/targetcli"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 1 ]
  nothing_destroyed
}

@test "a mounted zvol and one with holders or partitions are refused (3)" {
  printf 'disk /mnt/x\n' > "$STATE/lsblk.t0"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use"* ]]
  printf 'disk \npart \n' > "$STATE/lsblk.t0"
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 3 ]
  nothing_destroyed
}

@test "a failing zfs destroy (snapshots, clones) exits 1" {
  FAKE_ZFS_DESTROY_RC=1 destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 1 ]
}

@test "the approval key never appears in the log, the output or files" {
  destroy "$(p2_zvol_payload "$DS")"
  [ "$status" -eq 0 ]
  run ! grep -F "$P2_SECRET" "$SHIM_LOG"
  [[ "$stderr" != *"$P2_SECRET"* ]]
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
}

@test "only zvol-destroy destroys: zfs destroy appears nowhere else among the new scripts" {
  local f
  for f in storage-zvol-create storage-zvol-list storage-status; do
    run ! grep -E 'zfs destroy|zpool (destroy|import)' "$S/$f"
  done
}
