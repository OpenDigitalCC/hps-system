#!/usr/bin/env bats
#
# CS-1.10: storage-disks, node-dmesg and node-facts (node-manager/nixos-26/
# scripts) with PATH shims for lsblk, blkid, smartctl, dmesg, timedatectl, free
# and friends. Proves: argument handling and exit codes, the sections they
# print, the dmesg pattern validation and 500-line cap, smartctl only when
# present, every command logged, and no write verb anywhere.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-101.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  D="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/dev/disk/by-id" "$TEST_DIR/dev" "$TEST_DIR/proc/scsi" \
    "$TEST_DIR/sys/class/scsi_host/host0" "$TEST_DIR/sys/class/scsi_device/0:0:0:0/device"
  export HPS_DEV="$TEST_DIR/dev" HPS_PROC="$TEST_DIR/proc" HPS_SYS="$TEST_DIR/sys"
  touch "$TEST_DIR/dev/sda" "$TEST_DIR/dev/sdb" "$TEST_DIR/dev/sdaa" "$TEST_DIR/dev/disk/by-id/ata-FAKE"
  echo "Attached devices:" > "$TEST_DIR/proc/scsi/scsi"
  echo hpsa > "$TEST_DIR/sys/class/scsi_host/host0/proc_name"
  echo running > "$TEST_DIR/sys/class/scsi_host/host0/state"
  echo ATA > "$TEST_DIR/sys/class/scsi_device/0:0:0:0/device/vendor"
  export PATH="$TEST_DIR/bin:$PATH"

  for c in lsblk blkid smartctl timedatectl free uptime df ip hostname uname; do
    printf '#!/usr/bin/env bash\necho "%s $*" | sed "s/ *$//" >> "$SHIM_LOG"\necho "out-of-%s"\nexit "${FAKE_%s_RC:-0}"\n' \
      "$c" "$c" "$(echo "$c" | tr a-z A-Z)" > "$TEST_DIR/bin/$c"
  done
  cat > "$TEST_DIR/bin/dmesg" <<'SHIM'
#!/usr/bin/env bash
echo "dmesg $*" >> "$SHIM_LOG"
[[ -n "${FAKE_DMESG_RC:-}" ]] && exit "$FAKE_DMESG_RC"
i=1
while [[ $i -le "${FAKE_DMESG_LINES:-5}" ]]; do
  echo "[line $i] hpsa: event $i"
  i=$((i + 1))
done
echo "[other] usb: attached"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "all four scripts are executable with the env shebang and set -euo pipefail" {
  for s in storage-pool-inspect storage-disks node-dmesg node-facts; do
    [ -x "$D/$s" ]
    [ "$(head -1 "$D/$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$D/$s"
  done
}

@test "storage-disks and node-facts take no arguments (2)" {
  run bash "$D/storage-disks" x
  [ "$status" -eq 2 ]
  run bash "$D/node-facts" x
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "storage-disks runs the read-only inventory commands and prints sections" {
  run bash "$D/storage-disks"
  [ "$status" -eq 0 ]
  grep -qx 'lsblk -O -J' "$SHIM_LOG"
  grep -qx 'blkid' "$SHIM_LOG"
  [[ "$output" == *"=== lsblk ==="* ]]
  [[ "$output" == *"ata-FAKE"* ]]
  [[ "$output" == *"Attached devices:"* ]]
  [[ "$output" == *"proc_name:hpsa"* ]]
  [[ "$output" == *"vendor:ATA"* ]]
  [[ "$output" == *"+ lsblk -O -J"* ]]
}

@test "storage-disks runs smartctl -i on /dev/sd? only (not sdaa) and only when present" {
  run bash "$D/storage-disks"
  [ "$status" -eq 0 ]
  grep -qx "smartctl -i $HPS_DEV/sda" "$SHIM_LOG"
  grep -qx "smartctl -i $HPS_DEV/sdb" "$SHIM_LOG"
  ! grep -q 'sdaa' "$SHIM_LOG"
  ! grep -qE 'smartctl .*(-s|-t|-X|-a|--set)' "$SHIM_LOG"
  rm "$TEST_DIR/bin/smartctl"
  PATH="$TEST_DIR/bin:/usr/bin:/bin" run bash "$D/storage-disks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"smartctl not installed"* ]]
}

@test "storage-disks notes a failing command and carries on" {
  FAKE_BLKID_RC=2 run bash "$D/storage-disks"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(exit 2)"* ]]
  grep -q '^smartctl' "$SHIM_LOG"
}

@test "node-facts prints the measured figures: time sync, memory, store, kernel line" {
  run bash "$D/node-facts"
  [ "$status" -eq 0 ]
  grep -qx 'timedatectl show' "$SHIM_LOG"
  grep -qx 'free -m' "$SHIM_LOG"
  grep -qx 'df -h /nix/store /nix/.ro-store' "$SHIM_LOG"
  grep -qx 'ip -br addr' "$SHIM_LOG"
  [[ "$output" == *"=== time synchronisation ==="* ]]
  [[ "$output" == *"=== date -u ==="* ]]
}

@test "node-facts carries on when df fails" {
  FAKE_DF_RC=1 run bash "$D/node-facts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(exit 1)"* ]]
  grep -q '^ip -br addr' "$SHIM_LOG"
}

@test "node-dmesg without a pattern prints the log with dmesg -T" {
  run bash "$D/node-dmesg"
  [ "$status" -eq 0 ]
  grep -qx 'dmesg -T' "$SHIM_LOG"
  [[ "$output" == *"[other] usb: attached"* ]]
}

@test "node-dmesg filters with an extended regex" {
  run bash "$D/node-dmesg" 'hpsa|nothing'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[line 1] hpsa: event 1"* ]]
  [[ "$output" != *"usb: attached"* ]]
  [[ "$output" == *"+ grep -E -- hpsa|nothing"* ]]
}

@test "node-dmesg: a pattern matching nothing is still success" {
  run bash "$D/node-dmesg" 'zzz-none'
  [ "$status" -eq 0 ]
}

@test "node-dmesg caps the output at 500 lines (the newest)" {
  FAKE_DMESG_LINES=800 run bash "$D/node-dmesg" 'hpsa'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[line 800] hpsa"* ]]
  [[ "$output" != *"[line 300] hpsa"* ]]
  [[ "$output" == *"[line 301] hpsa"* ]]
}

@test "node-dmesg refuses shell metacharacters (3) and runs nothing" {
  for bad in 'a;b' 'a&b' 'a$b' 'a`b`' 'a>b' 'a<b' "a'b" 'a"b' 'a\b' $'a\nb' 'a!b' 'a#b' 'a~b' '$(id)'; do
    run bash "$D/node-dmesg" "$bad"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "node-dmesg refuses a pattern over 200 characters (3)" {
  long="$(printf 'a%.0s' $(seq 1 201))"
  run bash "$D/node-dmesg" "$long"
  [ "$status" -eq 3 ]
}

@test "node-dmesg: two arguments (2); an invalid regex (2); a pattern starting with - is data" {
  run bash "$D/node-dmesg" a b
  [ "$status" -eq 2 ]
  run bash "$D/node-dmesg" 'a(b'
  [ "$status" -eq 2 ]
  run bash "$D/node-dmesg" '-v'
  [ "$status" -eq 0 ]
}

@test "node-dmesg fails (1) when dmesg itself fails" {
  FAKE_DMESG_RC=1 run bash "$D/node-dmesg"
  [ "$status" -eq 1 ]
}

@test "none of the read-only scripts calls a write verb" {
  for s in storage-disks node-dmesg node-facts; do
    run bash -c "grep -v '^ *#' '$D/$s' | grep -nE '(^| )(mount|umount|dd|wipefs|mkfs|parted|mdadm|rm|mv|tee|zpool|zfs|sed -i)( |\$)'"
    [ "$status" -eq 1 ]
  done
}
