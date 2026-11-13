#!/usr/bin/env bats
#
# vm-image-write --mbps-max N: the write is qemu-img convert with its own rate
# limit, -r N*1048576 bytes/s (2026-11-13: the earlier pipe-and-dd form wrote
# 0 bytes on a node — qemu-img cannot write raw to a pipe). qemu-img, virsh
# and sha256sum are shims. Without --mbps-max the write is the plain convert
# and says it is not paced.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-256.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  cat > "$TEST_DIR/bin/qemu-img" <<'SHIM'
#!/usr/bin/env bash
echo "qemu-img $*" >> "$SHIM_LOG"
[[ "${FAKE_QEMU_RC:-0}" -ne 0 ]] && exit "$FAKE_QEMU_RC"
printf 'RAWIMAGE' | dd of="${*: -1}" conv=notrunc status=none
SHIM
  chmod +x "$TEST_DIR/bin/qemu-img"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "shellcheck clean" {
  shellcheck -S warning "$S/vm-image-write"
}

@test "no --mbps-max: the plain convert, one log line saying it is not paced, no -r" {
  run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not paced"* ]]
  [ "$(grep -c 'not paced' <<< "$stderr")" -eq 1 ]
  grep -qF "qemu-img convert -f qcow2 -O raw $IMG $DISK" "$SHIM_LOG"
  run ! grep -q -- ' -r ' "$SHIM_LOG"
}

@test "--mbps-max 4: qemu-img converts to the disk with -r 4194304; the last line is still IMAGE" {
  run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 4
  [ "$status" -eq 0 ]
  sum=$(/usr/bin/sha256sum "$IMG")
  [ "${lines[-1]}" = "IMAGE vm1 ${sum%% *} written" ]
  grep -qF "qemu-img convert -f qcow2 -O raw -r 4194304 $IMG $DISK" "$SHIM_LOG"
  run ! grep -q /dev/stdout "$SHIM_LOG"
  [[ "$stderr" == *"pacing the write to 4 MiB/s"* ]]
  [[ "$stderr" == *"paced write done at no more than 4 MiB/s"* ]]
}

@test "--mbps-max 999999: -r is 999999*1048576 bytes/s" {
  run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 999999
  [ "$status" -eq 0 ]
  grep -qF -- "-r 1048574951424 $IMG" "$SHIM_LOG"
}

@test "--mbps-max: the image reaches the disk" {
  : > "$DISK"
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 4
  [ "$status" -eq 0 ]
  grep -q RAWIMAGE "$DISK"
}

@test "--mbps-max values: 0, negative, text, a decimal, 1000000 are refused (3) and nothing runs" {
  for v in 0 -5 abc 1.5 1000000 ''; do
    : > "$SHIM_LOG"
    run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max "$v"
    [ "$status" -eq 3 ] || { echo "accepted [$v]"; false; }
    run ! grep -q qemu-img "$SHIM_LOG"
  done
}

@test "--mbps-max without a value is a usage error (2)" {
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max
  [ "$status" -eq 2 ]
}

@test "--mbps-max: a failing qemu-img fails the script (1)" {
  FAKE_QEMU_RC=1 run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 50
  [ "$status" -eq 1 ]
  [[ "$output" != *"written"* ]]
}

@test "--mbps-max: the other refusals still apply (a written disk is refused, 3)" {
  printf 'DATA' | dd of="$DISK" conv=notrunc status=none
  run bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 50
  [ "$status" -eq 3 ]
  run ! grep -q qemu-img "$SHIM_LOG"
}
