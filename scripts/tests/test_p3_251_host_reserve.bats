#!/usr/bin/env bats
#
# Resource isolation, host side: host-reserve-apply (machine.slice limits and
# the ZFS ARC cap from the cluster keys, defaults when they are absent) and the
# read-only host-resources; their allowlist entries and the boot unit.

bats_require_minimum_version 1.5.0
load p2_30_helpers

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-251.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  export HPS_RUN_DIR="$TEST_DIR/run"
  export HPS_ROLES_FILE="$TEST_DIR/roles"
  export HPS_MEMINFO="$TEST_DIR/meminfo"
  export HPS_CPU_ONLINE="$TEST_DIR/cpu-online"
  export HPS_ZFS_PARAMS="$TEST_DIR/zfs-params"
  export HPS_MODPROBE_DIR="$TEST_DIR/modprobe.d"
  export HPS_CGROUP_ROOT="$TEST_DIR/cgroup"
  export HPS_ARCSTATS="$TEST_DIR/arcstats"
  echo "SCH,TCH" > "$HPS_ROLES_FILE"
  mem 65536
  echo "0-31" > "$HPS_CPU_ONLINE"
  mkdir -p "$HPS_ZFS_PARAMS"
  echo 0 > "$HPS_ZFS_PARAMS/zfs_arc_max"
  # curl: cmd=cluster_variable&name=<k> answers $STATE/key.<k>, else HTTP 404 (exit 22).
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
[[ "${FAKE_CURL_RC:-0}" -ne 0 ]] && exit "$FAKE_CURL_RC"
url=${*: -1}
k=${url##*name=}
[[ -e "$STATE/key.$k" ]] || exit 22
cat "$STATE/key.$k"
SHIM
  cat > "$TEST_DIR/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SHIM_LOG"
[[ "$1" == show ]] && printf 'AllowedCPUs=2-31\nCPUWeight=50\nIOWeight=50\nMemoryMax=40265318400\n'
exit "${FAKE_SYSTEMCTL_RC:-0}"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

# mem <MiB>: MemTotal in the fake meminfo.
mem() {
  printf 'MemTotal:       %s kB\nMemAvailable:   %s kB\n' "$(($1 * 1024))" "$(($1 * 512))" > "$HPS_MEMINFO"
}

key() { printf '%s\n' "$2" > "$STATE/key.$1"; }

setprop() { grep '^systemctl set-property' "$SHIM_LOG"; }

@test "defaults on a converged 32-CPU 64 GiB host: 2 CPUs and 6553 MiB kept, ARC 25%, the rest to machine.slice" {
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "HOST-RESERVE roles=SCH,TCH cpus=32 host_cpus=0-1 guest_cpus=2-31 mem_total_mib=65536 host_mem_mib=6553 arc_max_mib=16384 guest_mem_max_mib=42599" ]
  [ "$(setprop)" = "systemctl set-property --runtime machine.slice AllowedCPUs=2-31 CPUWeight=50 IOWeight=50 MemoryMax=42599M" ]
  [ "$(cat "$HPS_ZFS_PARAMS/zfs_arc_max")" = "$((16384 * 1048576))" ]
  grep -qx "options zfs zfs_arc_max=$((16384 * 1048576))" "$HPS_MODPROBE_DIR/hps-zfs-arc.conf"
  grep -qx "guest_mem_max_mib=42599" "$HPS_RUN_DIR/host-reserve"
  [ "$(grep -c 'cmd=cluster_variable&name=' "$SHIM_LOG")" -eq 3 ]
}

@test "small host: 1 CPU of 4, at least 2048 MiB kept, ARC at least 1024 MiB" {
  echo "0-3" > "$HPS_CPU_ONLINE"
  mem 8192
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"host_cpus=0 guest_cpus=1-3 mem_total_mib=8192 host_mem_mib=2048 arc_max_mib=2048 guest_mem_max_mib=4096" ]]
  mem 2048
  : > "$SHIM_LOG"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: RAM 2048 MiB less host 2048 MiB and ARC 1024 MiB leaves -1024 MiB for guests; 512 MiB used"* ]]
  [[ "${lines[-1]}" == *"arc_max_mib=1024 guest_mem_max_mib=512" ]]
}

@test "the cluster keys win over the defaults" {
  key host_reserve_cpus 4
  key host_reserve_mem_mib 8192
  key zfs_arc_max_pct 10
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"host_cpus=0-3 guest_cpus=4-31 mem_total_mib=65536 host_mem_mib=8192 arc_max_mib=6553 guest_mem_max_mib=50791" ]]
  [ "$(setprop)" = "systemctl set-property --runtime machine.slice AllowedCPUs=4-31 CPUWeight=50 IOWeight=50 MemoryMax=50791M" ]
}

@test "host_reserve_cpus 0 keeps none: every CPU to guests" {
  key host_reserve_cpus 0
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"host_cpus=none guest_cpus=0-31 "* ]]
}

@test "a reserve of every CPU leaves one to the guests; a bad value takes the default, logged" {
  echo "0-3" > "$HPS_CPU_ONLINE"
  key host_reserve_cpus 8
  key zfs_arc_max_pct 95
  key host_reserve_mem_mib lots
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "$output" == *"host_reserve_cpus 8 leaves no CPU of 4 to guests: 3 kept"* ]]
  [[ "$output" == *"zfs_arc_max_pct '95' is not 1-90: default used"* ]]
  [[ "$output" == *"host_reserve_mem_mib 'lots' is not 256-16777216: default used"* ]]
  [[ "${lines[-1]}" == *"host_cpus=0-2 guest_cpus=3 mem_total_mib=65536 host_mem_mib=6553 arc_max_mib=16384 "* ]]
}

@test "a sparse online list keeps its gaps: 0-3,8-11 reserves 0, guests 1-3,8-11" {
  echo "0-3,8-11" > "$HPS_CPU_ONLINE"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == *"cpus=8 host_cpus=0 guest_cpus=1-3,8-11 "* ]]
}

@test "the IPS unreachable or absent: defaults, still applied" {
  FAKE_CURL_RC=7 run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cannot read host_reserve_cpus from the IPS (curl exit 7): default used"* ]]
  [[ "${lines[-1]}" == *"host_cpus=0-1 "* ]]
  echo "BOOT_IMAGE=bzImage" > "$HPS_CMDLINE"
  : > "$SHIM_LOG"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  run ! grep -q '^curl' "$SHIM_LOG"
  setprop
}

@test "storage only (SCH): ARC cap, no machine.slice call; compute only (TCH): machine.slice, no ARC" {
  echo "SCH" > "$HPS_ROLES_FILE"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  run ! grep -q '^systemctl' "$SHIM_LOG"
  [ "$(cat "$HPS_ZFS_PARAMS/zfs_arc_max")" -gt 0 ]
  echo "TCH" > "$HPS_ROLES_FILE"
  echo 0 > "$HPS_ZFS_PARAMS/zfs_arc_max"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_ZFS_PARAMS/zfs_arc_max")" = 0 ]
  [[ "${lines[-1]}" == *"arc_max_mib=- guest_mem_max_mib=58983" ]]
}

@test "no roles: nothing set, only the record" {
  rm -f "$HPS_ROLES_FILE"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "${lines[-1]}" == "HOST-RESERVE roles=none "*"guest_cpus=- "*"arc_max_mib=- guest_mem_max_mib=-" ]]
  run ! grep -q '^systemctl' "$SHIM_LOG"
  [ -s "$HPS_RUN_DIR/host-reserve" ]
}

@test "zfs not loaded: the ARC cap waits in modprobe.d" {
  rm -rf "$HPS_ZFS_PARAMS"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zfs module not loaded"* ]]
  grep -q "options zfs zfs_arc_max=" "$HPS_MODPROBE_DIR/hps-zfs-arc.conf"
}

@test "idempotent: the same run twice sets the same values" {
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  first=${lines[-1]}
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$first" ]
  [ "$(setprop | sort -u | wc -l)" -eq 1 ]
}

@test "systemctl failing is exit 1; an argument is usage 2" {
  FAKE_SYSTEMCTL_RC=1 run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply"
  [ "$status" -eq 1 ]
  run bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply" --now
  [ "$status" -eq 2 ]
}

#--- host-resources (read-only)

@test "host-resources: before any apply it says so; after, it shows the record, the slice, the cgroup, ZFS, memory" {
  run bash "$ROOT/node-manager/nixos-26/scripts/host-resources"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESERVE none (host-reserve-apply has not run this boot)"* ]]
  [[ "$output" == *"ZFS none (module not loaded)"* ]]
  [[ "$output" == *"CGROUP machine.slice cpus=- memory_max=- memory_current_mib=-"* ]]
  bash "$ROOT/node-manager/nixos-26/scripts/host-reserve-apply" > /dev/null 2>&1
  mkdir -p "$HPS_CGROUP_ROOT/machine.slice"
  echo "2-31" > "$HPS_CGROUP_ROOT/machine.slice/cpuset.cpus.effective"
  echo "$((42599 * 1048576))" > "$HPS_CGROUP_ROOT/machine.slice/memory.max"
  echo "$((1024 * 1048576))" > "$HPS_CGROUP_ROOT/machine.slice/memory.current"
  printf 'c_max 4 %s\nsize 4 %s\n' "$((16384 * 1048576))" "$((100 * 1048576))" > "$HPS_ARCSTATS"
  : > "$SHIM_LOG"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-resources"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESERVE roles=SCH,TCH cpus=32 host_cpus=0-1 guest_cpus=2-31 "* ]]
  [[ "$output" == *"SLICE machine.slice AllowedCPUs=2-31 CPUWeight=50 IOWeight=50 MemoryMax=40265318400"* ]]
  [[ "$output" == *"CGROUP machine.slice cpus=2-31 memory_max=$((42599 * 1048576)) memory_current_mib=1024"* ]]
  [[ "$output" == *"ZFS arc_max_mib=16384 arc_size_mib=100"* ]]
  [[ "$output" == *"MEM total_mib=65536 available_mib=32768"* ]]
  run ! grep -q 'set-property' "$SHIM_LOG"
}

@test "host-resources: running guests and their memory when virsh is there" {
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "-c" ]] && shift 2
case "$1" in
  list) printf 'g1\ng2\n\n' ;;
  dominfo) printf 'Name: %s\nMax memory:     2097152 KiB\n' "$2" ;;
esac
SHIM
  chmod +x "$TEST_DIR/bin/virsh"
  run bash "$ROOT/node-manager/nixos-26/scripts/host-resources"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GUESTS running=2 memory_mib=4096"* ]]
}

#--- wiring

@test "both scripts are allowlisted under profile node, executable, shellcheck clean, no library sourcing" {
  local s nix="$ROOT/nix/modules/hps-ctrl-exec.nix" sd="$ROOT/node-manager/nixos-26/scripts"
  for s in host-reserve-apply host-resources; do
    grep -qF "$s.source = mkScript \"$s\" (scriptsDir + \"/$s\");" "$nix"
    grep -qF "$s.options.profile = \"node\";" "$nix"
    [ -x "$sd/$s" ]
    [ "$(head -1 "$sd/$s")" = "#!/usr/bin/env bash" ]
    grep -q '^set -euo pipefail' "$sd/$s"
    shellcheck -S warning "$sd/$s"
    run ! bash -c "grep -v '^[[:space:]]*#' '$sd/$s' | grep -E '^[[:space:]]*(source|\\.)[[:space:]]'"
  done
}

@test "the boot unit runs the allowlisted script, after the network, before pairing" {
  local nix="$ROOT/nix/modules/hps-node.nix"
  grep -q 'systemd.services.hps-host-reserve' "$nix"
  grep -qF 'ExecStart = "${pkgs.bash}/bin/bash /opt/ctrl-exec-scripts/host-reserve-apply";' "$nix"
  awk '/systemd.services.hps-host-reserve/,/^  };/' "$nix" | grep -qF 'before = [ "hps-node-init.service" ];'
  awk '/systemd.services.hps-host-reserve/,/^  };/' "$nix" | grep -qF '"network-online.target"'
}
