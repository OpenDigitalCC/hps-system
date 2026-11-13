#!/usr/bin/env bats
#
# vm-image-write --mbps-max N: the image is written through a pipe, one dd per
# chunk, with a sleep after each chunk that holds the average at N MiB/s.
# qemu-img, virsh, sha256sum and sleep are shims; dd is the real one. Without
# --mbps-max the write is the plain qemu-img convert and says it is not paced.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-256.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  export HPS_DD_OFLAG=dsync
  export HPS_PACE_CHUNK=1048576
  # A qemu-img that, when it writes to /dev/stdout, sends FAKE_QEMU_BYTES bytes (default 8) of 'R'.
  cat > "$TEST_DIR/bin/qemu-img" <<'SHIM'
#!/usr/bin/env bash
echo "qemu-img $*" >> "$SHIM_LOG"
[[ "${FAKE_QEMU_RC:-0}" -ne 0 ]] && exit "$FAKE_QEMU_RC"
n=${FAKE_QEMU_BYTES:-8}
if [[ "${*: -1}" == /dev/stdout ]]; then
  head -c "$n" /dev/zero | tr '\0' R
else
  printf 'RAWIMAGE' | dd of="${*: -1}" conv=notrunc status=none
fi
SHIM
  cat > "$TEST_DIR/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
echo "sleep $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$TEST_DIR/bin/qemu-img" "$TEST_DIR/bin/sleep"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "shellcheck clean" {
  shellcheck -S warning "$S/vm-image-write"
}

@test "no --mbps-max: the plain convert, one log line saying it is not paced, no sleep" {
  run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"not paced"* ]]
  [ "$(grep -c 'not paced' <<< "$stderr")" -eq 1 ]
  grep -qF "qemu-img convert -f qcow2 -O raw $IMG $DISK" "$SHIM_LOG"
  run ! grep -q '^sleep' "$SHIM_LOG"
}

@test "--mbps-max: qemu-img converts to /dev/stdout, not to the disk; the last line is still IMAGE" {
  FAKE_QEMU_BYTES=3145728 run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 4
  [ "$status" -eq 0 ]
  sum=$(/usr/bin/sha256sum "$IMG")
  [ "${lines[-1]}" = "IMAGE vm1 ${sum%% *} written" ]
  grep -qF "qemu-img convert -f qcow2 -O raw $IMG /dev/stdout" "$SHIM_LOG"
  run ! grep -qF "qemu-img convert -f qcow2 -O raw $IMG $DISK" "$SHIM_LOG"
  [[ "$stderr" == *"pacing the write to 4 MiB/s"* ]]
}

@test "--mbps-max: the whole image reaches the disk, chunk by chunk (3 MiB = 3 chunks + the empty last read)" {
  : > "$DISK"
  FAKE_QEMU_BYTES=3145728 run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 4
  [ "$status" -eq 0 ]
  [ "$(stat -c %s "$DISK")" -eq 3145728 ]
  [ -z "$(tr -d 'R' < "$DISK")" ]
  [[ "$stderr" == *"paced write: 3145728 bytes"* ]]
}

@test "--mbps-max: sleeps so that bytes / elapsed stays at or under the cap (3 MiB at 1 MiB/s: the last sleep reaches 3 s)" {
  FAKE_QEMU_BYTES=3145728 run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^sleep' "$SHIM_LOG")" -ge 2 ]
  last=$(grep '^sleep' "$SHIM_LOG" | tail -1 | cut -d' ' -f2)
  awk -v s="$last" 'BEGIN { exit !(s > 2.8 && s <= 3.0) }'
}

@test "--mbps-max: a cap high enough for the machine does not sleep" {
  run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 999999
  [ "$status" -eq 0 ]
  run ! grep -q '^sleep' "$SHIM_LOG"
}

@test "--mbps-max: dd writes with the oflag (default direct) at the chunk's offset, conv=notrunc" {
  unset HPS_DD_OFLAG
  FAKE_QEMU_BYTES=2097152 run --separate-stderr bash "$S/vm-image-write" vm1 --disk "$DISK" --image "$IMG" --mbps-max 999999 || true
  grep -q "dd of=$DISK bs=1048576 count=1 iflag=fullblock seek=0 oflag=direct conv=notrunc" <<< "$stderr"
  grep -q "seek=1 oflag=direct" <<< "$stderr"
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

@test "--mbps-max: a failing qemu-img fails the script (1) even though dd succeeded" {
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
