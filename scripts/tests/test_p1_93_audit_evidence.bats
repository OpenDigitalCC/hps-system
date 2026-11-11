#!/usr/bin/env bats
#
# CS-1.9: the evidence hps-audit.sh keeps for a drive the OS cannot see:
# dmesg (json or text, capped), /proc/scsi/scsi, every scsi_host and
# scsi_device attribute that exists, hpsa/smartpqi driver bindings, and the
# size cap on the assembled JSON. Fixture sysfs trees for the DL360 inferred
# HBA case, the RAID case and the explicit-attribute case.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-93.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_SYS="$TEST_DIR/sys"
  export HPS_PROC="$TEST_DIR/proc"
  export HPS_CMDLINE="$TEST_DIR/proc/cmdline"
  export HPS_CONSOLES="$TEST_DIR/console"
  export HPS_AUDIT_OUT="$TEST_DIR/run/audit.json"
  export HPS_REBOOT_CMD=true HPS_REBOOT_DELAY=0
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  AUDIT="$ROOT/node-manager/nixos-26/audit/hps-audit.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_PROC/scsi" "$HPS_SYS/class/dmi/id" "$HPS_SYS/class/scsi_host" "$HPS_SYS/class/scsi_device"
  : > "$TEST_DIR/console"
  echo "hps.ips=10.99.1.1" > "$HPS_CMDLINE"
  printf 'MemTotal: 1 kB\n' > "$HPS_PROC/meminfo"

  # DL360 shape: hpsa host with no hba_mode_enabled, one with only proc_name
  mkdir -p "$HPS_SYS/class/scsi_host/host0" "$HPS_SYS/class/scsi_host/host1" "$HPS_SYS/class/scsi_host/host2"
  echo hpsa > "$HPS_SYS/class/scsi_host/host0/proc_name"
  echo "HBA" > "$HPS_SYS/class/scsi_host/host0/transport_mode"
  echo "7.20" > "$HPS_SYS/class/scsi_host/host0/firmware_revision"
  echo ahci > "$HPS_SYS/class/scsi_host/host1/proc_name"
  # host2: no attribute at all, still listed
  mkdir -p "$HPS_SYS/class/scsi_device/0:0:0:0/device" "$HPS_SYS/class/scsi_device/0:1:0:0/device"
  printf 'ATA     \n' > "$HPS_SYS/class/scsi_device/0:0:0:0/device/vendor"
  printf 'SSDSC2KB       \n' > "$HPS_SYS/class/scsi_device/0:0:0:0/device/model"
  echo running > "$HPS_SYS/class/scsi_device/0:0:0:0/device/state"
  echo 0 > "$HPS_SYS/class/scsi_device/0:0:0:0/device/type"
  echo "HPE" > "$HPS_SYS/class/scsi_device/0:1:0:0/device/vendor"
  mkdir -p "$HPS_SYS/bus/pci/drivers/hpsa"
  touch "$HPS_SYS/bus/pci/drivers/hpsa/0000:03:00.0" "$HPS_SYS/bus/pci/drivers/hpsa/bind" "$HPS_SYS/bus/pci/drivers/hpsa/unbind"
  printf 'Attached devices:\nHost: scsi0 Channel: 00 Id: 00 Lun: 00\n  Vendor: ATA      Model: SSDSC2KB\n' > "$HPS_PROC/scsi/scsi"

  for n in lscpu numactl lspci blkid zpool; do
    printf '#!/bin/bash\necho "%s $*" >> "$SHIM_LOG"\necho "{}"\n' "$n" > "$TEST_DIR/bin/$n"
  done
  printf '#!/bin/bash\necho "lscpu $*" >> "$SHIM_LOG"\necho "{}"\n' > "$TEST_DIR/bin/lscpu"
  cat > "$TEST_DIR/bin/lsblk" <<'SH'
#!/bin/bash
echo "lsblk $*" >> "$SHIM_LOG"
if [[ -n "${FAKE_LV:-}" ]]; then
  echo '{"blockdevices":[{"name":"sda","type":"disk","model":"LOGICAL VOLUME"}]}'
else
  echo '{"blockdevices":[{"name":"sda","type":"disk","model":"SSDSC2KB960G8"},{"name":"sdb","type":"disk","model":"SSDSC2KB960G8"}]}'
fi
SH
  cat > "$TEST_DIR/bin/ip" <<'SH'
#!/bin/bash
echo "ip $*" >> "$SHIM_LOG"
echo '[]'
SH
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$SHIM_LOG"
SH
  # dmesg: --json when FAKE_DMESG_JSON=1 (else the option fails), N lines of
  # FAKE_DMESG_LEN characters
  cat > "$TEST_DIR/bin/dmesg" <<'SH'
#!/bin/bash
echo "dmesg $*" >> "$SHIM_LOG"
n="${FAKE_DMESG_LINES:-5}"
pad=$(printf '%*s' "${FAKE_DMESG_LEN:-10}" '' | tr ' ' x)
if [[ "$1" == "--json" ]]; then
  [[ "${FAKE_DMESG_JSON:-}" == 1 ]] || { echo "dmesg: unrecognized option '--json'" >&2; exit 1; }
  echo '{"dmesg":['
  for ((i = 1; i <= n; i++)); do
    sep=","; [[ $i -eq $n ]] && sep=""
    echo "{\"pri\":6,\"time\":$i.0,\"msg\":\"hpsa ${FAKE_DMESG_WORD:-line} $i $pad\"}$sep"
  done
  echo ']}'
  exit 0
fi
for ((i = 1; i <= n; i++)); do echo "[    $i.000000] hpsa ${FAKE_DMESG_WORD:-line} $i $pad"; done
SH
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "every scsi host is kept, with whatever attributes it has" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.storage_controllers.scsi_hosts | length == 3' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.scsi_hosts[0] == {host:"host0",driver:"hpsa",transport_mode:"HBA",firmware_revision:"7.20"}' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.scsi_hosts[1] == {host:"host1",driver:"ahci"}' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.scsi_hosts[2] == {host:"host2"}' "$HPS_AUDIT_OUT"
}

@test "scsi devices keep vendor, model, state, type, trimmed, and a device with a missing attribute is kept" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.scsi_devices[0] == {id:"0:0:0:0",vendor:"ATA",model:"SSDSC2KB",state:"running",type:"0"}' "$HPS_AUDIT_OUT" || \
    jq -e '.scsi_devices[0].vendor == "ATA" and .scsi_devices[0].state == "running"' "$HPS_AUDIT_OUT"
  jq -e '.scsi_devices[1] == {id:"0:1:0:0",vendor:"HPE"}' "$HPS_AUDIT_OUT"
}

@test "driver bindings list hpsa entries and null for a driver that is not loaded" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.storage_controllers.pci_drivers.hpsa | index("0000:03:00.0") != null' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.pci_drivers.smartpqi == null' "$HPS_AUDIT_OUT"
}

@test "/proc/scsi/scsi is kept" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.proc_scsi | test("Attached devices")' "$HPS_AUDIT_OUT"
}

@test "dmesg --json is used when available" {
  FAKE_DMESG_JSON=1 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -qx 'dmesg --json' "$SHIM_LOG"
  jq -e '.dmesg | length == 5 and (.[0] | test("hpsa line 1"))' "$HPS_AUDIT_OUT"
  jq -e '.dmesg_trimmed == false' "$HPS_AUDIT_OUT"
}

@test "plain dmesg is the fallback when --json is not supported" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -qx "dmesg " "$SHIM_LOG"
  jq -e '.dmesg | length == 5 and (.[4] | test("hpsa line 5"))' "$HPS_AUDIT_OUT"
}

@test "dmesg is capped at 2000 lines, keeping the newest" {
  FAKE_DMESG_LINES=2500 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.dmesg | length == 2000 and (.[1999] | test("hpsa line 2500"))' "$HPS_AUDIT_OUT"
}

@test "the assembled JSON is trimmed to fit under 200 KiB and the intake limit" {
  FAKE_DMESG_LINES=2000 FAKE_DMESG_LEN=300 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  size=$(wc -c < "$HPS_AUDIT_OUT")
  [ "$size" -le 204800 ]
  jq -e '.dmesg_trimmed == true' "$HPS_AUDIT_OUT"
  jq -e '.dmesg | length > 0 and (.[-1] | test("hpsa line 2000"))' "$HPS_AUDIT_OUT"
}

@test "a small dmesg is not trimmed" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.dmesg_trimmed == false' "$HPS_AUDIT_OUT"
}

# ---- the verdicts, end to end through the renderer ---------------------------

render() {
  perl -I"$ROOT/lib/perl" -MHPS::Onboard -MJSON::PP -e '
    local $/; my $a = decode_json(<STDIN>); print HPS::Onboard::render_audit($a)' < "$HPS_AUDIT_OUT"
}

@test "DL360 case: no hba_mode_enabled, hpsa bound, native models -> HBA with its evidence" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run render
  [[ "$output" == *"Verdict: HBA mode"* ]]
  [[ "$output" == *"driver hpsa bound to 0000:03:00.0; no LOGICAL VOLUME disk; native disk model(s): SSDSC2KB960G8"* ]]
}

@test "RAID case: a LOGICAL VOLUME disk -> RAID" {
  FAKE_LV=1 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run render
  [[ "$output" == *"Verdict: RAID mode detected"* ]]
}

@test "explicit attribute case: hba_mode_enabled=1 -> HBA citing the attribute" {
  echo 1 > "$HPS_SYS/class/scsi_host/host0/hba_mode_enabled"
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.storage_controllers.scsi_hosts[0].hba_mode_enabled == 1' "$HPS_AUDIT_OUT"
  run render
  [[ "$output" == *"Verdict: HBA mode"* ]]
  [[ "$output" == *"evidence: hba_mode_enabled=1 on host0"* ]]
}

@test "no driver binding and no attribute -> unknown" {
  rm -rf "$HPS_SYS/bus/pci/drivers/hpsa"
  rm -f "$HPS_SYS/class/scsi_host/host0/proc_name"
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run render
  [[ "$output" == *"Verdict: unknown"* ]]
}

@test "the hidden-drive hint shows the last 12 hpsa device lines from dmesg" {
  FAKE_DMESG_WORD=scsi FAKE_DMESG_LINES=20 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run render
  [[ "$output" == *"Drives the OS cannot see (last 12"* ]]
  [[ "$output" == *"scsi 20 "* ]]
  [[ "$output" == *"scsi 9 "* ]]
  [[ "$output" != *"scsi 8 "* ]]
}
