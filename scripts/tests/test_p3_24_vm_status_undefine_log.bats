#!/usr/bin/env bats
#
# CS-3.3: vm-status, vm-undefine, vm-console-log.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-24.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "vm-status VM: list --all, dominfo, domblklist, domstate; last line VM vm1 running" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-status" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "list dominfo dominfo domblklist domstate" ]
  [[ "$output" == *"vda"* ]]
}

@test "vm-status: every defined guest, one VM line each, last line is a VM line" {
  p3_20_fake_dom vm1 running
  p3_20_fake_dom vm2 "shut off"
  run bash "$S/vm-status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VM vm1 running"* ]]
  [ "${lines[-1]}" = "VM vm2 shut off" ]
}

@test "vm-status: read-only, no start/stop/define/undefine/destroy call" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-status"
  run ! grep -E '^virsh (start|shutdown|destroy|define|undefine)' "$SHIM_LOG"
}

@test "vm-status: no guests prints no VMs; an unknown guest exits 4; usage exits 2" {
  run bash "$S/vm-status"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "no VMs" ]
  run bash "$S/vm-status" vm9
  [ "$status" -eq 4 ]
  run bash "$S/vm-status" a b
  [ "$status" -eq 2 ]
  run bash "$S/vm-status" -x
  [ "$status" -eq 2 ]
}

@test "vm-undefine: shut-off guest: domstate, undefine --nvram; nothing else; last line VM vm1 undefined" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-undefine" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 undefined" ]
  [ "$(awk '$1=="virsh"' "$SHIM_LOG" | paste -sd'|' -)" = "virsh domstate vm1|virsh undefine --nvram vm1" ]
  [ ! -e "$STATE/dom.vm1" ]
}

@test "vm-undefine: idempotent, an undefined guest is a no-op (0)" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-undefine" vm1
  : > "$SHIM_LOG"
  run bash "$S/vm-undefine" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 undefined" ]
  run ! grep -q '^virsh undefine' "$SHIM_LOG"
}

@test "vm-undefine: a running guest is refused (3), nothing undefined" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-undefine" vm1
  [ "$status" -eq 3 ]
  run ! grep -q '^virsh undefine' "$SHIM_LOG"
  [ -e "$STATE/dom.vm1" ]
}

@test "vm-undefine: touches no disk, mirror or image: only virsh is called" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-undefine" vm1
  [ "$(awk '{print $1}' "$SHIM_LOG" | sort -u)" = "virsh" ]
  [ "$(tr -d '\0' < "$DISK" | wc -c)" -eq 0 ]
  [ -f "$IMG" ]
}

@test "vm-undefine: usage 2, bad name 3" {
  run bash "$S/vm-undefine"
  [ "$status" -eq 2 ]
  run bash "$S/vm-undefine" -x
  [ "$status" -eq 2 ]
  run bash "$S/vm-undefine" BAD
  [ "$status" -eq 3 ]
}

@test "vm-console-log: tails 200 lines by default, --lines N otherwise, read-only" {
  seq 1 500 > "$HPS_LIBVIRT_LOGDIR/vm1-serial.log"
  run bash "$S/vm-console-log" vm1
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -ge 200 ]
  [ "${lines[-1]}" = "500" ]
  run bash "$S/vm-console-log" vm1 --lines 3
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^[0-9]*$')" -eq 3 ]
  [ "$(wc -l < "$HPS_LIBVIRT_LOGDIR/vm1-serial.log")" -eq 500 ]
}

@test "vm-console-log: no log exits 4; usage exits 2" {
  run bash "$S/vm-console-log" vm1
  [ "$status" -eq 4 ]
  run bash "$S/vm-console-log"
  [ "$status" -eq 2 ]
  run bash "$S/vm-console-log" vm1 --lines x
  [ "$status" -eq 2 ]
  run bash "$S/vm-console-log" vm1 --bogus
  [ "$status" -eq 2 ]
}
