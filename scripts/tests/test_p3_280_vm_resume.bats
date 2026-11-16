#!/usr/bin/env bats
#
# vm-resume, and the paused guest in vm-status and vm-stop (docs/STORAGE-FAULTS.md
# "A paused guest"). Proves: not defined 4; a guest that is not paused, or is
# paused by an operator (any reason but an I/O error) without --any-reason, is
# refused (3) with a REFUSED line and nothing resumed; an I/O-error pause is
# resumed only when every disk is healthy (mirror assembled, not failed, a leg in
# sync; pool ONLINE) and refused with the reason otherwise; unreadable state is
# exit 1, never a resume; the guest must run after the resume and keep running;
# vm-status prints the pause reason; vm-stop of a paused guest refuses without
# --force and does not wait with it.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers
load p3_20_helpers
load p3_280_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-280.XXXXXX")"
  export TEST_DIR
  p3_280_setup
  export HPS_VM_SETTLE=0
  p3_280_paused vm1 "I/O error"
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0"
  p3_280_md vm1-disk0 clean 2
}

teardown() {
  rm -rf "$TEST_DIR"
}

resumed() { grep -q '^virsh resume vm1' "$SHIM_LOG"; }

#--- the guest itself --------------------------------------------------------------

@test "vm-resume: a guest paused by an I/O error with a healthy mirror is resumed; last line VM vm1 running" {
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  resumed
  grep -q '^mdadm --detail '"$HPS_DEV"'/md/vm1-disk0' "$SHIM_LOG"
  [ "$(cat "$STATE/dom.vm1")" = running ]
}

@test "vm-resume: the reason is read as a token, so 'ioerror' is the same pause as 'I/O error'" {
  echo ioerror > "$STATE/reason.vm1"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  resumed
}

@test "vm-resume: not defined exits 4, nothing resumed" {
  run bash "$S/vm-resume" vm9
  [ "$status" -eq 4 ]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: a running guest is refused (3) with REFUSED not-paused" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED not-paused vm1 is running, not paused"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: a shut-off guest is refused (3) with REFUSED not-paused" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED not-paused"* ]]
}

@test "vm-resume: a guest an operator paused (user) is refused (3) with REFUSED operator-paused; no disk is looked at" {
  p3_280_paused vm1 user
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED operator-paused"* ]]
  [[ "$output" == *"--any-reason"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
  run ! grep -q '^mdadm' "$SHIM_LOG"
}

@test "vm-resume: a pause with no reason from libvirt is refused like an operator's" {
  rm -f "$STATE/reason.vm1"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED operator-paused vm1 is paused (unknown)"* ]]
}

@test "vm-resume --any-reason: an operator's pause is resumed, and no disk check is made for it" {
  p3_280_paused vm1 user
  run bash "$S/vm-resume" vm1 --any-reason
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  resumed
  run ! grep -q '^mdadm' "$SHIM_LOG"
}

@test "vm-resume --any-reason: an I/O-error pause is still checked against the disks" {
  p3_280_md vm1-disk0 "clean, FAILED" 0
  run bash "$S/vm-resume" vm1 --any-reason
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED disk mirror vm1-disk0 is clean, failed"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

#--- the disks ----------------------------------------------------------------------

@test "vm-resume: a degraded mirror with one leg in sync is healthy enough" {
  p3_280_md vm1-disk0 "clean, degraded" 1
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  resumed
}

@test "vm-resume: a failed mirror is refused (3, REFUSED disk), nothing resumed" {
  p3_280_md vm1-disk0 "clean, FAILED" 1
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED disk mirror vm1-disk0 is clean, failed"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: an inactive mirror, and one with no leg in sync, are refused" {
  p3_280_md vm1-disk0 inactive 0
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"is inactive"* ]]
  p3_280_md vm1-disk0 active 0
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"has no leg in sync"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: a mirror that is not assembled is refused, and so is one that reports no State or no Active Devices" {
  rm -f "$STATE/detail.vm1-disk0"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"mirror vm1-disk0 is not assembled"* ]]
  echo '   Active Devices : 2' > "$STATE/detail.vm1-disk0"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"reports no State"* ]]
  echo '           State : clean' > "$STATE/detail.vm1-disk0"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"no Active Devices figure"* ]]
}

@test "vm-resume: every disk must be healthy: one bad mirror of two refuses the resume" {
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0" "$HPS_DEV/md/vm1-disk1"
  p3_280_md vm1-disk1 "clean, FAILED" 0
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"mirror vm1-disk1"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: a local zvol needs its pool ONLINE" {
  p3_280_blk vm1 "$HPS_DEV/zvol/lab/enc/vm/vm1-disk0"
  echo ONLINE > "$STATE/pool.lab"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  grep -q '^zpool list -H -o health lab' "$SHIM_LOG"
  resumed
}

@test "vm-resume: a zvol pool that is DEGRADED, SUSPENDED or not imported is refused" {
  p3_280_blk vm1 "$HPS_DEV/zvol/lab/enc/vm/vm1-disk0"
  echo DEGRADED > "$STATE/pool.lab"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED disk pool lab is DEGRADED"* ]]
  echo SUSPENDED > "$STATE/pool.lab"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  rm -f "$STATE/pool.lab"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"pool lab is not imported"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: a mirror and a zvol together are both checked" {
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0" "$HPS_DEV/zvol/lab/enc/vm/vm1-scratch"
  echo DEGRADED > "$STATE/pool.lab"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  grep -q '^mdadm --detail' "$SHIM_LOG"
  grep -q '^zpool list' "$SHIM_LOG"
}

@test "vm-resume: a disk that is neither a mirror nor a zvol cannot be judged and is refused; a file and an empty drive are skipped" {
  p3_280_blk vm1 "$HPS_DEV/sdb"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"neither a mirror nor a zvol"* ]]
  p3_280_blk vm1 "$HPS_DEV/md/vm1-disk0" /var/lib/seed.iso -
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"is a file: not checked"* ]]
}

@test "vm-resume: a guest with no mirror or zvol to check is refused, not resumed blind" {
  p3_280_blk vm1 -
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"no mirror or zvol to check"* ]]
}

#--- state that cannot be read ----------------------------------------------------

@test "vm-resume: an unreadable guest state is exit 1, never a resume" {
  touch "$STATE/domstate-fails"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read the state of vm1"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

@test "vm-resume: an unreadable disk list is exit 1, never a resume" {
  touch "$STATE/domblklist-fails"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot read the disk list of vm1"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
}

#--- after the resume ------------------------------------------------------------------

@test "vm-resume: a virsh resume that fails is exit 1" {
  touch "$STATE/resume-fails"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 1 ]
}

@test "vm-resume: a guest that stays paused after the resume is exit 1 and prints no running line" {
  touch "$STATE/stays-paused"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 1 ]
  [[ "$output" != *"VM vm1 running"* ]]
  [[ "$output" == *"paused again"* ]]
}

@test "vm-resume: a guest that runs for a moment and is paused again by the settle check is exit 1" {
  touch "$STATE/repause"
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 1 ]
  [[ "$output" != *"VM vm1 running"* ]]
}

@test "vm-resume: never runs a mutating command but virsh resume (no start, destroy, mdadm change, zpool change)" {
  run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
  run ! grep -E '^virsh (start|shutdown|destroy|define|undefine|reboot|suspend)' "$SHIM_LOG"
  run ! grep -E '^mdadm (--assemble|--create|--stop|--add|--re-add|--fail|--remove)' "$SHIM_LOG"
  run ! grep -E '^zpool (online|clear|import|export|offline)' "$SHIM_LOG"
}

@test "vm-resume: usage errors exit 2" {
  run bash "$S/vm-resume"
  [ "$status" -eq 2 ]
  run bash "$S/vm-resume" -x
  [ "$status" -eq 2 ]
  run bash "$S/vm-resume" vm1 --bogus
  [ "$status" -eq 2 ]
  run bash "$S/vm-resume" BAD
  [ "$status" -eq 2 ]
  run bash "$S/vm-resume" vm1 vm2
  [ "$status" -eq 2 ]
  run ! grep -q '^virsh' "$SHIM_LOG"
}

#--- vm-status ---------------------------------------------------------------------------

@test "vm-status: a paused guest gets a PAUSED line with the reason token before its VM line" {
  run bash "$S/vm-status" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-2]}" = "PAUSED vm1 reason=ioerror" ]
  [ "${lines[-1]}" = "VM vm1 paused" ]
}

@test "vm-status: an operator's pause says user; a pause with no reason says unknown" {
  p3_280_paused vm1 user
  run bash "$S/vm-status" vm1
  [ "${lines[-2]}" = "PAUSED vm1 reason=user" ]
  rm -f "$STATE/reason.vm1"
  run bash "$S/vm-status" vm1
  [ "${lines[-2]}" = "PAUSED vm1 reason=unknown" ]
  [ "${lines[-1]}" = "VM vm1 paused" ]
}

@test "vm-status: a running guest has no PAUSED line, and the whole list names each paused guest" {
  p3_20_fake_dom vm2 running
  run bash "$S/vm-status" vm2
  [[ "$output" != *PAUSED* ]]
  run bash "$S/vm-status"
  [[ "$output" == *"PAUSED vm1 reason=ioerror"* ]]
  [[ "$output" == *"VM vm2 running"* ]]
}

@test "vm-status: still read-only with a paused guest" {
  run bash "$S/vm-status"
  run ! grep -E '^virsh (start|shutdown|destroy|define|undefine|resume|suspend)' "$SHIM_LOG"
}

#--- vm-stop -----------------------------------------------------------------------------

@test "vm-stop: a paused guest is refused (3) without --force, naming resume-paused and --force; nothing is shut down" {
  run bash "$S/vm-stop" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"resume-paused"* ]]
  [[ "$output" == *"--force"* ]]
  run ! grep -E '^virsh (shutdown|destroy)' "$SHIM_LOG"
  [ "$(cat "$STATE/dom.vm1")" = paused ]
}

@test "vm-stop --force: a paused guest is destroyed at once, with no graceful wait for a shutdown it cannot act on" {
  run bash "$S/vm-stop" vm1 --force
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 shut off" ]
  grep -q '^virsh destroy vm1' "$SHIM_LOG"
  run ! grep -q '^virsh shutdown' "$SHIM_LOG"
}

@test "vm-stop: a running guest is stopped as before (shutdown, no destroy)" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-stop" vm1
  [ "$status" -eq 0 ]
  grep -q '^virsh shutdown vm1' "$SHIM_LOG"
  run ! grep -q '^virsh destroy' "$SHIM_LOG"
}

#--- wiring ------------------------------------------------------------------------------

@test "vm-resume: allowlisted once under profile node in the ctrl-exec module; no raw input" {
  local nix="${BATS_TEST_DIRNAME}/../../nix/modules/hps-ctrl-exec.nix"
  grep -qF 'vm-resume.source = mkScript "vm-resume" (scriptsDir + "/vm-resume");' "$nix"
  grep -qF 'vm-resume.options.profile = "node";' "$nix"
  [ "$(grep -cF 'vm-resume.source' "$nix")" -eq 1 ]
  run ! grep -F 'vm-resume.options.input' "$nix"
}

@test "vm-resume: executable, env shebang, set -euo pipefail, shellcheck clean, no library sourcing, no real values" {
  [ -x "$S/vm-resume" ]
  [ "$(head -1 "$S/vm-resume")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$S/vm-resume"
  shellcheck -S warning "$S/vm-resume"
  shellcheck -S warning "$S/vm-status" "$S/vm-stop"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-resume' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  run ! grep -nE '(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)' "$S/vm-resume"
  run ! grep -nE 'password|PRIVATE KEY|secret=' "$S/vm-resume"
}

@test "vm-resume: no --force, no destroy, no start; mdadm and zpool only to read" {
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-resume' | grep -E -- '--force|virsh.* (destroy|start|undefine|define|shutdown)'"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-resume' | grep -E 'mdadm (--assemble|--create|--stop|--add|--re-add|--fail|--remove|--run)'"
  run ! bash -c "grep -v '^[[:space:]]*#' '$S/vm-resume' | grep -E 'zpool (online|clear|import|export|offline|create|destroy|replace)'"
}

@test "the CHANGELOG, VM-LIFECYCLE and the monitoring docs name vm-resume and the paused figure" {
  local root="${BATS_TEST_DIRNAME}/../.."
  grep -q 'vm-resume' "$root/docs/VM-LIFECYCLE.md"
  grep -q 'vm-resume' "$root/CHANGELOG.md"
  grep -q 'guest-paused' "$root/docs/ISSUES.md"
  grep -q 'paused=' "$root/docs/MONITORING.md"
}

@test "vm-resume: a mirror the kernel calls broken is refused even when mdadm says clean with both legs back" {
  mkdir -p "$HPS_DEV" "$TEST_DIR/sys/block/md127/md"
  ln -sf "$HPS_DEV/md127" "$HPS_DEV/md/vm1-disk0" 2> /dev/null || { mkdir -p "$HPS_DEV/md"; ln -sf "$HPS_DEV/md127" "$HPS_DEV/md/vm1-disk0"; }
  echo broken > "$TEST_DIR/sys/block/md127/md/array_state"
  HPS_SYS="$TEST_DIR/sys" run bash "$S/vm-resume" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED broken-mirror mirror vm1-disk0 is broken"* ]]
  [[ "$output" == *"vm-reassemble vm1"* ]]
  run ! grep -q '^virsh resume' "$SHIM_LOG"
  echo clean > "$TEST_DIR/sys/block/md127/md/array_state"
  HPS_SYS="$TEST_DIR/sys" run bash "$S/vm-resume" vm1
  [ "$status" -eq 0 ]
}
