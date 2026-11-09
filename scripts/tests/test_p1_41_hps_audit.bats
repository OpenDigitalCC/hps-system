#!/usr/bin/env bats
#
# node-manager/nixos-26/audit/hps-audit.sh with every hardware command shimmed
# (lscpu, lspci, lsblk, zpool, ip, numactl, blkid, curl) and fake /sys, /proc
# trees. Proves: valid JSON with the expected keys, one POST to the right
# URL, and that nothing in the command log writes to a disk.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-41.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_SYS="$TEST_DIR/sys"
  export HPS_PROC="$TEST_DIR/proc"
  export HPS_CMDLINE="$TEST_DIR/proc/cmdline"
  export HPS_CONSOLES="$TEST_DIR/console"
  export HPS_AUDIT_OUT="$TEST_DIR/run/audit.json"
  AUDIT="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/audit/hps-audit.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin" "$HPS_PROC" "$HPS_SYS/class/dmi/id" "$HPS_SYS/class/scsi_host/host0" "$HPS_SYS/class/scsi_host/host1"
  : > "$TEST_DIR/console"

  echo "BOOT_IMAGE=bzImage initrd=initrd console=ttyS0,115200n8 hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=audit" > "$HPS_CMDLINE"
  printf 'MemTotal:       16318860 kB\nMemFree:         1234 kB\nMemAvailable:    5678 kB\nSwapTotal:       0 kB\nHugePages_Total:       0\nHugepagesize:       2048 kB\n' > "$HPS_PROC/meminfo"
  echo "HPE" > "$HPS_SYS/class/dmi/id/sys_vendor"
  echo "ProLiant DL360 Gen9" > "$HPS_SYS/class/dmi/id/product_name"
  echo "SERIAL0001" > "$HPS_SYS/class/dmi/id/product_serial"
  echo "ProLiant DL360 Gen9" > "$HPS_SYS/class/dmi/id/board_name"
  echo "P89 v2.76" > "$HPS_SYS/class/dmi/id/bios_version"
  echo "1" > "$HPS_SYS/class/scsi_host/host0/hba_mode_enabled"
  echo "hpsa" > "$HPS_SYS/class/scsi_host/host0/proc_name"
  echo "ahci" > "$HPS_SYS/class/scsi_host/host1/proc_name"

  make_shim lscpu '{"lscpu":[{"field":"Architecture:","data":"x86_64"}]}'
  make_shim numactl 'available: 2 nodes (0-1)'
  make_shim lspci '00:00.0 "Host bridge" "Intel" "Xeon" -r02 "HPE" "DL360"'
  make_shim blkid '/dev/sda1: UUID="abc" TYPE="ext4"'
  make_shim zpool '   pool: tank
     id: 1234
  state: ONLINE'
  cat > "$TEST_DIR/bin/lsblk" <<'EOF'
#!/bin/bash
echo "lsblk $*" >> "$SHIM_LOG"
if [[ -n "${FAKE_LSBLK_RAID:-}" ]]; then
  echo '{"blockdevices":[{"name":"sda","model":"LOGICAL VOLUME","children":[{"name":"sda1","model":null}]}]}'
else
  echo '{"blockdevices":[{"name":"sda","model":"MK001920GWCFB","children":[{"name":"sda1","model":null}]}]}'
fi
EOF
  cat > "$TEST_DIR/bin/ip" <<'EOF'
#!/bin/bash
echo "ip $*" >> "$SHIM_LOG"
case "$*" in
  *route*) echo '[{"dst":"default","gateway":"10.99.1.254","dev":"eno1"}]' ;;
  *link*) echo '[{"ifname":"eno1","address":"aa:bb:cc:dd:ee:ff"}]' ;;
  *addr*) echo '[{"ifname":"eno1","addr_info":[{"local":"10.99.1.100"}]}]' ;;
esac
EOF
  cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$SHIM_LOG"
for a in "$@"; do
  case "$a" in @*) cp "${a#@}" "$TEST_DIR/posted.json" ;; esac
done
exit "${FAKE_CURL_RC:-0}"
EOF
  chmod +x "$TEST_DIR"/bin/*
}

# make_shim <name> <stdout>: a shim that logs its call and prints fixed output.
make_shim() {
  local name="$1" out="$2"
  cat > "$TEST_DIR/bin/$name" <<EOF
#!/bin/bash
echo "$name \$*" >> "\$SHIM_LOG"
rc_var="FAKE_\$(echo $name | tr a-z A-Z)_RC"
cat <<'OUT'
$out
OUT
exit "\${!rc_var:-0}"
EOF
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "produces valid JSON with the expected top-level keys" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e . "$HPS_AUDIT_OUT" > /dev/null
  for k in schema collected_at dmi cpu memory numa pci storage_controllers block disk_by_id blkid zpool_import net; do
    jq -e --arg k "$k" 'has($k)' "$HPS_AUDIT_OUT" > /dev/null
  done
  jq -e '.schema == "hps-audit/1"' "$HPS_AUDIT_OUT"
  jq -e '.dmi.product_name == "ProLiant DL360 Gen9" and .dmi.product_serial == "SERIAL0001"' "$HPS_AUDIT_OUT"
  jq -e '.memory.MemTotal == 16318860' "$HPS_AUDIT_OUT"
  jq -e '.cpu.lscpu[0].data == "x86_64"' "$HPS_AUDIT_OUT"
  jq -e '.block.blockdevices[0].name == "sda"' "$HPS_AUDIT_OUT"
  jq -e '.net.link[0].address == "aa:bb:cc:dd:ee:ff"' "$HPS_AUDIT_OUT"
  jq -e '.zpool_import | test("pool: tank")' "$HPS_AUDIT_OUT"
}

@test "reports the hpsa controller mode and no RAID indicator for plain disks" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.storage_controllers.scsi_hosts | length == 2' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.scsi_hosts[0] == {host:"host0",driver:"hpsa",hba_mode_enabled:1}' "$HPS_AUDIT_OUT"
  jq -e '.storage_controllers.raid_mode_indicator == false' "$HPS_AUDIT_OUT"
}

@test "flags RAID mode when a disk model is a Smart Array LOGICAL VOLUME" {
  FAKE_LSBLK_RAID=1 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.storage_controllers.raid_mode_indicator == true' "$HPS_AUDIT_OUT"
}

@test "makes exactly one POST, to cmd=node_audit on the hps.ips address, with the JSON body" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  run grep -c '^curl ' "$SHIM_LOG"
  [ "$output" -eq 1 ]
  grep -q '^curl .*-X POST .*http://10.99.1.1/cgi-bin/boot_manager.sh?cmd=node_audit$' "$SHIM_LOG"
  cmp "$TEST_DIR/posted.json" "$HPS_AUDIT_OUT"
}

@test "never runs anything that writes to a disk" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  ! grep -q 'zpool import -f' "$SHIM_LOG"
  ! grep -qE '^(mdadm|wipefs|dd|parted|sgdisk|mkfs|zfs) ' "$SHIM_LOG"
  ! grep -qE 'zpool (create|destroy|labelclear|import [a-z])' "$SHIM_LOG"
  # The pool listing is the bare scan, nothing else.
  run grep -c '^zpool ' "$SHIM_LOG"
  [ "$output" -eq 1 ]
  grep -qx 'zpool import' "$SHIM_LOG"
}

@test "falls back to the default gateway when hps.ips is absent" {
  echo "console=ttyS0 hps.profile=audit" > "$HPS_CMDLINE"
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -q 'boot_manager.sh?cmd=node_audit' "$SHIM_LOG"
  grep -q 'http://10.99.1.254/cgi-bin/boot_manager.sh?cmd=node_audit' "$SHIM_LOG"
}

@test "a refused POST still exits 0 and the banner on the console says so" {
  FAKE_CURL_RC=22 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -q 'SEND FAILED' "$TEST_DIR/console"
  grep -q 'HPS AUDIT' "$TEST_DIR/console"
}

@test "a successful run writes the banner to the console and stdout" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  grep -q 'Audit sent to the IPS' "$TEST_DIR/console"
  [[ "$output" == *"Audit sent to the IPS"* ]]
}

@test "a failing collector leaves a null field and does not stop the audit" {
  FAKE_LSCPU_RC=1 run bash "$AUDIT"
  [ "$status" -eq 0 ]
  jq -e '.cpu == null' "$HPS_AUDIT_OUT"
  jq -e '.dmi.sys_vendor == "HPE"' "$HPS_AUDIT_OUT"
  grep -q '^curl ' "$SHIM_LOG"
}

@test "logs every command as it runs" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  for c in 'lscpu -J' 'numactl -H' 'lspci -k -mm' 'lsblk -O -J' 'ls -l /dev/disk/by-id' 'blkid' 'zpool import' 'ip -j link' 'ip -j addr'; do
    [[ "$output" == *"+ $c"* ]]
  done
}
