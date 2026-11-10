#!/usr/bin/env bats
#
# CS-3.3: vm-confinement-report.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-25.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  export HPS_PROC="$TEST_DIR/proc"
  export HPS_SYS="$TEST_DIR/sys"
  export HPS_QEMU_CONF="$TEST_DIR/qemu.conf"
  mkdir -p "$HPS_PROC" "$HPS_SYS/module/apparmor/parameters" "$HPS_SYS/kernel/security/apparmor"
  echo Y > "$HPS_SYS/module/apparmor/parameters/enabled"
  printf '/nix/store/abc-libvirt-12.2.0/sbin/.libvirtd-wrapped (enforce)\nlibvirt-aaaa (enforce)\nlibvirt-bbbb (enforce)\nother (complain)\n' > "$HPS_SYS/kernel/security/apparmor/profiles"
  printf 'user = "qemu-libvirtd"\ngroup = "qemu-libvirtd"\nseccomp_sandbox = 1\nclear_emulator_capabilities = 1\ndynamic_ownership = 1\nallow_disk_format_probing = 0\nsecurity_default_confined = 1\nvnc_listen = "0.0.0.0"\n' > "$HPS_QEMU_CONF"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a confined running guest: every check labelled, last line carries the facts" {
  p3_20_fake_dom vm1 running
  p3_20_proc 4242 vm1 1000 0000000000000000 2 "libvirt-aaaa (enforce)"
  run bash "$S/vm-confinement-report" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK1 libvirt secmodels: apparmor,dac"* ]]
  [[ "$output" == *"CHECK1 dominfo vm1: Security model: apparmor"* ]]
  [[ "$output" == *"CHECK2 vm1: pid=4242 user=qemu-libvirtd CapEff=0000000000000000 CapPrm=0000000000000000 NoNewPrivs=1 Seccomp=2"* ]]
  [[ "$output" == *"CHECK3 vm1: label=libvirt-aaaa (enforce)"* ]]
  [[ "$output" == *"CHECK4 apparmor kernel enabled: Y"* ]]
  [[ "$output" == *"CHECK4 apparmor profiles: total=4 libvirtd=1 guest=2"* ]]
  [[ "$output" == *'CHECK5 qemu.conf: seccomp_sandbox = 1'* ]]
  [[ "$output" == *'CHECK5 qemu.conf: dynamic_ownership = 1'* ]]
  [[ "$output" != *vnc_listen* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=qemu-libvirtd seccomp=2 apparmor_kernel=Y label=libvirt-aaaa" ]
}

@test "the DAC-only finding: dominfo says dac, label unconfined" {
  p3_20_fake_dom vm1 running
  p3_20_proc 4242 vm1 1000 0000000000000000 2 unconfined
  FAKE_SECMODEL=dac FAKE_CAPS=dac run bash "$S/vm-confinement-report" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "CONFINEMENT model=dac qemu_user=qemu-libvirtd seccomp=2 apparmor_kernel=Y label=unconfined" ]
}

@test "no guest running: reports it, exits 0, dashes in the last line, model from capabilities" {
  run bash "$S/vm-confinement-report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK2: no guest running"* ]]
  [[ "$output" == *"CHECK3: no guest running"* ]]
  [[ "$output" == *"CHECK4 apparmor kernel enabled: Y"* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=- seccomp=- apparmor_kernel=Y label=-" ]
}

@test "a named guest that is defined but has no process: no guest running, exit 0" {
  p3_20_fake_dom vm1 "shut off"
  run bash "$S/vm-confinement-report" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK2 vm1: no guest running"* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=- seccomp=- apparmor_kernel=Y label=-" ]
}

@test "a named guest that is not defined at all: still exit 0" {
  run bash "$S/vm-confinement-report" nosuch
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK1 dominfo nosuch: not defined"* ]]
}

@test "no models listed and no apparmor in the kernel: model=none, apparmor_kernel=- when the file is absent" {
  rm "$HPS_SYS/module/apparmor/parameters/enabled"
  rm "$HPS_SYS/kernel/security/apparmor/profiles"
  FAKE_CAPS=" " run bash "$S/vm-confinement-report"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECK4 apparmor kernel enabled: absent"* ]]
  [[ "$output" == *"CHECK4 apparmor profiles: list unreadable"* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=none qemu_user=- seccomp=- apparmor_kernel=- label=-" ]
}

@test "apparmor kernel N is reported as N" {
  echo N > "$HPS_SYS/module/apparmor/parameters/enabled"
  run bash "$S/vm-confinement-report"
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=- seccomp=- apparmor_kernel=N label=-" ]
}

@test "an unprivileged-looking process with seccomp 0 and capabilities set is reported as it is" {
  p3_20_fake_dom vm1 running
  p3_20_proc 77 vm1 0 000001ffffffffff 0 unconfined
  run bash "$S/vm-confinement-report" vm1
  [[ "$output" == *"user=0 "* ]]
  [[ "$output" == *"CapEff=000001ffffffffff"* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=0 seccomp=0 apparmor_kernel=Y label=unconfined" ]
}

@test "with no argument every running guest is examined and the first one fills the last line" {
  p3_20_fake_dom vm1 running
  p3_20_fake_dom vm2 running
  p3_20_proc 10 vm1 1000 0000000000000000 2 "libvirt-aaaa (enforce)"
  p3_20_proc 11 vm2 1000 0000000000000000 2 "libvirt-bbbb (enforce)"
  run bash "$S/vm-confinement-report"
  [[ "$output" == *"CHECK2 vm1: pid=10"* ]]
  [[ "$output" == *"CHECK2 vm2: pid=11"* ]]
  [ "${lines[-1]}" = "CONFINEMENT model=apparmor qemu_user=qemu-libvirtd seccomp=2 apparmor_kernel=Y label=libvirt-aaaa" ]
}

@test "a guest whose name is a prefix of another matches only itself" {
  p3_20_fake_dom vm1 running
  p3_20_proc 10 vm10 1000 0000000000000000 2 "libvirt-x (enforce)"
  run bash "$S/vm-confinement-report" vm1
  [[ "$output" == *"CHECK2 vm1: no guest running"* ]]
}

@test "read-only: only capabilities, list, dominfo are called on virsh; the last line is CONFINEMENT in every case" {
  p3_20_fake_dom vm1 running
  p3_20_proc 4242 vm1 1000 0000000000000000 2 unconfined
  run bash "$S/vm-confinement-report"
  run ! grep -E '^virsh (start|shutdown|destroy|define|undefine)' "$SHIM_LOG"
  [ "$(p3_20_virsh_cmds | sort -u | paste -sd' ' -)" = "capabilities dominfo list" ]
}

@test "usage errors exit 2" {
  run bash "$S/vm-confinement-report" a b
  [ "$status" -eq 2 ]
  run bash "$S/vm-confinement-report" -x
  [ "$status" -eq 2 ]
}
