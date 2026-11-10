#!/usr/bin/env bats
#
# CS-3.12a: vm-define --boot network (OVMF netboot, optional --mac per --net,
# no disk), and the MACs reported on the last lines.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-82.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "network boot with no disk and no image: defined, boot dev network, no disk element" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  grep -qF "<boot dev='network'/>" "$x"
  run ! grep -qF "<boot dev='hd'/>" "$x"
  run ! grep -qF "<disk " "$x"
  run ! grep -qF "<hps:image>" "$x"
  grep -qF "<source bridge='br-prov'/>" "$x"
  grep -q "machine='q35'" "$x"
  grep -q "edk2-x86_64-code.fd" "$x"
}

@test "the last line is VM <vm> defined mac=<mac>, the libvirt-generated MAC read back with domiflist" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM n1 defined mac=52:54:00:00:00:01" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "dominfo define domiflist" ]
}

@test "--mac fixes the MAC of the --net before it; one mac line per NIC in --net order" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc --net br-work
  [ "$status" -eq 0 ]
  grep -qF "<mac address='52:54:00:aa:bb:cc'/>" "$STATE/xml.n1"
  [ "${lines[-2]}" = "VM n1 defined mac=52:54:00:aa:bb:cc" ]
  [ "${lines[-1]}" = "VM n1 defined mac=52:54:00:00:00:02" ]
}

@test "network boot with a disk: network first, then hd" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --disk "$DISK" --net br-prov
  [ "$status" -eq 0 ]
  x="$STATE/xml.n1"
  grep -qF "<source dev='$DISK'/>" "$x"
  n=$(grep -n "<boot dev='network'/>" "$x" | cut -d: -f1)
  h=$(grep -n "<boot dev='hd'/>" "$x" | cut -d: -f1)
  [ "$n" -lt "$h" ]
}

@test "idempotent: the same network definition again defines nothing and still reports the MAC" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM n1 defined mac=52:54:00:aa:bb:cc" ]
  run ! grep -q '^virsh define' "$SHIM_LOG"
}

@test "a different MAC for the same name is a different definition (3)" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc
  [ "$status" -eq 0 ]
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:dd
  [ "$status" -eq 3 ]
}

@test "disk boot (default) still needs --disk and --image (2) and still ends VM <vm> defined" {
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --net br-work
  [ "$status" -eq 2 ]
  run p3_20_define
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 defined" ]
  grep -qF "<boot dev='hd'/>" "$STATE/xml.vm1"
}

@test "--boot other than disk or network is refused (3)" {
  run bash "$S/vm-define" n1 --boot floppy --memory 4096 --vcpus 2 --disk "$DISK" --image "$IMG" --net br-prov
  [ "$status" -eq 3 ]
  [[ "$output" == *"--boot 'floppy'"* ]]
  [ ! -e "$STATE/xml.n1" ]
}

@test "--mac before any --net is a usage error (2)" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --mac 52:54:00:aa:bb:cc --net br-prov
  [ "$status" -eq 2 ]
}

@test "two --mac for one --net is a usage error (2)" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc --mac 52:54:00:aa:bb:dd
  [ "$status" -eq 2 ]
}

@test "bad MACs are refused (3): upper case, short, multicast, duplicate" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:AA:BB:CC
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 53:54:00:aa:bb:cc
  [ "$status" -eq 3 ]
  [[ "$output" == *"multicast"* ]]
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --net br-prov --mac 52:54:00:aa:bb:cc --net br-work --mac 52:54:00:aa:bb:cc
  [ "$status" -eq 3 ]
  [[ "$output" == *"twice"* ]]
  [ ! -e "$STATE/xml.n1" ]
}

@test "a --disk that does not exist is still refused with --boot network (3)" {
  run bash "$S/vm-define" n1 --boot network --memory 4096 --vcpus 2 --disk "$HPS_DEV/md/nosuch" --net br-prov
  [ "$status" -eq 3 ]
}
