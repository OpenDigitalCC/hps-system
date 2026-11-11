#!/usr/bin/env bats
#
# CS-3.3: vm-start, vm-stop.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-23.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "vm-start: starts a shut-off guest; calls domstate, start, domstate, dumpxml (VLAN metadata); last line VM vm1 running" {
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate start domstate dumpxml" ]
}

@test "vm-start: idempotent, a running guest is a no-op (no start call) and exits 0" {
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1
  : > "$SHIM_LOG"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate dumpxml" ]
}

@test "vm-start: not defined exits 4 and does not start" {
  run bash "$S/vm-start" vm1
  [ "$status" -eq 4 ]
  run ! grep -q '^virsh start' "$SHIM_LOG"
}

@test "vm-start: waits for the running state when libvirt is slow" {
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  echo 3 > "$STATE/startdelay"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [ "$(grep -c '^virsh domstate' "$SHIM_LOG")" -ge 4 ]
}

@test "vm-start: a guest that never reaches running exits 1 after the wait and prints no running line" {
  p3_20_fake_dom vm1 "shut off"
  touch "$STATE/never-running"
  HPS_VM_WAIT=2 run bash "$S/vm-start" vm1
  [ "$status" -eq 1 ]
  [[ "$output" != *"VM vm1 running"* ]]
}

@test "vm-start: a paused guest is refused (3), no start call" {
  p3_20_fake_dom vm1 paused
  run bash "$S/vm-start" vm1
  [ "$status" -eq 3 ]
  run ! grep -q '^virsh start' "$SHIM_LOG"
}

@test "vm-start: usage 2, bad name 3" {
  run bash "$S/vm-start"
  [ "$status" -eq 2 ]
  run bash "$S/vm-start" a b
  [ "$status" -eq 2 ]
  run bash "$S/vm-start" -x
  [ "$status" -eq 2 ]
  run bash "$S/vm-start" Bad_Name
  [ "$status" -eq 3 ]
}

@test "vm-stop: clean shutdown: domstate, shutdown, domstate; no destroy; last line VM vm1 shut off" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-stop" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 shut off" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate shutdown domstate" ]
}

@test "vm-stop: idempotent, a shut-off guest gets no shutdown call" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-stop" vm1
  : > "$SHIM_LOG"
  run bash "$S/vm-stop" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 shut off" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate" ]
}

@test "vm-stop: waits while the guest shuts down slowly" {
  p3_20_fake_dom vm1 running
  echo 3 > "$STATE/stopdelay"
  run bash "$S/vm-stop" vm1 --timeout 5
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 shut off" ]
}

@test "vm-stop: a guest that ignores the shutdown is NOT destroyed without --force (exit 1)" {
  p3_20_fake_dom vm1 running
  touch "$STATE/stubborn"
  run bash "$S/vm-stop" vm1 --timeout 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"not forcing"* ]]
  run ! grep -q '^virsh destroy' "$SHIM_LOG"
  [[ "$output" != *"VM vm1 shut off"* ]]
}

@test "vm-stop: --force destroys after the timeout, then reports shut off" {
  p3_20_fake_dom vm1 running
  touch "$STATE/stubborn"
  run bash "$S/vm-stop" vm1 --timeout 2 --force
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 shut off" ]
  [ "$(p3_20_virsh_cmds | grep -c '^destroy$')" -eq 1 ]
  [ "$(p3_20_virsh_cmds | sed -n 2p)" = "shutdown" ]
}

@test "vm-stop: --force does not destroy a guest that shut down in time" {
  p3_20_fake_dom vm1 running
  run bash "$S/vm-stop" vm1 --force
  [ "$status" -eq 0 ]
  run ! grep -q '^virsh destroy' "$SHIM_LOG"
}

@test "vm-stop: not defined exits 4" {
  run bash "$S/vm-stop" vm1
  [ "$status" -eq 4 ]
}

@test "vm-stop: usage errors exit 2" {
  run bash "$S/vm-stop"
  [ "$status" -eq 2 ]
  run bash "$S/vm-stop" vm1 --timeout
  [ "$status" -eq 2 ]
  run bash "$S/vm-stop" vm1 --timeout x
  [ "$status" -eq 2 ]
  run bash "$S/vm-stop" vm1 --bogus
  [ "$status" -eq 2 ]
  run bash "$S/vm-stop" -f
  [ "$status" -eq 2 ]
}
