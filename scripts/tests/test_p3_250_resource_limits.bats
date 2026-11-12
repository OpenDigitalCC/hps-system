#!/usr/bin/env bats
#
# Resource isolation, guest side: vm-define's cputune / memtune / blkiotune /
# iotune, and vm-start's guest memory budget (machine.slice memory.max).

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_20_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-250.XXXXXX")"
  export TEST_DIR
  p3_20_setup
}

teardown() {
  rm -rf "$TEST_DIR"
}

# budget <MiB>: machine.slice memory.max in the fake cgroup tree.
budget() {
  mkdir -p "$HPS_CGROUP_ROOT/machine.slice"
  echo "$(($1 * 1048576))" > "$HPS_CGROUP_ROOT/machine.slice/memory.max"
}

#--- vm-define

@test "defaults: memtune hard_limit memory + 256 + memory/16, cputune shares 100 per vCPU, nothing else" {
  run p3_20_define
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -q "<memtune>" "$x"
  grep -q "<hard_limit unit='MiB'>2432</hard_limit>" "$x"
  grep -q "<cputune>" "$x"
  grep -q "<shares>200</shares>" "$x"
  run ! grep -qE "<period>|<quota>|<blkiotune>|<iotune>" "$x"
}

@test "the default CPU weight stops at 10000 (cgroup v2 cpu.weight's top)" {
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 128 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  grep -q "<shares>10000</shares>" "$STATE/xml.vm1"
}

@test "--cpu-weight, --cpu-max-pct, --mem-hard-limit, --io-weight are written as asked" {
  run p3_20_define --cpu-weight 50 --cpu-max-pct 50 --mem-hard-limit 3000 --io-weight 200
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  grep -q "<shares>50</shares>" "$x"
  grep -q "<period>100000</period>" "$x"
  grep -q "<quota>50000</quota>" "$x"
  grep -q "<hard_limit unit='MiB'>3000</hard_limit>" "$x"
  grep -q "<blkiotune>" "$x"
  grep -q "<weight>200</weight>" "$x"
  # domain level, before <os>
  [ "$(grep -n '<cputune>' "$x" | cut -d: -f1)" -lt "$(grep -n '<os>' "$x" | cut -d: -f1)" ]
}

@test "--disk-iops / --disk-mbps belong to the --disk before them: iotune on that disk only, MiB/s in bytes" {
  D2="$HPS_DEV/md/vm1-disk1"
  head -c 4096 /dev/zero > "$D2"
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --disk "$D2" --disk-iops 500 --disk-mbps 100 \
    --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  x="$STATE/xml.vm1"
  [ "$(grep -c '<iotune>' "$x")" -eq 1 ]
  awk '/<target dev=.vdb./,/<\/disk>/' "$x" | grep -q "<total_iops_sec>500</total_iops_sec>"
  awk '/<target dev=.vdb./,/<\/disk>/' "$x" | grep -q "<total_bytes_sec>104857600</total_bytes_sec>"
  run ! bash -c "awk '/<target dev=.vda./,/<\/disk>/' '$x' | grep -q iotune"
}

@test "a disk option before any --disk, or twice for one disk, is usage (2)" {
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk-iops 5 --disk "$DISK" --net br-work --image "$IMG"
  [ "$status" -eq 2 ]
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --disk-mbps 5 --disk-mbps 6 --net br-work --image "$IMG"
  [ "$status" -eq 2 ]
}

@test "out-of-range limits are refused (3) and nothing is defined" {
  local bad
  for bad in "--cpu-weight 0" "--cpu-weight 10001" "--cpu-max-pct 0" "--cpu-max-pct 101" "--io-weight 5" \
    "--io-weight 1001" "--mem-hard-limit 2100" "--mem-hard-limit x" "--disk-iops 0" "--disk-mbps -1"; do
    # shellcheck disable=SC2086  # the option and its value
    run p3_20_define $bad
    [ "$status" -eq 3 ] || { echo "$bad: $status"; false; }
  done
  [ ! -e "$STATE/xml.vm1" ]
}

@test "the limits are part of the spec: another cap is a different definition (3), the same again a no-op" {
  run p3_20_define --cpu-max-pct 50
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run p3_20_define --cpu-max-pct 50
  [ "$status" -eq 0 ]
  run ! grep -q '^virsh define' "$SHIM_LOG"
  run p3_20_define --cpu-max-pct 40
  [ "$status" -eq 3 ]
}

#--- vm-start: the guest memory budget

@test "vm-start: no budget (no memory.max) starts as before, and says so" {
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"no guest memory budget"* ]]
  [ "$(p3_20_virsh_cmds | paste -sd' ' -)" = "domstate start domstate dumpxml" ]
}

@test "vm-start: memory.max 'max' is no budget" {
  mkdir -p "$HPS_CGROUP_ROOT/machine.slice"
  echo max > "$HPS_CGROUP_ROOT/machine.slice/memory.max"
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory.max is 'max'"* ]]
}

@test "vm-start: within the budget it starts and logs the sum" {
  budget 8192
  p3_20_fake_dom vm1 "shut off"
  echo '<domain/>' > "$STATE/xml.vm1"
  echo 2048 > "$STATE/mem.vm1"
  p3_20_fake_dom vm2 running
  echo 4096 > "$STATE/mem.vm2"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "VM vm1 running" ]
  [[ "$output" == *"guest memory: 6144 of 8192 MiB with vm1"* ]]
}

@test "vm-start: over the budget it is refused (3), names the running guests, and does not start" {
  budget 4096
  p3_20_fake_dom vm1 "shut off"
  echo 2048 > "$STATE/mem.vm1"
  p3_20_fake_dom vm2 running
  echo 3072 > "$STATE/mem.vm2"
  p3_20_fake_dom vm3 "shut off"
  echo 8192 > "$STATE/mem.vm3"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 3 ]
  [[ "$output" == *"would put the running guests at 5120 MiB, over the guest memory budget of 4096 MiB"* ]]
  [[ "$output" == *"running: vm2"* ]]
  run ! grep -q '^virsh start' "$SHIM_LOG"
}

@test "vm-start: an already running guest is not checked again" {
  budget 1024
  p3_20_fake_dom vm1 running
  echo 2048 > "$STATE/mem.vm1"
  echo '<domain/>' > "$STATE/xml.vm1"
  run bash "$S/vm-start" vm1
  [ "$status" -eq 0 ]
  run ! grep -q '^virsh dominfo' "$SHIM_LOG"
}
