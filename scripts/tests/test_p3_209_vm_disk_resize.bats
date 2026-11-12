#!/usr/bin/env bats
#
# vm-disk-resize: virsh blockresize of one guest disk to its source device's
# size, so a running guest sees a zvol grown by storage-zvol-grow.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-209.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  SCRIPT="$S/vm-disk-resize"
  echo running > "$STATE/domstate.s1-cnh"
  printf ' Target   Source\n----------------------------------------\n vda      /dev/zvol/lab/enc/vm/s1-cnh-d0\n vdb      /dev/md/s1-cnh-d1\n sdz      -\n' > "$STATE/blk.s1-cnh"
  echo $((64 << 30)) > "$STATE/size.s1-cnh-d0"
  echo $((8 << 30)) > "$STATE/size.s1-cnh-d1"
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
echo "virsh $*" >> "$SHIM_LOG"
shift 2  # -c qemu:///system
case "$1" in
  domstate) cat "$STATE/domstate.$2" 2> /dev/null || { echo "error: no domain" >&2; exit 1; } ;;
  domblklist) cat "$STATE/blk.$2" ;;
  blockresize) exit "${FAKE_RESIZE_RC:-0}" ;;
esac
SHIM
  cat > "$TEST_DIR/bin/blockdev" <<'SHIM'
#!/usr/bin/env bash
echo "blockdev $*" >> "$SHIM_LOG"
dev="${@: -1}"
cat "$STATE/size.${dev##*/}" 2> /dev/null || exit 1
SHIM
  chmod +x "$TEST_DIR"/bin/*
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

@test "by target: blockresize to the source device's size in bytes" {
  run --separate-stderr bash "$SCRIPT" s1-cnh vda
  [ "$status" -eq 0 ]
  grep -qxF 'blockdev --getsize64 /dev/zvol/lab/enc/vm/s1-cnh-d0' "$SHIM_LOG"
  grep -qxF "virsh -c qemu:///system blockresize s1-cnh vda $((64 << 30))B" "$SHIM_LOG"
  [ "$output" = "VM-DISK s1-cnh vda source=/dev/zvol/lab/enc/vm/s1-cnh-d0 bytes=$((64 << 30)) resized=yes" ]
  [[ "$stderr" == *"+ virsh -c qemu:///system blockresize s1-cnh vda"* ]]
}

@test "by zvol path: the same disk is found through domblklist" {
  run bash "$SCRIPT" s1-cnh /dev/zvol/lab/enc/vm/s1-cnh-d0
  [ "$status" -eq 0 ]
  grep -qxF "virsh -c qemu:///system blockresize s1-cnh vda $((64 << 30))B" "$SHIM_LOG"
}

@test "a shut off guest needs nothing: no blockresize, resized=no" {
  echo "shut off" > "$STATE/domstate.s1-cnh"
  run bash "$SCRIPT" s1-cnh vda
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM-DISK s1-cnh vda source=/dev/zvol/lab/enc/vm/s1-cnh-d0 bytes=$((64 << 30)) resized=no" ]
  run ! grep -q 'blockresize' "$SHIM_LOG"
}

@test "a guest that is not defined exits 4" {
  run bash "$SCRIPT" nosuch vda
  [ "$status" -eq 4 ]
  run ! grep -q 'blockresize' "$SHIM_LOG"
}

@test "a disk the guest does not have is refused (3); so is one without a device source" {
  run bash "$SCRIPT" s1-cnh vdc
  [ "$status" -eq 3 ]
  [[ "$output" == *"has no disk 'vdc'"* ]]
  run bash "$SCRIPT" s1-cnh /dev/zvol/lab/enc/vm/other-d0
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" s1-cnh sdz
  [ "$status" -eq 3 ]
  [[ "$output" == *"not a device under /dev"* ]]
  run ! grep -q 'blockresize' "$SHIM_LOG"
}

@test "disk arguments other than a target or a /dev/zvol path are refused (3) before virsh" {
  local d
  for d in /dev/sda /dev/zvol/lab/t0 /dev/zvol/lab/enc/../x vda1 'vda;x' /etc/passwd /dev/md/s1-cnh-d1; do
    run bash "$SCRIPT" s1-cnh "$d"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1-cnh
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" s1-cnh vda 64G
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" S1_bad vda
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force vda
  [ "$status" -eq 2 ]
}

@test "a failing blockresize, or an unreadable device size, fails the run (1)" {
  export FAKE_RESIZE_RC=1
  run bash "$SCRIPT" s1-cnh vda
  [ "$status" -eq 1 ]
  unset FAKE_RESIZE_RC
  rm "$STATE/size.s1-cnh-d0"
  run bash "$SCRIPT" s1-cnh vda
  [ "$status" -eq 1 ]
}
