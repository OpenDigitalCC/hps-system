#!/usr/bin/env bats
#
# cnh-disk-grow: resize2fs, online, on the one disk labelled hps-cnh that is
# mounted at /var/lib/containers; anything else refused before resize2fs runs.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-207.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  SCRIPT="$S/cnh-disk-grow"
  C="$HPS_CNH_ROOT/var/lib/containers"
  p3_171_disk vdb
  echo "$HPS_DEV/vdb" > "$STATE/labelled"
  printf 'TYPE=ext4\nLABEL=hps-cnh\n' > "$STATE/sig.vdb"
  p3_171_mount "$C" "$HPS_DEV/vdb"
  echo "1000 20000" > "$STATE/df"
  cat > "$TEST_DIR/bin/resize2fs" <<'SHIM'
#!/usr/bin/env bash
echo "resize2fs $*" >> "$SHIM_LOG"
[[ "${FAKE_RESIZE_RC:-0}" -ne 0 ]] && exit "$FAKE_RESIZE_RC"
echo "1000 64000" > "$STATE/df"
SHIM
  chmod +x "$TEST_DIR/bin/resize2fs"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "grows the mounted hps-cnh filesystem with resize2fs and reports both sizes" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF "resize2fs $HPS_DEV/vdb" "$SHIM_LOG"
  [ "${lines[-1]}" = "CNH-DISK-GROW $HPS_DEV/vdb size_before=20000 size_after=64000" ]
  [[ "$output" == *"+ resize2fs $HPS_DEV/vdb"* ]]
}

@test "takes no arguments (2)" {
  run bash "$SCRIPT" /dev/vdb
  [ "$status" -eq 2 ]
  run ! grep -q '^resize2fs' "$SHIM_LOG"
}

@test "no labelled disk, or two, is refused (3) and resize2fs never runs" {
  : > "$STATE/labelled"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no disk is labelled hps-cnh"* ]]
  p3_171_disk vdc
  printf '%s\n%s\n' "$HPS_DEV/vdb" "$HPS_DEV/vdc" > "$STATE/labelled"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"2 disks are labelled hps-cnh"* ]]
  run ! grep -q '^resize2fs' "$SHIM_LOG"
}

@test "a labelled disk that is not ext4 is refused (3)" {
  printf 'TYPE=xfs\nLABEL=hps-cnh\n' > "$STATE/sig.vdb"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"its filesystem is 'xfs', not ext4"* ]]
  run ! grep -q '^resize2fs' "$SHIM_LOG"
}

@test "not mounted, or mounted from another device, is refused (3)" {
  : > "$STATE/mounts"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not mounted"* ]]
  p3_171_disk vdc
  p3_171_mount "$C" "$HPS_DEV/vdc"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is mounted from $HPS_DEV/vdc, not $HPS_DEV/vdb"* ]]
  run ! grep -q '^resize2fs' "$SHIM_LOG"
}

@test "a failing resize2fs fails the run (1)" {
  export FAKE_RESIZE_RC=1
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" != *CNH-DISK-GROW* ]]
}
