#!/usr/bin/env bats
#
# vm-define with several --disk: targets per bus (vda.. / sda..), boot order,
# the 1..8 limit, a repeated path, a single disk unchanged. virsh is the
# p3_20_helpers shim (it keeps the XML define received in $STATE/xml.<vm>).

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-170.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  D1="$HPS_DEV/md/s1-d1"
  D2="$HPS_DEV/md/s1-d2"
  D3="$HPS_DEV/md/s1-d3"
  head -c 4096 /dev/zero > "$D1"
  head -c 4096 /dev/zero > "$D2"
  head -c 4096 /dev/zero > "$D3"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# three_net [extra args]: a network-boot VM with three disks.
three_net() {
  bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 --disk "$D1" --disk "$D2" --disk "$D3" --net br-work "$@"
}

# targets <vm>: the disk targets and sources in XML order, one per line.
targets() {
  sed -n -E "s/.*<target dev='([a-z]+)' bus='([a-z]+)'\/>.*/\1 \2/p; s/.*<source dev='([^']+)'\/>.*/\1/p" "$STATE/xml.$1"
}

@test "three disks, virtio: vda vdb vdc in the order given, network first then the disk" {
  run three_net
  [ "$status" -eq 0 ]
  x="$STATE/xml.s1"
  [ "$(grep -c "<disk type='block'" "$x")" -eq 3 ]
  [ "$(targets s1 | paste -sd' ' -)" = "$D1 vda virtio $D2 vdb virtio $D3 vdc virtio" ]
  [ "$(grep -n "<boot dev" "$x" | sed -E 's/^[0-9]+:\s*//' | paste -sd' ' -)" = "<boot dev='network'/> <boot dev='hd'/>" ]
  [ "$(grep -c "<boot dev='hd'/>" "$x")" -eq 1 ]
}

@test "three disks, sata: sda sdb sdc, no SCSI controller" {
  run three_net --disk-bus sata
  [ "$status" -eq 0 ]
  [ "$(targets s1 | paste -sd' ' -)" = "$D1 sda sata $D2 sdb sata $D3 sdc sata" ]
  run ! grep -q "<controller type='scsi'" "$STATE/xml.s1"
}

@test "three disks, scsi: sda sdb sdc on the one virtio-scsi controller" {
  run three_net --disk-bus scsi
  [ "$status" -eq 0 ]
  [ "$(targets s1 | paste -sd' ' -)" = "$D1 sda scsi $D2 sdb scsi $D3 sdc scsi" ]
  [ "$(grep -c "<controller type='scsi'" "$STATE/xml.s1")" -eq 1 ]
}

@test "disk boot with three disks: only disk 1 is a boot device, --image recorded once" {
  run bash "$S/vm-define" s1 --memory 2048 --vcpus 2 --disk "$D1" --disk "$D2" --disk "$D3" --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  x="$STATE/xml.s1"
  [ "$(grep -c "<boot dev" "$x")" -eq 1 ]
  [ "$(grep -c "<hps:image>" "$x")" -eq 1 ]
  [ "$(grep -c "<disk type='block'" "$x")" -eq 3 ]
}

@test "the same three disks again: nothing to do; another disk order is a different definition" {
  run three_net
  [ "$status" -eq 0 ]
  run three_net
  [ "$status" -eq 0 ]
  [ "$(p3_20_virsh_cmds | grep -c '^define$')" -eq 1 ]
  run bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 --disk "$D2" --disk "$D1" --disk "$D3" --net br-work
  [ "$status" -eq 3 ]
  [[ "$output" == *"defined differently"* ]]
}

@test "eight disks are accepted, vda to vdh" {
  args=()
  for n in 1 2 3 4 5 6 7 8; do
    head -c 4096 /dev/zero > "$HPS_DEV/md/e$n"
    args+=(--disk "$HPS_DEV/md/e$n")
  done
  run bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 "${args[@]}" --net br-work
  [ "$status" -eq 0 ]
  [ "$(targets s1 | grep -c ' virtio$')" -eq 8 ]
  [ "$(targets s1 | grep ' virtio$' | cut -d' ' -f1 | paste -sd' ' -)" = "vda vdb vdc vdd vde vdf vdg vdh" ]
}

@test "nine disks are refused (3), nothing defined" {
  args=()
  for n in 1 2 3 4 5 6 7 8 9; do
    head -c 4096 /dev/zero > "$HPS_DEV/md/e$n"
    args+=(--disk "$HPS_DEV/md/e$n")
  done
  run bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 "${args[@]}" --net br-work
  [ "$status" -eq 3 ]
  [[ "$output" == *"at most 8"* ]]
  [ ! -e "$STATE/xml.s1" ]
}

@test "a repeated --disk path is refused (3), nothing defined" {
  run bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 --disk "$D1" --disk "$D2" --disk "$D1" --net br-work
  [ "$status" -eq 3 ]
  [[ "$output" == *"is given twice"* ]]
  [ ! -e "$STATE/xml.s1" ]
}

@test "every --disk must exist: a missing second disk is refused (3)" {
  run bash "$S/vm-define" s1 --boot network --memory 2048 --vcpus 2 --disk "$D1" --disk "$HPS_DEV/md/nope" --net br-work
  [ "$status" -eq 3 ]
  [[ "$output" == *"does not exist"* ]]
  [ ! -e "$STATE/xml.s1" ]
}

@test "a single disk is exactly the old definition: one disk element, vda, no controller (byte-identical to the old script)" {
  run p3_20_define
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  [ "$(grep -c "<disk type='block'" "$x")" -eq 1 ]
  [ "$(targets vm1 | paste -sd' ' -)" = "$DISK vda virtio" ]
  run ! grep -q "<controller" "$x"
}

@test "single disk on scsi and sata keep sda and their controller layout" {
  run p3_20_define --disk-bus scsi
  [ "$status" -eq 0 ]
  [ "$(targets vm1 | paste -sd' ' -)" = "$DISK sda scsi" ]
  [ "$(grep -c "<controller type='scsi'" "$STATE/xml.vm1")" -eq 1 ]
  run p3_20_define --replace --disk-bus sata
  [ "$status" -eq 0 ]
  [ "$(targets vm1 | paste -sd' ' -)" = "$DISK sda sata" ]
}
