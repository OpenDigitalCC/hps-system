#!/usr/bin/env bats
#
# vm-save / vm-restore: suspend a running guest to a state file on the pool
# (virsh save --running) and bring it back (virsh restore). Shims: virsh (state
# in $STATE), zfs (a dataset exists when $STATE/ds.<name> does) and df (the
# free bytes in $STATE/avail). The state file path is under HPS_STATE_ROOT.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-257.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  SAVE="$S/vm-save"
  RESTORE="$S/vm-restore"
  export HPS_STATE_ROOT="$TEST_DIR/root"
  mkdir -p "$HPS_STATE_ROOT/lab/enc/state"
  F=/lab/enc/state/s1-sch-001.save
  echo running > "$STATE/domstate.s1-sch-001"
  touch "$STATE/ds.lab_enc" "$STATE/ds.lab_enc_state" "$STATE/mounted.lab_enc_state"
  echo available > "$STATE/keystatus"
  echo 107374182400 > "$STATE/avail"
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
echo "virsh $*" >> "$SHIM_LOG"
shift 2  # -c qemu:///system
case "$1" in
  domstate) cat "$STATE/domstate.$2" 2> /dev/null || { echo "error: no domain" >&2; exit 1; } ;;
  dominfo) printf 'Name: %s\nMax memory: 8388608 KiB\nUsed memory: %s KiB\n' "$2" "${FAKE_USED_KIB:-4194304}" ;;
  save)
    [[ -n "${FAKE_SAVE_RC:-}" ]] && exit "$FAKE_SAVE_RC"
    echo "shut off" > "$STATE/domstate.$3"
    head -c 4096 /dev/zero > "$4" ;;
  restore)
    [[ -n "${FAKE_RESTORE_RC:-}" ]] && exit "$FAKE_RESTORE_RC"
    echo running > "$STATE/domstate.s1-sch-001" ;;
esac
SHIM
  cat > "$TEST_DIR/bin/zfs" <<'SHIM'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
# A dataset created or given a mountpoint is mounted (the pool has mountpoint=none:
# a dataset made without one is not). $STATE/set-no-mount: a set that leaves it unmounted.
n=${@: -1}; k=${n//\//_}
case "$1" in
  list) [[ -e "$STATE/ds.$k" ]] || exit 1 ;;
  create)
    [[ -e "$STATE/create-fails" ]] && exit 1
    touch "$STATE/ds.$k"
    [[ "$*" == *"-o mountpoint=/"* ]] && touch "$STATE/mounted.$k"
    exit 0 ;;
  set) [[ -e "$STATE/set-no-mount" ]] || touch "$STATE/mounted.${n//\//_}" ;;
  mount) touch "$STATE/mounted.$k" ;;
  get)
    case "$5" in
      keystatus) cat "$STATE/keystatus" ;;
      mounted) if [[ -e "$STATE/mounted.$k" ]]; then echo yes; else echo no; fi ;;
    esac ;;
esac
SHIM
  cat > "$TEST_DIR/bin/df" <<'SHIM'
#!/usr/bin/env bash
echo "df $*" >> "$SHIM_LOG"
printf 'Avail\n%s\n' "$(cat "$STATE/avail")"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "both are executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean" {
  local s
  for s in "$SAVE" "$RESTORE"; do
    [ -x "$s" ]
    [ "$(head -1 "$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$s"
    grep -q '^run() {' "$s"
    run ! grep -E '^[[:space:]]*(source|\.) ' "$s"
    shellcheck -S warning "$s"
  done
}

@test "vm-save saves a running guest to the state file and reports its size" {
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "VM-SAVE s1-sch-001 $F 4096" ]
  [ -f "$HPS_STATE_ROOT$F" ]
  grep -qxF "virsh -c qemu:///system save --running s1-sch-001 $HPS_STATE_ROOT$F" "$SHIM_LOG"
  run ! grep -q "zfs create" "$SHIM_LOG"
}

@test "vm-save creates the state dataset on first use under the encrypted parent, with a mountpoint" {
  rm "$STATE/ds.lab_enc_state" "$STATE/mounted.lab_enc_state"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  # the pool has mountpoint=none: without -o mountpoint the dataset is never mounted (the 2026-11-15 failure)
  grep -qxF "zfs create -o mountpoint=/lab/enc/state -o recordsize=1M lab/enc/state" "$SHIM_LOG"
  grep -qF "virsh -c qemu:///system save --running" "$SHIM_LOG"
}

@test "vm-save: a second save finds the dataset there and creates nothing" {
  rm "$STATE/ds.lab_enc_state" "$STATE/mounted.lab_enc_state"
  bash "$SAVE" s1-sch-001 --state "$F" 2> /dev/null
  echo running > "$STATE/domstate.s1-sch-001"
  rm "$HPS_STATE_ROOT$F"
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  run ! grep -qE "zfs (create|set|mount)" "$SHIM_LOG"
}

@test "vm-save: an existing but unmounted dataset gets its mountpoint set, which mounts it, with no second mount" {
  rm "$STATE/mounted.lab_enc_state"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  grep -qxF "zfs set mountpoint=/lab/enc/state lab/enc/state" "$SHIM_LOG"
  run ! grep -q "zfs mount" "$SHIM_LOG"
  run ! grep -q "zfs create" "$SHIM_LOG"
}

@test "vm-save: a mountpoint set that leaves the dataset unmounted is followed by zfs mount" {
  rm "$STATE/mounted.lab_enc_state"
  touch "$STATE/set-no-mount"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  grep -qxF "zfs mount lab/enc/state" "$SHIM_LOG"
}

@test "vm-save refuses a pool with no enc dataset, naming the dataset and the fix; the guest keeps running" {
  rm "$STATE/ds.lab_enc_state" "$STATE/ds.lab_enc"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"lab/enc does not exist"* ]]
  [[ "$stderr" == *"hps-storage <host> up"* ]]
  run ! grep -qE "virsh.* save|zfs create" "$SHIM_LOG"
  [ "$(cat "$STATE/domstate.s1-sch-001")" = running ]
}

@test "vm-save refuses when the key of the parent is not loaded; nothing is created" {
  rm "$STATE/ds.lab_enc_state"
  echo unavailable > "$STATE/keystatus"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"lab/enc is locked (keystatus unavailable)"* ]]
  run ! grep -qE "virsh.* save|zfs create" "$SHIM_LOG"
}

@test "vm-save: a failing zfs create is exit 1, the guest keeps running" {
  rm "$STATE/ds.lab_enc_state" "$STATE/mounted.lab_enc_state"
  touch "$STATE/create-fails"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot create lab/enc/state"* ]]
  run ! grep -q "virsh.* save" "$SHIM_LOG"
}

@test "vm-save refuses when the dataset is there but its directory is not (named, with the fix)" {
  rm -r "$HPS_STATE_ROOT/lab"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"/lab/enc/state is not a directory"* ]]
  [[ "$stderr" == *"zfs set mountpoint=/lab/enc/state lab/enc/state"* ]]
  run ! grep -q "virsh.* save" "$SHIM_LOG"
}

@test "vm-save refuses a guest that is not running" {
  echo "shut off" > "$STATE/domstate.s1-sch-001"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"is shut off"* ]]
  run ! grep -q "virsh.* save" "$SHIM_LOG"
}

@test "vm-save refuses when the state file exists" {
  : > "$HPS_STATE_ROOT$F"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"already exists"* ]]
  run ! grep -q "virsh.* save" "$SHIM_LOG"
}

@test "vm-save refuses when the state dataset cannot hold the guest's memory, naming the figures" {
  echo 1000000000 > "$STATE/avail"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"needs 4294967296 bytes, has 1000000000 bytes"* ]]
  [[ "$stderr" == *"keeps running"* ]]
  run ! grep -q "virsh.* save" "$SHIM_LOG"
  [ "$(cat "$STATE/domstate.s1-sch-001")" = running ]
  [ ! -e "$HPS_STATE_ROOT$F" ]
  echo 4294967296 > "$STATE/avail"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
}

@test "vm-save: usage 2, not defined 4, a failing virsh save 1" {
  run bash "$SAVE"
  [ "$status" -eq 2 ]
  run bash "$SAVE" s1-sch-001
  [ "$status" -eq 2 ]
  run bash "$SAVE" s1-sch-001 --state /lab/enc/state/other.save
  [ "$status" -eq 2 ]
  run bash "$SAVE" s1-sch-001 --state /etc/passwd
  [ "$status" -eq 2 ]
  run bash "$SAVE" 'Bad;vm' --state "$F"
  [ "$status" -eq 2 ]
  run bash "$SAVE" ghost --state /lab/enc/state/ghost.save
  [ "$status" -eq 4 ]
  FAKE_SAVE_RC=1 run bash "$SAVE" s1-sch-001 --state "$F"
  [ "$status" -eq 1 ]
}

@test "vm-save --discard removes the state file and nothing else" {
  : > "$HPS_STATE_ROOT$F"
  run --separate-stderr bash "$SAVE" s1-sch-001 --state "$F" --discard
  [ "$status" -eq 0 ]
  [ "$output" = "VM-SAVE s1-sch-001 $F discarded" ]
  [ ! -e "$HPS_STATE_ROOT$F" ]
  run ! grep -q "virsh" "$SHIM_LOG"
}

@test "vm-restore restores a saved guest and removes the state file" {
  bash "$SAVE" s1-sch-001 --state "$F" 2> /dev/null
  run --separate-stderr bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 0 ]
  [ "$output" = "VM-RESTORE s1-sch-001 running" ]
  grep -qxF "virsh -c qemu:///system restore $HPS_STATE_ROOT$F" "$SHIM_LOG"
  [ ! -e "$HPS_STATE_ROOT$F" ]
  [ "$(cat "$STATE/domstate.s1-sch-001")" = running ]
}

@test "vm-restore refuses with no state file, and with the guest already running" {
  run --separate-stderr bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no state file"* ]]
  [[ "$stderr" == *"lab/enc/state is mounted but holds no s1-sch-001.save"* ]]
  : > "$HPS_STATE_ROOT$F"
  run --separate-stderr bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"already running"* ]]
  [ -f "$HPS_STATE_ROOT$F" ]
  run ! grep -q "virsh.* restore" "$SHIM_LOG"
}

@test "vm-restore with the state file absent says why: dataset missing, or not mounted" {
  rm "$STATE/ds.lab_enc_state" "$STATE/mounted.lab_enc_state"
  run --separate-stderr bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"the dataset lab/enc/state does not exist on this host"* ]]
  touch "$STATE/ds.lab_enc_state"
  run --separate-stderr bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"the dataset lab/enc/state is not mounted"* ]]
  [[ "$stderr" == *"hps-storage <host> up"* ]]
  run ! grep -q "virsh.* restore" "$SHIM_LOG"
}

@test "vm-restore: usage 2, not defined 4, a failing restore 1 keeps the file" {
  run bash "$RESTORE" s1-sch-001
  [ "$status" -eq 2 ]
  run bash "$RESTORE" s1-sch-001 --state /etc/passwd
  [ "$status" -eq 2 ]
  mkdir -p "$HPS_STATE_ROOT/lab/enc/state"
  : > "$HPS_STATE_ROOT/lab/enc/state/ghost.save"
  run bash "$RESTORE" ghost --state /lab/enc/state/ghost.save
  [ "$status" -eq 4 ]
  echo "shut off" > "$STATE/domstate.s1-sch-001"
  : > "$HPS_STATE_ROOT$F"
  FAKE_RESTORE_RC=1 run bash "$RESTORE" s1-sch-001 --state "$F"
  [ "$status" -eq 1 ]
  [ -f "$HPS_STATE_ROOT$F" ]
}

@test "both are on the ctrl-exec allowlist and named in VM-LIFECYCLE.md" {
  grep -q 'vm-save.source = mkScript "vm-save"' "$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  grep -q 'vm-restore.source = mkScript "vm-restore"' "$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  grep -q 'vm-save <vm> --state' "$BATS_TEST_DIRNAME/../../docs/VM-LIFECYCLE.md"
  grep -q 'vm-restore <vm> --state' "$BATS_TEST_DIRNAME/../../docs/VM-LIFECYCLE.md"
}
