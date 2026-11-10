#!/usr/bin/env bats
#
# CS-3.12a: iscsi-login-test. Log in through leg-resolve, read the first MiB,
# log out and delete the node record; iscsiadm is a stateful shim, dd is real.

bats_require_minimum_version 1.5.0
load p2_30_helpers

IQN="iqn.2026-11.hps.lab:sch-001:t0"
PORTAL="10.100.1.10"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-84.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_LEG_TIMEOUT=2
  mkdir -p "$HPS_DEV/disk/by-path"
  DEV="$HPS_DEV/disk/by-path/ip-$PORTAL:3260-iscsi-$IQN-lun-0"
  SCRIPT="$S/iscsi-login-test"
  cat > "$TEST_DIR/bin/iscsiadm" <<'SHIM'
#!/usr/bin/env bash
echo "iscsiadm $*" >> "$SHIM_LOG"
case "$2" in
  session)
    [[ -s "$STATE/sessions" ]] && { cat "$STATE/sessions"; exit 0; }
    exit 21 ;;
  discovery) echo "$6:3260,1 iqn.fake"; exit 0 ;;
  node)
    iqn="$4"; ip="$6"
    case "$7" in
      --login)
        [[ "${FAKE_LOGIN_RC:-0}" -eq 0 ]] || exit "$FAKE_LOGIN_RC"
        echo "tcp: [1] $ip:3260,1 $iqn (non-flash)" >> "$STATE/sessions"
        touch "$STATE/record"
        if [[ ! -e "$STATE/nolun" ]]; then
          head -c "$(cat "$STATE/lunsize" 2>/dev/null || echo 2097152)" /dev/zero > "$HPS_DEV/disk/by-path/ip-$ip:3260-iscsi-$iqn-lun-0"
        fi ;;
      --logout)
        [[ "${FAKE_LOGOUT_RC:-0}" -eq 0 ]] || exit "$FAKE_LOGOUT_RC"
        rm -f "$STATE/sessions" "$HPS_DEV/disk/by-path/ip-$ip:3260-iscsi-$iqn-lun-0" ;;
      -o)
        [[ -e "$STATE/record" ]] || exit 21
        rm -f "$STATE/record" ;;
    esac
    exit 0 ;;
esac
SHIM
  printf '#!/usr/bin/env bash\necho "udevadm $*" >> "$SHIM_LOG"\n' > "$TEST_DIR/bin/udevadm"
  chmod +x "$TEST_DIR"/bin/*
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

@test "success: device printed, 1 MiB read, last line ISCSI <iqn> <device> <bytes> OK" {
  run --separate-stderr bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$DEV" ]
  [ "${lines[-1]}" = "ISCSI $IQN $DEV 1048576 OK" ]
  [[ "$stderr" == *"+ dd if=$DEV of=/dev/null bs=1M count=1"* ]]
}

@test "login goes through leg-resolve: discovery, then login, then settle" {
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m discovery -t sendtargets -p $PORTAL" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $PORTAL --login" "$SHIM_LOG"
  grep -q '^udevadm settle' "$SHIM_LOG"
}

@test "it leaves nothing behind: logged out, node record deleted, device gone" {
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $PORTAL --logout" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $PORTAL -o delete" "$SHIM_LOG"
  [ ! -s "$STATE/sessions" ]
  [ ! -e "$STATE/record" ]
  [ ! -e "$DEV" ]
}

@test "the order is login, read, logout, delete" {
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 0 ]
  l=$(grep -n -- '--login' "$SHIM_LOG" | cut -d: -f1)
  o=$(grep -n -- '--logout' "$SHIM_LOG" | cut -d: -f1)
  d=$(grep -n -- '-o delete' "$SHIM_LOG" | cut -d: -f1)
  [ "$l" -lt "$o" ]
  [ "$o" -lt "$d" ]
}

@test "a session for the iqn that already exists is refused (3) and left alone" {
  echo "tcp: [1] $PORTAL:3260,1 $IQN (non-flash)" > "$STATE/sessions"
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"already logged in"* ]]
  run ! grep -E -- '--login|--logout|-o delete' "$SHIM_LOG"
  [ -s "$STATE/sessions" ]
}

@test "a LUN that never appears: refused (3), and it still logs out and deletes the record" {
  touch "$STATE/nolun"
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 3 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $PORTAL --logout" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $PORTAL -o delete" "$SHIM_LOG"
  [ ! -e "$STATE/record" ]
}

@test "a failing login is a failed command (its exit code), no ISCSI line" {
  FAKE_LOGIN_RC=8 run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 8 ]
  run ! grep -q '^ISCSI ' <<< "$output"
}

@test "a LUN shorter than 1 MiB is a short read (1), still cleaned up" {
  echo 4096 > "$STATE/lunsize"
  run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"short read: 4096 of 1048576"* ]]
  [ ! -e "$STATE/record" ]
}

@test "a failing logout is a failure (1) even though the read worked, no OK line" {
  FAKE_LOGOUT_RC=5 run bash "$SCRIPT" "$PORTAL" "$IQN"
  [ "$status" -eq 1 ]
  run ! grep -q '^ISCSI .* OK$' <<< "$output"
}

@test "usage errors exit 2; bad portal or iqn exit 3; nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$PORTAL"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$PORTAL" "$IQN" extra
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" nonsense "$IQN"
  [ "$status" -eq 3 ]
  run bash "$SCRIPT" "$PORTAL" nonsense
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "it is registered as an allowlisted node script" {
  grep -qF 'iscsi-login-test.source = mkScript "iscsi-login-test" (scriptsDir + "/iscsi-login-test");' "$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  grep -qF 'iscsi-login-test.options.profile = "node";' "$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
}
