#!/usr/bin/env bats
#
# Storage faults (docs/STORAGE-FAULTS.md): the guest disk error policy of
# vm-define, max_sectors_kb and replacement_timeout from the cluster keys in
# leg-resolve, vm.min_free_kbytes in host-reserve-apply on a storage host.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_10_helpers
load p3_20_helpers

IQN="iqn.2026-01.hps.example:vm1-disk0"
IP="10.99.1.2"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-260.XXXXXX")"
  export TEST_DIR
  p3_20_setup
  p3_setup
  # p3_setup resets S to the same directory; the helpers share the state dir
  export HPS_MEMINFO="$TEST_DIR/meminfo"
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_ROLES_FILE="$TEST_DIR/roles"
  export HPS_CPU_ONLINE="$TEST_DIR/cpu-online"
  export HPS_ZFS_PARAMS="$TEST_DIR/zfs-params"
  export HPS_MODPROBE_DIR="$TEST_DIR/modprobe.d"
  export HPS_PROC_SYS="$TEST_DIR/procsys"
  mkdir -p "$HPS_ZFS_PARAMS" "$HPS_PROC_SYS/vm"
  echo 0 > "$HPS_ZFS_PARAMS/zfs_arc_max"
  echo "0-3" > "$HPS_CPU_ONLINE"
  echo 67584 > "$HPS_PROC_SYS/vm/min_free_kbytes"
  printf 'MemTotal:       %s kB\n' "$((8192 * 1024))" > "$HPS_MEMINFO"
  echo "SCH" > "$HPS_ROLES_FILE"
  cat > "$TEST_DIR/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$TEST_DIR/bin/systemctl"
}

teardown() {
  rm -rf "$TEST_DIR"
}

key() { printf '%s\n' "$2" > "$STATE/key.$1"; }

#--- vm-define: disk error policy

@test "vm-define: the default policy is stop, on error and read error, on the disk's driver" {
  run p3_20_define
  [ "$status" -eq 0 ]
  grep -q "<driver name='qemu' type='raw' cache='none' io='native' error_policy='stop' rerror_policy='stop'/>" "$STATE/xml.vm1"
}

@test "vm-define: --disk-error-policy report writes report on both" {
  run p3_20_define --disk-error-policy report
  [ "$status" -eq 0 ]
  grep -q "error_policy='report' rerror_policy='report'" "$STATE/xml.vm1"
  run ! grep -q "'stop'" "$STATE/xml.vm1"
}

@test "vm-define: a policy other than stop or report is refused (3), nothing defined" {
  run p3_20_define --disk-error-policy ignore
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not stop or report"* ]]
  [ ! -e "$STATE/xml.vm1" ]
  run p3_20_define --disk-error-policy
  [ "$status" -eq 2 ]
}

@test "vm-define: the same arguments again are already defined; report is a different definition" {
  p3_20_define > /dev/null 2>&1
  run p3_20_define
  [ "$status" -eq 0 ]
  [[ "$output" == *"already defined with this definition; nothing to do"* ]]
  run p3_20_define --disk-error-policy report
  [ "$status" -eq 3 ]
  [[ "$output" == *"defined differently"* ]]
}

@test "vm-define: a guest defined before the policy existed is not refused, and --replace applies it" {
  p3_20_define > /dev/null 2>&1
  sed -i "s/ error_policy='stop' rerror_policy='stop'//" "$STATE/xml.vm1"
  run p3_20_define
  [ "$status" -eq 0 ]
  [[ "$output" == *"without the disk error policy stop (made before it existed)"* ]]
  run ! grep -q "error_policy" "$STATE/xml.vm1"
  run p3_20_define --replace
  [ "$status" -eq 0 ]
  grep -q "error_policy='stop' rerror_policy='stop'" "$STATE/xml.vm1"
}

@test "vm-define: the policy is on every disk" {
  D2="$HPS_DEV/md/vm1-disk1"
  head -c 4096 /dev/zero > "$D2"
  run bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --disk "$D2" --net br-work --image "$IMG"
  [ "$status" -eq 0 ]
  [ "$(grep -c "error_policy='stop' rerror_policy='stop'" "$STATE/xml.vm1")" -eq 2 ]
}

#--- leg-resolve: max_sectors_kb and the replacement timeout

# queue <name> <cur> <hw>: the fake sysfs queue of the device the by-path link names.
queue() {
  mkdir -p "$HPS_SYS/block/$1/queue"
  echo "$2" > "$HPS_SYS/block/$1/queue/max_sectors_kb"
  echo "$3" > "$HPS_SYS/block/$1/queue/max_hw_sectors_kb"
}

# remote_dev: the by-path name is a symlink to sdz, so sdz is the sysfs name.
remote_dev() {
  touch "$HPS_DEV/sdz"
  ln -s ../../sdz "$REMDEV"
}

@test "leg-resolve: max_sectors_kb of an already present device is lowered to 256, logged" {
  remote_dev
  queue sdz 1280 32767
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 256 ]
  [[ "$stderr" == *"+ echo 256 > $HPS_SYS/block/sdz/queue/max_sectors_kb"* ]]
  [ "$output" = "$REMDEV" ]
}

@test "leg-resolve: iscsi_max_sectors_kb from the cluster key; a lower current value is kept (never raised)" {
  remote_dev
  key iscsi_max_sectors_kb 128
  queue sdz 512 32767
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 128 ]
  key iscsi_max_sectors_kb 1024
  queue sdz 512 32767
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 512 ]
  queue sdz 100 32767
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 100 ]
}

@test "leg-resolve: never beyond max_hw_sectors_kb; 0 keeps the kernel's limit" {
  remote_dev
  queue sdz 1280 200
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 200 ]
  key iscsi_max_sectors_kb 0
  queue sdz 1280 32767
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 1280 ]
  [[ "$stderr" == *"iscsi_max_sectors_kb is 0"* ]]
}

@test "leg-resolve: a key out of range is logged and the default 256 applies" {
  remote_dev
  queue sdz 1280 32767
  key iscsi_max_sectors_kb 30
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"iscsi_max_sectors_kb '30' is not 0 or 64-4096"* ]]
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 256 ]
  key iscsi_max_sectors_kb 99999
  queue sdz 1280 32767
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [[ "$stderr" == *"iscsi_max_sectors_kb '99999' is not 0-4096"* ]]
  [ "$(cat "$HPS_SYS/block/sdz/queue/max_sectors_kb")" = 256 ]
}

@test "leg-resolve: no sysfs queue for the device is a warning, the leg still resolves" {
  p3_make_remote
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING: no $HPS_SYS/block/"* ]]
  [ "$output" = "$REMDEV" ]
}

@test "leg-resolve: a login resolves, then limits the device that appeared" {
  # the iscsiadm shim makes a plain file; the limit is looked up by its name
  mkdir -p "$HPS_SYS/block/$P3_REM_NAME/queue"
  echo 1280 > "$HPS_SYS/block/$P3_REM_NAME/queue/max_sectors_kb"
  echo 32767 > "$HPS_SYS/block/$P3_REM_NAME/queue/max_hw_sectors_kb"
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -q -- '--login' "$SHIM_LOG"
  [ "$(cat "$HPS_SYS/block/$P3_REM_NAME/queue/max_sectors_kb")" = 256 ]
}

@test "leg-resolve: a local leg reads no key and touches no queue" {
  p3_make_local
  run bash "$S/leg-resolve" "$P3_LOC_SPEC"
  [ "$status" -eq 0 ]
  run ! grep '^curl' "$SHIM_LOG"
}

@test "leg-resolve: iscsi_replacement_timeout from the cluster key goes to the node record, the others keep their values" {
  key iscsi_replacement_timeout 45
  run bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n node.session.timeo.replacement_timeout -v 45" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n node.conn[0].timeo.noop_out_interval -v 5" "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n node.conn[0].timeo.login_timeout -v 15" "$SHIM_LOG"
  grep -qxF "curl -fsS --max-time 10 http://10.99.1.1/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=iscsi_replacement_timeout" "$SHIM_LOG"
}

@test "leg-resolve: an out of range or unreadable replacement timeout keeps 15" {
  key iscsi_replacement_timeout 2
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"iscsi_replacement_timeout '2' is not 5-600"* ]]
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n node.session.timeo.replacement_timeout -v 15" "$SHIM_LOG"
}

@test "leg-resolve: no hps.ips on the command line: defaults, no curl" {
  echo "BOOT_IMAGE=bzImage" > "$HPS_CMDLINE"
  run --separate-stderr bash "$S/leg-resolve" "$P3_REM_SPEC"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"hps.ips absent from the command line"* ]]
  run ! grep '^curl' "$SHIM_LOG"
  grep -qxF "iscsiadm -m node -T $IQN -p $IP -o update -n node.session.timeo.replacement_timeout -v 15" "$SHIM_LOG"
}

#--- host-reserve-apply: vm.min_free_kbytes

@test "host-reserve-apply: a storage host raises vm.min_free_kbytes to 2% of RAM (8 GiB: 163 MiB)" {
  run --separate-stderr bash "$S/host-reserve-apply"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((163 * 1024))" ]
  [[ "$stderr" == *"+ echo $((163 * 1024)) > $HPS_PROC_SYS/vm/min_free_kbytes"* ]]
  grep -qx "min_free_mib=163" "$HPS_RUN_DIR/host-reserve"
}

@test "host-reserve-apply: the floor is 128 MiB, the ceiling 2048 MiB" {
  printf 'MemTotal:       %s kB\n' "$((2048 * 1024))" > "$HPS_MEMINFO"
  run bash "$S/host-reserve-apply"
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((128 * 1024))" ]
  printf 'MemTotal:       %s kB\n' "$((262144 * 1024))" > "$HPS_MEMINFO"
  key storage_min_free_pct 10
  run bash "$S/host-reserve-apply"
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((2048 * 1024))" ]
}

@test "host-reserve-apply: storage_min_free_pct from the key; never lowers a higher kernel value; 0 leaves it" {
  key storage_min_free_pct 5
  run bash "$S/host-reserve-apply"
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((409 * 1024))" ]
  key storage_min_free_pct 1
  run --separate-stderr bash "$S/host-reserve-apply"
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((409 * 1024))" ]
  [[ "$stderr" == *"kept"* ]]
  echo 67584 > "$HPS_PROC_SYS/vm/min_free_kbytes"
  key storage_min_free_pct 0
  run --separate-stderr bash "$S/host-reserve-apply"
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = 67584 ]
  [[ "$stderr" == *"storage_min_free_pct 0"* ]]
  grep -qx "min_free_mib=-" "$HPS_RUN_DIR/host-reserve"
}

@test "host-reserve-apply: a key out of range is logged and the default 2 applies" {
  key storage_min_free_pct 50
  run --separate-stderr bash "$S/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"storage_min_free_pct '50' is not 0-10: default used"* ]]
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = "$((163 * 1024))" ]
}

@test "host-reserve-apply: a compute-only host leaves vm.min_free_kbytes alone" {
  echo "TCH" > "$HPS_ROLES_FILE"
  run bash "$S/host-reserve-apply"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_PROC_SYS/vm/min_free_kbytes")" = 67584 ]
  grep -qx "min_free_mib=-" "$HPS_RUN_DIR/host-reserve"
}

@test "host-reserve-apply: the HOST-RESERVE line is unchanged in form" {
  run bash "$S/host-reserve-apply"
  [[ "${lines[-1]}" =~ ^HOST-RESERVE\ roles=SCH\ roles_from=.*\ arc_max_mib=2048\ guest_mem_max_mib=-$ ]]
}

@test "changed scripts: shellcheck clean at warning level" {
  local s
  for s in leg-resolve vm-define host-reserve-apply; do
    shellcheck -S warning "$S/$s"
  done
}
