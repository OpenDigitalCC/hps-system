#!/usr/bin/env bats
#
# check_vms and the paused guest (docs/STORAGE-FAULTS.md "A paused guest",
# docs/MONITORING.md). Proves: one virsh call that asks for paused guests and
# their state; a guest paused by an I/O error is named with its reason, counted
# in paused=<n>, and makes the check WARNING (exit 1); a guest paused for another
# reason is reported and the check stays OK; paused guests leave the running
# figures and the saved sample; the paused figure is always printed (0 included),
# so a node without it is told apart from a node with none paused; the figures of
# running guests are unchanged.

bats_require_minimum_version 1.5.0
P="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/plugins"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-280c.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/root"
  cat > "$TEST_DIR/bin/virsh" <<EOT
#!/bin/sh
echo "\$*" >> "$TEST_DIR/virsh.calls"
[ "\$*" = "-c qemu:///system domstats --raw --list-running --list-paused --nowait --state --cpu-total --balloon --vcpu --block --interface" ] || { echo "bad args: \$*" >&2; exit 2; }
cat "$TEST_DIR/root/virsh.out"
EOT
  chmod +x "$TEST_DIR/bin/virsh"
  export HPS_VIRSH="$TEST_DIR/bin/virsh"
  export HPS_VMS_STATE="$TEST_DIR/run/hps/check_vms.prev"
  export HPS_NOW=1000
}

teardown() {
  rm -rf "$TEST_DIR"
}

# dom NAME STATE REASON: a domstats block; REASON "-" leaves state.reason out.
dom() {
  printf "Domain: '%s'\n  state.state=%s\n" "$1" "$2"
  [ "$3" = "-" ] || printf '  state.reason=%s\n' "$3"
  cat <<EOT
  cpu.time=10000000000
  balloon.current=2097152
  balloon.rss=1048576
  vcpu.current=2
  block.count=1
  block.0.rd.bytes=1000
  block.0.wr.bytes=2000
  net.count=1
  net.0.rx.bytes=10
  net.0.tx.bytes=20

EOT
}

@test "check_vms: one virsh call asks for the running and the paused guests and their state" {
  { dom web 1 1; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TEST_DIR/virsh.calls")" -eq 1 ]
  grep -q -- '--list-running --list-paused' "$TEST_DIR/virsh.calls"
  grep -q -- '--state' "$TEST_DIR/virsh.calls"
}

@test "check_vms: a guest paused by an I/O error is WARNING (exit 1), named with its reason, counted, and out of the running figures" {
  { dom web 1 1; dom db 3 5; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 1 ]
  [ "$output" = "VMS WARNING - 1 running VMs (rss 1.0 GiB, rates: no previous sample), 1 paused: db (ioerror) | vms=1 paused=1 db_paused_ioerror=1 web_vcpus=2 web_rss=1073741824B web_mem=2147483648B" ]
}

@test "check_vms: the paused guest is not in the saved sample, so the next run rates only the running guests" {
  { dom web 1 1; dom db 3 5; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$(cat "$HPS_VMS_STATE")" = $'ts=1000\nweb 10000000000 2 1048576 2097152 1000 2000 10 20' ]
}

@test "check_vms: only paused guests: no running VMs, still WARNING for an I/O error" {
  dom db 3 5 > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 1 ]
  [ "$output" = "VMS WARNING - no running VMs, 1 paused: db (ioerror) | vms=0 paused=1 db_paused_ioerror=1" ]
  [ "$(cat "$HPS_VMS_STATE")" = "ts=1000" ]
}

@test "check_vms: a guest an operator paused is reported with its reason and the check stays OK" {
  { dom web 1 1; dom db 3 1; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [[ "$output" == "VMS OK - 1 running VMs (rss 1.0 GiB, rates: no previous sample), 1 paused: db (user) | vms=1 paused=1 db_paused_user=1 web_vcpus=2"* ]]
}

@test "check_vms: several paused guests are each named; one I/O error among them makes it WARNING" {
  { dom a 3 1; dom b 3 5; dom c 3 5; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 1 ]
  [ "$output" = "VMS WARNING - no running VMs, 3 paused: a (user), b (ioerror), c (ioerror) | vms=0 paused=3 a_paused_user=1 b_paused_ioerror=1 c_paused_ioerror=1" ]
}

@test "check_vms: the reason codes of libvirt are named; an unknown code is code<N>, a missing one unknown" {
  { dom a 3 2; dom b 3 6; dom c 3 10; dom d 3 99; dom e 3 -; dom f 3 0; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a (migrating), b (watchdog), c (crashed), d (code99), e (unknown), f (unknown)"* ]]
  [[ "$output" == *"a_paused_migrating=1 b_paused_watchdog=1 c_paused_crashed=1 d_paused_code99=1 e_paused_unknown=1 f_paused_unknown=1"* ]]
}

@test "check_vms: paused=0 is printed when nothing is paused, so an older node (no figure) is told apart from none paused" {
  dom web 1 1 > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [[ "$output" == *"| vms=1 paused=0 web_vcpus=2"* ]]
  [[ "$output" != *paused:* ]]
}

@test "check_vms: a guest the sample gives no state for is a running one, as before" {
  printf "Domain: 'old'\n  cpu.time=1\n  balloon.current=1024\n  balloon.rss=1024\n  vcpu.current=1\n\n" > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [[ "$output" == "VMS OK - 1 running VMs"* ]]
  [[ "$output" == *"vms=1 paused=0 old_vcpus=1"* ]]
}

@test "check_vms: the running guests' figures and rates are the same with a paused guest beside them" {
  { dom web 1 1; } > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  { dom web 1 1; dom db 3 5; } > "$TEST_DIR/root/virsh.out"
  HPS_NOW=1010 run "$P/check_vms"
  [ "$status" -eq 1 ]
  [[ "$output" == "VMS WARNING - 1 running VMs (rss 1.0 GiB), 1 paused: db (ioerror) | vms=1 paused=1 db_paused_ioerror=1 web_cpu_pct=0.0% web_vcpus=2 web_rss=1073741824B web_mem=2147483648B web_rd_Bps=0 web_wr_Bps=0 web_rx_Bps=0 web_tx_Bps=0" ]]
}

@test "check_vms: the perf labels of a paused guest keep to [a-z0-9_.-], a guest name with a dot is sanitised" {
  dom Db.2 3 5 > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [[ "$output" == *"| vms=0 paused=1 db_2_paused_ioerror=1" ]]
}
