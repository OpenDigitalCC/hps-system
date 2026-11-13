#!/usr/bin/env bats
#
# CS-2.5: storage-zvol-destroy. Proves: it runs with no approval and reads no
# input (ADR 0007), the refusals (not a zvol, exported, in use), the exact
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

# destroy [stdin text]: run the script for $DS (stdin empty unless given).
destroy() {
  run --separate-stderr bash "$SCRIPT" "$DS" <<< "${1:-}"
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
  run bash "$SCRIPT" "$DS" --approval-file -
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$DS" lab/enc/t1
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force "$DS"
  [ "$status" -eq 2 ]
  local d
  for d in lab lab/enc lab/t0 lab/enc/a/b 'lab/enc/t0;x' Lab/enc/t0; do
    run bash "$SCRIPT" "$d"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "with no approval it destroys exactly that zvol, announced and logged; stdin is not read" {
  echo "other/enc/keep 1073741824" >> "$STATE/zvols"
  destroy '{"anything":"the request context ctrl-exec writes"}'
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WILL DESTROY: zvol $DS"* ]]
  [[ "$stderr" == *"+ zfs destroy $DS"* ]]
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
  [ "$(grep -c '^zfs destroy' "$SHIM_LOG")" -eq 1 ]
  run ! grep -E 'zfs destroy .*(-r|-R|-f)|zpool' "$SHIM_LOG"
  grep -q '^other/enc/keep' "$STATE/zvols"
  [[ "$stderr" != *"approv"* ]]
  run ! grep -nE '\$\(cat\)|\bjq\b' "$SCRIPT"
}

@test "a zvol under <pool>/enc/vm is destroyed, nothing else" {
  local vds=lab/enc/vm/t0-app-root
  echo "$vds 1073741824" >> "$STATE/zvols"
  run --separate-stderr bash "$SCRIPT" "$vds"
  [ "$status" -eq 0 ]
  grep -qxF "zfs destroy $vds" "$SHIM_LOG"
  [ "$(grep -c '^zfs destroy' "$SHIM_LOG")" -eq 1 ]
  grep -q "^$DS " "$STATE/zvols"
}

@test "deeper names under <pool>/enc/vm are refused" {
  run bash "$SCRIPT" lab/enc/vm/a/b
  [ "$status" -eq 3 ]
  nothing_destroyed
}

@test "a dataset that is not there: exit 0, nothing destroyed" {
  : > "$STATE/zvols"
  destroy
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing to do"* ]]
  nothing_destroyed
}

@test "a filesystem is not a zvol: refused (3)" {
  : > "$STATE/zvols"
  echo "$DS" > "$STATE/datasets"
  destroy
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"not a zvol"* ]]
  nothing_destroyed
}

@test "an exported zvol is refused (3) and stays" {
  targetcli /backstores/block create lab_enc_t0 /dev/zvol/$DS
  destroy
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"exported"* ]]
  nothing_destroyed
}

@test "a backstore of the same name for another device still blocks (3)" {
  targetcli /backstores/block create lab_enc_t0 /dev/zvol/lab/enc/other
  destroy
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
  destroy
  [ "$status" -eq 1 ]
  nothing_destroyed
}

@test "a mounted zvol, a holder on it, or a mounted partition are refused (3)" {
  printf 'disk /mnt/x\n' > "$STATE/lsblk.t0"
  destroy
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use (mounted at /mnt/x)"* ]]
  printf 'disk \npart \nraid1 \n' > "$STATE/lsblk.t0"
  destroy
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use (raid1 holder on the device)"* ]]
  printf 'disk \npart /mnt/y\n' > "$STATE/lsblk.t0"
  destroy
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"in use (partition mounted at /mnt/y)"* ]]
  nothing_destroyed
}

@test "partition nodes alone are not in use: a stopped guest's disk is destroyed" {
  printf 'disk \npart \npart \n' > "$STATE/lsblk.t0"
  destroy
  [ "$status" -eq 0 ]
  grep -q 'zfs destroy' "$SHIM_LOG"
}

@test "a failing zfs destroy (snapshots, clones) exits 1" {
  FAKE_ZFS_DESTROY_RC=1 destroy
  [ "$status" -eq 1 ]
}

@test "it leaves no file behind" {
  destroy
  [ "$status" -eq 0 ]
  [ -z "$(find "$TMPDIR" "$WORK" -mindepth 1)" ]
}

@test "only zvol-destroy destroys: zfs destroy appears nowhere else among the new scripts" {
  local f
  for f in storage-zvol-create storage-zvol-list storage-status; do
    run ! grep -E 'zfs destroy|zpool (destroy|import)' "$S/$f"
  done
}
