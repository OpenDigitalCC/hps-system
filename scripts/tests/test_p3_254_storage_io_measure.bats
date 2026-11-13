#!/usr/bin/env bats
#
# storage-io-measure: the pool's read test of its disks and the write + fsync
# test on a temporary zvol (hps-storage measure). zpool, zfs, udevadm and dd are
# shims (dd runs the real dd on files). Proves: argument checks and refusals
# before anything is created, the exact dd flags, the output lines, the zvol
# destroyed on success and on failure, and that nothing else is written.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_254_helpers

DISK=ata-TESTDISK-1
DS=lab/enc/hps-measure

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-254.XXXXXX")"
  export TEST_DIR
  p3_254_setup
  p3_254_disk "$DISK"
  printf '%s\n' lab lab/enc > "$STATE/datasets"
  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
case "$1" in
  list) [[ -e "$STATE/no-pool" ]] && exit 1; exit 0 ;;
  status) printf '  pool: lab\n    lab   ONLINE\n      /dev/disk/by-id/%s-part1  ONLINE\n' "${FAKE_POOL_DISK:-ata-TESTDISK-1}" ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/zfs" <<'SHIM'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
last="${@: -1}"
case "$1" in
  list)
    if [[ "$*" == *"-o available"* ]]; then cat "$STATE/avail" 2> /dev/null || echo 107374182400; exit 0; fi
    grep -qxF "$last" "$STATE/datasets" && exit 0
    exit 1 ;;
  get)
    if [[ "$*" == *keystatus* ]]; then cat "$STATE/keystatus" 2> /dev/null || echo available; exit 0; fi
    printf 'standard\nlatency\n' ;;
  create)
    echo "$last" >> "$STATE/datasets"
    mkdir -p "$HPS_DEV/zvol/${last%/*}"
    head -c 1073741824 /dev/zero | head -c 16777216 > "$HPS_DEV/zvol/$last" ;;
  destroy)
    grep -vxF "$last" "$STATE/datasets" > "$STATE/d.tmp" || true
    mv "$STATE/d.tmp" "$STATE/datasets"
    rm -f "$HPS_DEV/zvol/$last" ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/udevadm" <<'SHIM'
#!/usr/bin/env bash
echo "udevadm $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$TEST_DIR"/bin/*
  SCRIPT="$S/storage-io-measure"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "is on the ctrl-exec allowlist as a node script" {
  ctrl="${BATS_TEST_DIRNAME}/../../nix/modules/hps-ctrl-exec.nix"
  [ "$(grep -c '^      storage-io-measure\.source = mkScript "storage-io-measure" (scriptsDir + "/storage-io-measure");' "$ctrl")" -eq 1 ]
  [ "$(grep -c '^      storage-io-measure\.options\.profile = "node";' "$ctrl")" -eq 1 ]
}

@test "usage errors exit 2 and run nothing" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --lab
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a bad pool name is refused (3) before any command" {
  run bash "$SCRIPT" 'Lab;id'
  [ "$status" -eq 3 ]
  [[ "$output" == *"pool name"* ]]
  [ ! -s "$SHIM_LOG" ]
}

@test "a pool that is not imported is refused (3) with the fix named; nothing is created" {
  touch "$STATE/no-pool"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"not imported"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
  run ! grep -q '^dd ' "$SHIM_LOG"
}

@test "a locked <pool>/enc is refused (3)" {
  echo unavailable > "$STATE/keystatus"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"locked"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "an existing hps-measure zvol is refused (3), left alone, nothing written" {
  echo "$DS" >> "$STATE/datasets"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"$DS already exists"* ]]
  [[ "$output" == *"zfs destroy $DS"* ]]
  run ! grep -q '^zfs destroy' "$SHIM_LOG"
  run ! grep -q '^dd ' "$SHIM_LOG"
}

@test "too little room is refused (3)" {
  echo 1000000 > "$STATE/avail"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"available"* ]]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "measures: IOREAD per pool disk, IOPOLICY, IOPOOL; the zvol is made and destroyed" {
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^IOREAD\ ata-TESTDISK-1\ [0-9]+$ ]]
  [ "${lines[1]}" = "IOPOLICY lab sync=standard logbias=latency" ]
  [[ "${lines[2]}" =~ ^IOPOOL\ lab\ [0-9]+\ [0-9]+\.[0-9]{2}\ [0-9]+\.[0-9]{2}$ ]]
  [ "${#lines[@]}" -eq 3 ]
  grep -qxF "zfs create -V 1024M $DS" "$SHIM_LOG"
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
  ! grep -qxF "$DS" "$STATE/datasets"
  [ ! -e "$HPS_IO_TMP/hps-io-measure.$$" ]
  [ -z "$(ls "$HPS_IO_TMP")" ]
}

@test "dd flags: direct read of the disk, urandom data, direct 4 MiB writes, N x 4 KiB direct,dsync" {
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  grep -qE "^dd if=$HPS_DEV/disk/by-id/$DISK of=/dev/null bs=4M count=1 iflag=direct" "$SHIM_LOG"
  grep -qE '^dd if=/dev/urandom of=.*/hps-io-measure\.[0-9]+ bs=1M count=4' "$SHIM_LOG"
  grep -qE "^dd if=.*hps-io-measure.* of=$HPS_DEV/zvol/$DS bs=4M count=1 oflag=direct" "$SHIM_LOG"
  [ "$(grep -c 'bs=4096 count=1 .*oflag=direct,dsync' "$SHIM_LOG")" -eq 5 ]
}

@test "the data is not compressible: it comes from /dev/urandom, never /dev/zero" {
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  run ! grep -E '^dd if=/dev/zero' "$SHIM_LOG"
}

@test "a failing write still destroys the zvol, exits 1, prints no IOPOOL" {
  FAKE_DD_FAIL_OF="zvol/$DS" run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 1 ]
  [[ "$output" != *IOPOOL* ]]
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
  ! grep -qxF "$DS" "$STATE/datasets"
  [ -z "$(ls "$HPS_IO_TMP")" ]
}

@test "a disk that is not present under by-id is noted and skipped, the pool test still runs" {
  FAKE_POOL_DISK=ata-GONE run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"ata-GONE is not present"* ]]
  [[ "$output" == *IOPOOL* ]]
  [[ "$output" != *IOREAD* ]]
}

@test "writes nothing outside the test zvol: no zpool create/destroy/labelclear, no other zfs destroy" {
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  run ! grep -E '^zpool (create|destroy|labelclear|export|import)' "$SHIM_LOG"
  [ "$(grep -c '^zfs destroy' "$SHIM_LOG")" -eq 1 ]
  # every dd that writes (of= other than /dev/null) writes the tmpfs file or the zvol
  run ! bash -c "grep '^dd ' '$SHIM_LOG' | grep -v 'of=/dev/null' | grep -v 'of=.*hps-io-measure' | grep -v 'of=$HPS_DEV/zvol/$DS'"
}

@test "a failing 4 KiB synchronous write stops the test (1), no IOPOOL, zvol destroyed" {
  cat > "$TEST_DIR/bin/dd" <<'SHIM'
#!/usr/bin/env bash
echo "dd $*" >> "$SHIM_LOG"
[[ "$*" == *oflag=direct,dsync* ]] && { echo "dd: Input/output error" >&2; exit 1; }
args=()
for a in "$@"; do
  case "$a" in
    oflag=direct | iflag=direct) ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/dd "${args[@]}"
SHIM
  chmod +x "$TEST_DIR/bin/dd"
  run --separate-stderr bash "$SCRIPT" lab
  [ "$status" -eq 1 ]
  [[ "$output" != *IOPOOL* ]]
  grep -qxF "zfs destroy $DS" "$SHIM_LOG"
}
