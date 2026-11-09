#!/usr/bin/env bats
#
# CS-2.5: scripts/hps-iscsi-test.sh with iscsiadm, iscsid, dd, cmp, readlink,
# blockdev, pgrep, pkill and sleep shimmed. Proves: the missing-module refusal,
# argument checks, the command order (discover, login, write, read, compare,
# logout), the 4 MiB pattern at 1 GiB - 8 MiB, logout and iscsid cleanup on every
# path, the initiator-name handling, one verdict line.

bats_require_minimum_version 1.5.0

IQN=iqn.2026-11.example:t0
IPN=iqn.2026-11.example:ips

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-74.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$ROOT/scripts/hps-iscsi-test.sh"
  export SHIM_LOG="$TEST_DIR/shim.log"
  export STATE="$TEST_DIR/state"
  mkdir -p "$STATE" "$TEST_DIR/bin" "$TEST_DIR/sys/iscsi_tcp" "$TEST_DIR/bypath" "$TEST_DIR/etc"
  : > "$SHIM_LOG"
  export PATH="$TEST_DIR/bin:$PATH"
  export HPS_ISCSI_SYS_MODULE="$TEST_DIR/sys/iscsi_tcp"
  export HPS_ISCSI_INITIATORNAME="$TEST_DIR/etc/initiatorname.iscsi"
  export HPS_ISCSI_BYPATH="$TEST_DIR/bypath"
  export HPS_ISCSI_LOGIN_WAIT=3
  echo "InitiatorName=$IPN" > "$HPS_ISCSI_INITIATORNAME"
  touch "$STATE/fakedisk"
  make_shims
}

teardown() {
  rm -rf "$TEST_DIR"
}

make_shims() {
  cat > "$TEST_DIR/bin/iscsiadm" <<'SHIM'
#!/usr/bin/env bash
echo "iscsiadm $*" >> "$SHIM_LOG"
case "$*" in
  *"-m discovery"*)
    [[ -e "$STATE/discovery-fail" ]] && exit 1
    [[ -e "$STATE/discovery-empty" ]] && exit 0
    echo "10.0.0.5:3260,1 iqn.2026-11.example:t0"
    exit 0 ;;
  *--login*)
    [[ -e "$STATE/login-fail" ]] && exit 1
    touch "$STATE/logged-in"
    [[ -e "$STATE/no-device" ]] || ln -sf "$STATE/fakedisk" "$HPS_ISCSI_BYPATH/ip-10.0.0.5:3260-iscsi-iqn.2026-11.example:t0-lun-0"
    [[ -e "$STATE/no-device" ]] || ln -sf "$STATE/fakedisk" "$HPS_ISCSI_BYPATH/ip-10.0.0.5:3260-iscsi-iqn.2026-11.example:t0-lun-0-part1"
    exit 0 ;;
  *--logout*)
    rm -f "$STATE/logged-in" "$HPS_ISCSI_BYPATH"/*
    exit 0 ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/iscsid" <<'SHIM'
#!/usr/bin/env bash
echo "iscsid $*" >> "$SHIM_LOG"
touch "$STATE/iscsid-running"
SHIM
  cat > "$TEST_DIR/bin/pgrep" <<'SHIM'
#!/usr/bin/env bash
[[ -e "$STATE/iscsid-running" ]] && { echo 4242; exit 0; }
exit 1
SHIM
  cat > "$TEST_DIR/bin/pkill" <<'SHIM'
#!/usr/bin/env bash
echo "pkill $*" >> "$SHIM_LOG"
rm -f "$STATE/iscsid-running"
SHIM
  cat > "$TEST_DIR/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  cat > "$TEST_DIR/bin/readlink" <<'SHIM'
#!/usr/bin/env bash
echo "/dev/fake-sdz"
SHIM
  cat > "$TEST_DIR/bin/blockdev" <<'SHIM'
#!/usr/bin/env bash
echo "blockdev $*" >> "$SHIM_LOG"
echo "${FAKE_SIZE:-1073741824}"
SHIM
  cat > "$TEST_DIR/bin/dd" <<'SHIM'
#!/usr/bin/env bash
echo "dd $*" >> "$SHIM_LOG"
[[ "$*" == *"of=/dev/fake-sdz"* && -n "${FAKE_DD_WRITE_RC:-}" ]] && exit "$FAKE_DD_WRITE_RC"
exit 0
SHIM
  cat > "$TEST_DIR/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
echo "cmp $*" >> "$SHIM_LOG"
exit "${FAKE_CMP_RC:-0}"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

run_test() {
  run --separate-stderr bash "$SCRIPT" 10.0.0.5 "$IQN" "$@"
}

logged_out() {
  grep -q '^iscsiadm .*--logout' "$SHIM_LOG"
  [ ! -e "$STATE/logged-in" ]
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage: missing or extra arguments exit 2, bad ip or iqn exit 3, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 10.0.0.5
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 10.0.0.5 "$IQN" extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 10.0.0.5 "$IQN" --bogus
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 10.0.0.5 "$IQN" --initiator-name
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 'host;x' "$IQN"
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 10.0.0.5 'not-an-iqn'
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" 10.0.0.5 "$IQN" --initiator-name 'bad name'
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "iscsi_tcp not loaded on the host: refused (3) with a clear message, nothing is run" {
  rmdir "$HPS_ISCSI_SYS_MODULE"
  run_test
  [ "$status" -eq 3 ]
  [[ "$output" == "ISCSI TEST FAILED: the iscsi_tcp kernel module is not loaded on the host"* ]]
  [[ "$output" == *"modprobe iscsi_tcp"* ]]
  [ ! -s "$SHIM_LOG" ]
}

@test "happy path: discover, login, write 4 MiB at 1016 MiB, read back, compare, logout, one verdict line" {
  run_test
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "ISCSI TEST OK $IQN via 10.0.0.5: 4 MiB written and read back at offset 1016 MiB of /dev/fake-sdz" ]]
  grep -qxF "iscsiadm -m discovery -t sendtargets -p 10.0.0.5" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p 10.0.0.5 --login" "$SHIM_LOG"
  grep -Eq '^dd if=[^ ]+/pattern of=/dev/fake-sdz bs=1M seek=1016 count=4 oflag=direct conv=fsync status=none$' "$SHIM_LOG"
  grep -Eq '^dd if=/dev/fake-sdz of=[^ ]+/readback bs=1M skip=1016 count=4 iflag=direct status=none$' "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p 10.0.0.5 --logout" "$SHIM_LOG"
  # order
  local d l w r c o
  d=$(grep -n 'discovery' "$SHIM_LOG" | head -1 | cut -d: -f1)
  l=$(grep -n -e '--login' "$SHIM_LOG" | head -1 | cut -d: -f1)
  w=$(grep -n 'seek=1016' "$SHIM_LOG" | head -1 | cut -d: -f1)
  r=$(grep -n 'skip=1016' "$SHIM_LOG" | head -1 | cut -d: -f1)
  c=$(grep -n '^cmp' "$SHIM_LOG" | head -1 | cut -d: -f1)
  o=$(grep -n -e '--logout' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [ "$d" -lt "$l" ]
  [ "$l" -lt "$w" ]
  [ "$w" -lt "$r" ]
  [ "$r" -lt "$c" ]
  [ "$c" -lt "$o" ]
  logged_out
  [[ "$stderr" == *"+ iscsiadm -m discovery"* ]]
}

@test "the partition link is not taken for the device, the whole disk is" {
  run_test
  [ "$status" -eq 0 ]
  run ! grep -F -e '-part' "$SHIM_LOG"
}

@test "iscsid is started when absent and stopped again; left alone when already running" {
  run_test
  [ "$status" -eq 0 ]
  grep -qxF 'iscsid ' "$SHIM_LOG"
  grep -q '^pkill ' "$SHIM_LOG"
  [ ! -e "$STATE/iscsid-running" ]
  : > "$SHIM_LOG"
  touch "$STATE/iscsid-running"
  run_test
  [ "$status" -eq 0 ]
  run ! grep -E '^(iscsid|pkill)' "$SHIM_LOG"
  [ -e "$STATE/iscsid-running" ]
}

@test "--initiator-name different from the file: written, a running iscsid restarted" {
  touch "$STATE/iscsid-running"
  run_test --initiator-name iqn.2026-11.example:other
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_ISCSI_INITIATORNAME")" = "InitiatorName=iqn.2026-11.example:other" ]
  grep -q '^pkill ' "$SHIM_LOG"
  grep -qxF 'iscsid ' "$SHIM_LOG"
}

@test "--initiator-name equal to the file: nothing rewritten, no restart" {
  touch "$STATE/iscsid-running"
  run_test --initiator-name "$IPN"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_ISCSI_INITIATORNAME")" = "InitiatorName=$IPN" ]
  run ! grep -E '^(iscsid|pkill)' "$SHIM_LOG"
}

@test "without --initiator-name the file is left alone" {
  run_test
  [ "$(cat "$HPS_ISCSI_INITIATORNAME")" = "InitiatorName=$IPN" ]
}

@test "discovery failure and a target not offered: failed (3), no login" {
  touch "$STATE/discovery-fail"
  run_test
  [ "$status" -eq 3 ]
  [[ "$output" == "ISCSI TEST FAILED: discovery"* ]]
  rm "$STATE/discovery-fail"
  touch "$STATE/discovery-empty"
  run_test
  [ "$status" -eq 3 ]
  [[ "$output" == *"was not offered"* ]]
  run ! grep -e '--login' "$SHIM_LOG"
  [ ! -e "$STATE/iscsid-running" ]
}

@test "login failure: failed (3), no I/O" {
  touch "$STATE/login-fail"
  run_test
  [ "$status" -eq 3 ]
  [[ "$output" == "ISCSI TEST FAILED: login"* ]]
  run ! grep '^dd ' "$SHIM_LOG"
  run ! grep -e '--logout' "$SHIM_LOG"
}

@test "no block device appears: failed (3), logged out" {
  touch "$STATE/no-device"
  run_test
  [ "$status" -eq 3 ]
  [[ "$output" == *"no block device"* ]]
  run ! grep '^dd ' "$SHIM_LOG"
  logged_out
}

@test "a LUN smaller than 1 GiB is refused (3) before any write, logged out" {
  FAKE_SIZE=536870912 run_test
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs at least"* ]]
  run ! grep 'seek=' "$SHIM_LOG"
  logged_out
}

@test "read-back mismatch: FAILED verdict (3) and still logged out" {
  FAKE_CMP_RC=1 run_test
  [ "$status" -eq 3 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "ISCSI TEST FAILED: read-back differs"* ]]
  logged_out
  [ ! -e "$STATE/iscsid-running" ]
}

@test "a failing write: failed (3), logged out, no read-back attempted" {
  FAKE_DD_WRITE_RC=1 run_test
  [ "$status" -eq 3 ]
  [[ "$output" == *"writing to /dev/fake-sdz failed"* ]]
  run ! grep 'skip=' "$SHIM_LOG"
  logged_out
}

@test "the only write target is the discovered LUN device; the temp dir is removed" {
  run_test
  [ "$status" -eq 0 ]
  run ! grep -E '^dd .*of=/dev/(sd|zd|nvme|vd|md)' "$SHIM_LOG"
  [ "$(grep -c '^dd .*of=/dev/' "$SHIM_LOG")" -eq 1 ]
  [ -z "$(find /tmp -maxdepth 1 -name 'hps-iscsi-test-*' 2> /dev/null)" ]
}
