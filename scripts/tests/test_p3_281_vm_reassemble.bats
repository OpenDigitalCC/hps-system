#!/usr/bin/env bats
#
# vm-reassemble (docs/STORAGE-FAULTS.md "A paused guest", "A broken mirror"): a guest
# paused by an I/O error whose mirror the kernel calls broken is powered off (vm-stop
# --force), the array stopped (mdadm --stop, never mirror-stop), assembled again from
# the legs the sidecar records (mirror-assemble --drop-bbl) and the guest started
# (vm-start, with the priority it had). Refused (3) with nothing changed unless the
# guest is paused by an I/O error, a mirror of it is broken and both legs of every
# broken mirror resolve. The sibling scripts are replaced by stubs through the HPS_*
# hooks; mirror-assemble's own --drop-bbl is proved in test_p3_12.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers
load p3_20_helpers
load p3_280_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-281.XXXXXX")"
  export TEST_DIR
  p3_280_setup
  export HPS_SYS="$TEST_DIR/sys" HPS_MIRROR_DIR="$TEST_DIR/mirrors"
  p3_280_paused vm1 "I/O error"
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0"
  mkdir -p "$HPS_DEV/md" "$HPS_SYS/block/md127/md" "$HPS_MIRROR_DIR" "$TEST_DIR/stubs" "$TEST_DIR/order"
  export HPS_GUEST_ORDER_DIR="$TEST_DIR/order"
  ln -sf "$HPS_DEV/md127" "$HPS_DEV/md/vm1-disk0"
  echo broken > "$HPS_SYS/block/md127/md/array_state"
  sidecar vm1-disk0 1
  stubs
}

teardown() {
  rm -rf "$TEST_DIR"
}

# sidecar <mirror> <remote index>: what mirror-assemble recorded.
sidecar() {
  printf '{"name":"%s","remote_index":%s,"legs":[{"spec":"%s","dev":"/d/a","kind":"local","write_mostly":0},{"spec":"%s","dev":"/d/b","kind":"remote","write_mostly":1}]}\n' \
    "$1" "$2" "$P3_LOC_SPEC" "$P3_REM_SPEC" > "$HPS_MIRROR_DIR/$1.json"
}

# stubs: the four sibling scripts log their call to SHIM_LOG; a file in $STATE says how one fails.
stubs() {
  local n
  for n in vm-stop vm-start mirror-assemble leg-resolve; do
    cat > "$TEST_DIR/stubs/$n" <<'STUB'
#!/usr/bin/env bash
n=$(basename "$0")
echo "$n $*" >> "$SHIM_LOG"
[[ -e "$STATE/$n-fails" ]] && exit 1
if [[ "$n" == leg-resolve ]]; then
  grep -qxF "$1" "$STATE/leg-missing" 2> /dev/null && exit 3
  echo "/dev/fake"
fi
[[ "$n" == vm-start ]] && echo "VM $1 running"
exit 0
STUB
    chmod +x "$TEST_DIR/stubs/$n"
  done
  export HPS_VM_STOP="$TEST_DIR/stubs/vm-stop" HPS_VM_START="$TEST_DIR/stubs/vm-start"
  export HPS_MIRROR_ASSEMBLE="$TEST_DIR/stubs/mirror-assemble" HPS_LEG_RESOLVE="$TEST_DIR/stubs/leg-resolve"
}

# line <pattern>: the line number of the first SHIM_LOG line matching it.
line() { grep -n -m1 -E "$1" "$SHIM_LOG" | cut -d: -f1; }

nothing_changed() {
  run ! grep -E '^(vm-stop|vm-start|mirror-assemble|mdadm --stop|virsh destroy)' "$SHIM_LOG"
}

@test "a paused guest on a broken mirror: vm-stop --force, mdadm --stop, mirror-assemble --drop-bbl from the sidecar legs, vm-start, in that order" {
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [[ "$output" == *"REASSEMBLED vm1 vm1-disk0"* ]]
  grep -qxF "vm-stop vm1 --force" "$SHIM_LOG"
  grep -qxF "mdadm --stop /dev/md/vm1-disk0" "$SHIM_LOG"
  grep -qxF "mirror-assemble vm1-disk0 --leg $P3_LOC_SPEC --leg $P3_REM_SPEC --remote-index 1 --drop-bbl" "$SHIM_LOG"
  grep -qxF "vm-start vm1 --priority 3" "$SHIM_LOG"
  [ "$(line '^vm-stop')" -lt "$(line '^mdadm --stop')" ]
  [ "$(line '^mdadm --stop')" -lt "$(line '^mirror-assemble')" ]
  [ "$(line '^mirror-assemble')" -lt "$(line '^vm-start')" ]
}

@test "the legs are resolved (logged in again) before anything is stopped" {
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  grep -qxF "leg-resolve $P3_LOC_SPEC" "$SHIM_LOG"
  grep -qxF "leg-resolve $P3_REM_SPEC" "$SHIM_LOG"
  [ "$(line '^leg-resolve')" -lt "$(line '^vm-stop')" ]
}

@test "the priority and the storage role the guest was started with are passed on to vm-start" {
  echo "5 1" > "$HPS_GUEST_ORDER_DIR/vm1"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  grep -qxF "vm-start vm1 --priority 5 --provides-storage" "$SHIM_LOG"
}

@test "a mirror with no remote leg index in the sidecar is assembled without --remote-index" {
  sidecar vm1-disk0 null
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  grep -qxF "mirror-assemble vm1-disk0 --leg $P3_LOC_SPEC --leg $P3_REM_SPEC --drop-bbl" "$SHIM_LOG"
}

@test "mirror-stop is never used (it would log the legs out), and --force is vm-stop's only" {
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-reassemble' | grep -E 'mirror-stop|iscsiadm|--logout'"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-reassemble' | grep -E -- '--force' | grep -v 'HPS_VM_STOP'"
  run bash "$S/vm-reassemble" vm1
  run ! grep -E 'iscsiadm|mirror-stop' "$SHIM_LOG"
}

@test "only the broken mirror of two is stopped and assembled; the healthy one is left alone" {
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0" "$HPS_DEV/md/vm1-disk1"
  ln -sf "$HPS_DEV/md128" "$HPS_DEV/md/vm1-disk1"
  mkdir -p "$HPS_SYS/block/md128/md"
  echo clean > "$HPS_SYS/block/md128/md/array_state"
  sidecar vm1-disk1 1
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"mirror vm1-disk1 is not broken: left alone"* ]]
  grep -qxF "mdadm --stop /dev/md/vm1-disk0" "$SHIM_LOG"
  run ! grep -F 'vm1-disk1' "$SHIM_LOG"
}

@test "two broken mirrors are both stopped and assembled, then the guest starts once" {
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0" "$HPS_DEV/md/vm1-disk1"
  ln -sf "$HPS_DEV/md128" "$HPS_DEV/md/vm1-disk1"
  mkdir -p "$HPS_SYS/block/md128/md"
  echo broken > "$HPS_SYS/block/md128/md/array_state"
  sidecar vm1-disk1 1
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^mirror-assemble' "$SHIM_LOG")" -eq 2 ]
  [ "$(grep -c '^vm-start' "$SHIM_LOG")" -eq 1 ]
  [ "$(grep -c '^vm-stop' "$SHIM_LOG")" -eq 1 ]
}

#--- refusals: nothing is changed -------------------------------------------------------

@test "not defined exits 4, nothing changed" {
  run bash "$S/vm-reassemble" vm9
  [ "$status" -eq 4 ]
  nothing_changed
}

@test "a running guest is refused (3) with REFUSED not-paused" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED not-paused vm1 is running"* ]]
  nothing_changed
}

@test "a guest an operator paused is refused (3) with REFUSED not-ioerror" {
  p3_280_paused vm1 user
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED not-ioerror vm1 is paused (user)"* ]]
  nothing_changed
}

@test "a mirror the kernel does not call broken is refused with REFUSED no-broken-mirror, naming vm-resume" {
  echo clean > "$HPS_SYS/block/md127/md/array_state"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED no-broken-mirror"* ]]
  [[ "$output" == *"vm-resume"* ]]
  nothing_changed
}

@test "a guest with no mirror at all is refused with no-broken-mirror" {
  p3_280_blk vm1 "$HPS_DEV/zvol/lab/enc/vm/vm1-disk0"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED no-broken-mirror"* ]]
  nothing_changed
}

@test "a leg that is not present or not logged in is refused (3), the leg named, the guest untouched" {
  echo "$P3_REM_SPEC" > "$STATE/leg-missing"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED legs"* ]]
  [[ "$output" == *"$P3_REM_SPEC (mirror vm1-disk0)"* ]]
  [[ "$output" != *"$P3_LOC_SPEC (mirror"* ]]
  nothing_changed
}

@test "both legs missing are both named" {
  printf '%s\n%s\n' "$P3_LOC_SPEC" "$P3_REM_SPEC" > "$STATE/leg-missing"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"$P3_LOC_SPEC (mirror vm1-disk0), $P3_REM_SPEC (mirror vm1-disk0)"* ]]
  nothing_changed
}

@test "no sidecar means the legs are not known: refused (3), nothing changed" {
  rm -f "$HPS_MIRROR_DIR/vm1-disk0.json"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED legs mirror vm1-disk0 has no sidecar"* ]]
  nothing_changed
}

@test "an unreadable guest state or disk list is exit 1, nothing changed" {
  touch "$STATE/domstate-fails"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  nothing_changed
  rm -f "$STATE/domstate-fails"
  touch "$STATE/domblklist-fails"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  nothing_changed
}

#--- failures after the guest is off ------------------------------------------------------

@test "vm-stop that fails is exit 1 and the array is not touched" {
  touch "$STATE/vm-stop-fails"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED vm1"* ]]
  run ! grep -E '^(mdadm --stop|mirror-assemble|vm-start)' "$SHIM_LOG"
}

@test "an array that will not stop is exit 1: the guest is off, nothing is assembled or started" {
  cat > "$TEST_DIR/bin/mdadm" <<'SHIM'
#!/usr/bin/env bash
echo "mdadm $*" >> "$SHIM_LOG"
[[ "$1" == --stop ]] && exit 1
exit 0
SHIM
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED vm1 mdadm --stop of vm1-disk0 failed"* ]]
  run ! grep -E '^(mirror-assemble|vm-start)' "$SHIM_LOG"
}

@test "a mirror-assemble that fails is exit 1: the guest stays off, and the message says so" {
  touch "$STATE/mirror-assemble-fails"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED vm1 mirror-assemble of vm1-disk0 failed"* ]]
  [[ "$output" == *"powered off"* ]]
  run ! grep -E '^vm-start' "$SHIM_LOG"
}

@test "a vm-start that fails is exit 1 and prints no running line" {
  touch "$STATE/vm-start-fails"
  run bash "$S/vm-reassemble" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED vm1 vm-start failed"* ]]
  [[ "$output" != *"VM vm1 running"* ]]
}

@test "usage errors exit 2, nothing runs" {
  run bash "$S/vm-reassemble"
  [ "$status" -eq 2 ]
  run bash "$S/vm-reassemble" -x
  [ "$status" -eq 2 ]
  run bash "$S/vm-reassemble" BAD
  [ "$status" -eq 2 ]
  run bash "$S/vm-reassemble" vm1 vm2
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

#--- wiring -------------------------------------------------------------------------------

@test "vm-reassemble: allowlisted once under profile node, in the bundle allowlist and the ctrl-exec module; no raw input" {
  local nix="${BATS_TEST_DIRNAME}/../../nix/modules/hps-ctrl-exec.nix"
  local al="${BATS_TEST_DIRNAME}/../../node-manager/bundle/allowlist"
  grep -qF 'vm-reassemble.source = mkScript "vm-reassemble" (scriptsDir + "/vm-reassemble");' "$nix"
  grep -qF 'vm-reassemble.options.profile = "node";' "$nix"
  [ "$(grep -cF 'vm-reassemble.source' "$nix")" -eq 1 ]
  run ! grep -F 'vm-reassemble.options.input' "$nix"
  grep -qxF 'vm-reassemble profile=node' "$al"
}

@test "vm-reassemble: executable, env shebang, set -euo pipefail, shellcheck clean, no library sourcing, no real values" {
  [ -x "$S/vm-reassemble" ]
  [ "$(head -1 "$S/vm-reassemble")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$S/vm-reassemble"
  shellcheck -S warning "$S/vm-reassemble"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-reassemble' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  run ! grep -nE '(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$S/vm-reassemble"
  run ! grep -nE 'password|PRIVATE KEY|secret=' "$S/vm-reassemble"
}
