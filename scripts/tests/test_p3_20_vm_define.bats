#!/usr/bin/env bats
#
# CS-3.3: vm-define.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-20.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "defines a guest: dominfo probe, then define, last line VM vm1 defined" {
  run p3_20_define
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 defined" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "dominfo define" ]
  [ -s "$STATE/xml.vm1" ]
}

@test "the same --disk twice is refused (3), nothing defined" {
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is given twice"* ]]
  [ ! -e "$STATE/xml.vm1" ]
}

@test "the XML: q35, OVMF loader and nvram, raw virtio disk on the given device, one NIC per bridge" {
  run p3_20_define
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -q "machine='q35'" "$x"
  grep -q "<loader readonly='yes' type='pflash'.*>/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>" "$x"
  grep -q "<nvram template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'.*>/var/lib/libvirt/qemu/nvram/vm1_VARS.fd</nvram>" "$x"
  grep -q "<disk type='block' device='disk'>" "$x"
  grep -q "<driver name='qemu' type='raw'" "$x"
  grep -qF "<source dev='$DISK'/>" "$x"
  grep -q "<target dev='vda' bus='virtio'/>" "$x"
  grep -q "<source bridge='br-work'/>" "$x"
  grep -q "<source bridge='br-store'/>" "$x"
  [ "$(grep -c "<interface type='bridge'>" "$x")" -eq 2 ]
  [ "$(grep -c "<model type='virtio'/>" "$x")" -eq 2 ]
  grep -q "<memory unit='MiB'>2048</memory>" "$x"
  grep -q "<vcpu placement='static'>2</vcpu>" "$x"
  grep -qF "<hps:image>$IMG</hps:image>" "$x"
}

@test "the XML: serial console to the default log, no graphics, no spice, no video device" {
  run p3_20_define
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -qF "<source path='$HPS_LIBVIRT_LOGDIR/vm1-serial.log'/>" "$x"
  grep -q "<serial type='file'>" "$x"
  grep -q "<console type='file'>" "$x"
  run ! grep -qiE 'graphics|spice|vnc' "$x"
  grep -q "<model type='none'/>" "$x"
}

@test "--serial-log overrides the log path" {
  run p3_20_define --serial-log /var/log/libvirt/qemu/other.log
  [ "$status" -eq 0 ]
  grep -qF "<source path='/var/log/libvirt/qemu/other.log'/>" "$STATE/xml.vm1"
}

@test "HPS_OVMF_CODE and HPS_OVMF_VARS override the firmware paths" {
  HPS_OVMF_CODE=/x/code.fd HPS_OVMF_VARS=/x/vars.fd run p3_20_define
  [ "$status" -eq 0 ]
  grep -q '>/x/code.fd</loader>' "$STATE/xml.vm1"
  grep -q "template='/x/vars.fd'" "$STATE/xml.vm1"
}

@test "idempotent: the same definition again makes no define call and exits 0" {
  run p3_20_define
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run p3_20_define
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 defined" ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "dominfo dumpxml" ]
  [ "$(ls "$STATE"/define-count.vm1.* | wc -l)" -eq 1 ]
}

@test "a different definition of a defined name is refused with 3 and nothing is defined" {
  run p3_20_define
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/vm-define" vm1 --memory 4096 --vcpus 2 --disk "$DISK" --net br-work --net br-store --image "$IMG"
  [ "$status" -eq 3 ]
  [[ "$output" == *"use --replace"* ]]
  run ! grep -q '^virsh define' "$SHIM_LOG"
  grep -q "<memory unit='MiB'>2048</memory>" "$STATE/xml.vm1"
}

@test "--replace redefines a shut-off guest keeping its uuid" {
  run p3_20_define
  : > "$SHIM_LOG"
  run bash "$S/vm-define" vm1 --memory 4096 --vcpus 2 --disk "$DISK" --net br-work --net br-store --image "$IMG" --replace
  [ "$status" -eq 0 ]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "dominfo dumpxml domstate domuuid define" ]
  grep -q "<memory unit='MiB'>4096</memory>" "$STATE/xml.vm1"
  grep -q '<uuid>11111111-2222-3333-4444-555555555555</uuid>' "$STATE/xml.vm1"
}

@test "--replace on a running guest is refused with 3" {
  run p3_20_define
  p3_20_fake_dom vm1 running
  run bash "$S/vm-define" vm1 --memory 4096 --vcpus 2 --disk "$DISK" --net br-work --net br-store --image "$IMG" --replace
  [ "$status" -eq 3 ]
  [[ "$output" == *"needs it shut off"* ]]
}

@test "usage errors exit 2" {
  run bash "$S/vm-define"
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" vm1
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --image "$IMG"
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" vm1 --bogus
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" --memory 1
  [ "$status" -eq 2 ]
}

@test "refusals exit 3 and call virsh not at all" {
  run bash "$S/vm-define" Vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" -x --memory 2048
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" vm1 --memory abc --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 8 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 0 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk /etc/passwd --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$HPS_DEV/md/missing" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net "br work" --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image relative.qcow2
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG" --serial-log "x/../y"
  [ "$status" -eq 3 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "vm names: 32 characters pass, 33 and a leading hyphen are refused" {
  run bash "$S/vm-define" a2345678901234567890123456789012 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  run bash "$S/vm-define" a23456789012345678901234567890123 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
  run bash "$S/vm-define" 0-x --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  run bash "$S/vm-define" a_b --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 3 ]
}

@test "a failing virsh define fails the script (1)" {
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
echo "virsh $*" >> "$SHIM_LOG"
[[ "$3" == define ]] && exit 1
exit 1
SHIM
  run p3_20_define
  [ "$status" -eq 1 ]
}

@test "the disk is never opened or written: the file keeps its zeros" {
  run p3_20_define
  [ "$status" -eq 0 ]
  [ "$(tr -d '\0' < "$DISK" | wc -c)" -eq 0 ]
}
