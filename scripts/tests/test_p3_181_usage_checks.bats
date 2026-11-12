#!/usr/bin/env bats
#
# Usage checks (docs/MONITORING.md): check_cpu, check_net, check_diskio,
# check_zpool_io, check_vms. Each plugin samples twice; the tests give it a fake
# /proc and /sys under $TEST_DIR/root and a sleep shim that, instead of waiting,
# copies $TEST_DIR/second over the tree, so the first read sees the "before" and
# the second the "after" state. zpool and virsh are shims that check their
# arguments. Plus the hps-monitor.nix wiring.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/node-manager/nixos-26/plugins"
  MOD="$ROOT/nix/modules/hps-monitor.nix"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-181.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/root/proc" "$TEST_DIR/root/sys/class/net" "$TEST_DIR/second/proc" "$TEST_DIR/second/sys/class/net" "$TEST_DIR/bin"
  printf '#!/bin/sh\ncp -r "%s/second/." "%s/root/"\n' "$TEST_DIR" "$TEST_DIR" > "$TEST_DIR/bin/sleep-shim"
  chmod +x "$TEST_DIR/bin/sleep-shim"
  export HPS_SLEEP="$TEST_DIR/bin/sleep-shim"
  export HPS_PROC="$TEST_DIR/root/proc"
  export HPS_SYS="$TEST_DIR/root/sys"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---- check_cpu -------------------------------------------------------------

cpu_fixture() {
  printf 'cpu  1000 0 500 8000 100 0 50 0 0 0\ncpu0 500 0 250 4000 50 0 25 0 0 0\ncpu1 500 0 250 4000 50 0 25 0 0 0\nintr 1\n' > "$TEST_DIR/root/proc/stat"
  printf 'cpu  1030 2 510 8930 110 1 55 12 0 0\ncpu0 515 1 255 4465 55 0 27 6 0 0\ncpu1 515 1 255 4465 55 1 28 6 0 0\nintr 2\n' > "$TEST_DIR/second/proc/stat"
}

@test "check_cpu: percentages of the interval, busy = 100 - idle - iowait, cpus counted" {
  cpu_fixture
  run "$P/check_cpu"
  [ "$status" -eq 0 ]
  [ "$output" = "CPU OK - 6.0% busy (iowait 1.0%, steal 1.2%) | busy=6.0%;;;0;100 user=3.0% nice=0.2% system=1.0% iowait=1.0% irq=0.1% softirq=0.5% steal=1.2% idle=93.0% cpus=2" ]
}

@test "check_cpu: -w and -c apply to the busy percentage" {
  cpu_fixture
  run "$P/check_cpu" -w 5 -c 6.5
  [ "$status" -eq 1 ]
  [[ "$output" == "CPU WARNING - 6.0% busy"*"busy=6.0%;5;6.5;0;100 "* ]]
  cpu_fixture
  run "$P/check_cpu" -w 5 -c 5.5
  [ "$status" -eq 2 ]
  [[ "$output" == "CPU CRITICAL - 6.0% busy"* ]]
  cpu_fixture
  run "$P/check_cpu" -w 50 -c 90
  [ "$status" -eq 0 ]
}

@test "check_cpu: bad interval, unreadable stat and a standing clock are UNKNOWN" {
  run "$P/check_cpu" -i 9
  [ "$status" -eq 3 ]
  run "$P/check_cpu" -i 2
  [ "$status" -eq 3 ]
  [[ "$output" == "CPU UNKNOWN - cannot read"* ]]
  cpu_fixture
  cp "$TEST_DIR/root/proc/stat" "$TEST_DIR/second/proc/stat"
  run "$P/check_cpu"
  [ "$status" -eq 3 ]
  [[ "$output" == "CPU UNKNOWN - no CPU time elapsed"* ]]
}

# ---- check_net -------------------------------------------------------------

# iface DIR NAME STATE rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped
iface() {
  local d=$1/class/net/$2
  mkdir -p "$d/statistics"
  echo "$3" > "$d/operstate"
  local names=(rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped)
  local i
  for i in 0 1 2 3 4 5 6 7; do
    echo "${@:4:8}" | cut -d' ' -f$((i + 1)) > "$d/statistics/${names[$i]}"
  done
}

net_fixture() {
  local n
  for n in lo veth1 vnet0 eth1; do
    iface "$TEST_DIR/root/sys" $n up 0 0 0 0 0 0 0 0
    iface "$TEST_DIR/second/sys" $n up 999999 999999 999 999 9 9 9 9
  done
  iface "$TEST_DIR/root/sys" eth1 down 0 0 0 0 0 0 0 0
  iface "$TEST_DIR/root/sys" br0 unknown 0 0 0 0 0 0 0 0
  iface "$TEST_DIR/second/sys" br0 unknown 0 0 0 0 0 0 0 0
  iface "$TEST_DIR/root/sys" eth0 up 1000000 0 1000 0 0 0 0 0
  iface "$TEST_DIR/second/sys" eth0 up 1125000 62500 1100 50 2 0 0 1
  iface "$TEST_DIR/root/sys" eth0.20 up 0 0 0 0 0 0 0 0
  iface "$TEST_DIR/second/sys" eth0.20 up 125000 0 7 0 0 0 0 0
}

@test "check_net: rates and counter deltas per interface, dots sanitised, lo/veth/vnet/down left out" {
  net_fixture
  run "$P/check_net"
  [ "$status" -eq 0 ]
  [ "$output" = "NET OK - rx 2.0 Mbit/s tx 0.5 Mbit/s (3 interfaces) | br0_rx_Bps=0 br0_tx_Bps=0 br0_rx_pps=0 br0_tx_pps=0 br0_rx_errors=0c br0_tx_errors=0c br0_rx_dropped=0c br0_tx_dropped=0c eth0_rx_Bps=125000 eth0_tx_Bps=62500 eth0_rx_pps=100 eth0_tx_pps=50 eth0_rx_errors=2c eth0_tx_errors=0c eth0_rx_dropped=0c eth0_tx_dropped=1c eth0_20_rx_Bps=125000 eth0_20_tx_Bps=0 eth0_20_rx_pps=7 eth0_20_tx_pps=0 eth0_20_rx_errors=0c eth0_20_tx_errors=0c eth0_20_rx_dropped=0c eth0_20_tx_dropped=0c" ]
  [[ "$output" != *"veth1_"* && "$output" != *"vnet0_"* && "$output" != *"lo_"* && "$output" != *"eth1_"* ]]
}

@test "check_net: -i divides by the interval; no usable interface is OK" {
  net_fixture
  run "$P/check_net" -i 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"eth0_rx_Bps=25000 "* ]]
  rm -rf "$TEST_DIR/root/sys/class/net/eth1" "$TEST_DIR/second/sys/class/net/eth1"
  rm -rf "$TEST_DIR/root/sys/class/net/eth0" "$TEST_DIR/root/sys/class/net/eth0.20" "$TEST_DIR/root/sys/class/net/br0"
  run "$P/check_net"
  [ "$status" -eq 0 ]
  [ "$output" = "NET OK - no active interfaces" ]
  rm -rf "$TEST_DIR/root/sys/class/net"
  run "$P/check_net"
  [ "$status" -eq 3 ]
}

# ---- check_diskio ----------------------------------------------------------

diskio_fixture() {
  cat > "$TEST_DIR/root/proc/diskstats" <<'EOT'
   8       0 sda 1000 0 20000 500 2000 0 40000 900 0 1000 1400
   8       1 sda1 5 0 50 5 5 0 50 5 0 5 10
 259       0 nvme0n1 100 0 2000 50 0 0 0 0 0 100 50
 259       1 nvme0n1p1 1 0 10 1 0 0 0 0 0 1 1
 252       0 dm-0 7 0 70 7 7 0 70 7 0 7 14
   9       0 md0 7 0 70 7 7 0 70 7 0 7 14
 230       0 zd0 7 0 70 7 7 0 70 7 0 7 14
   7       0 loop0 7 0 70 7 7 0 70 7 0 7 14
   1       0 ram0 7 0 70 7 7 0 70 7 0 7 14
EOT
  cat > "$TEST_DIR/second/proc/diskstats" <<'EOT'
   8       0 sda 1100 0 22048 550 2050 0 44096 950 0 1250 1500
   8       1 sda1 99 0 990 5 5 0 50 5 0 5 10
 259       0 nvme0n1 110 0 2200 60 0 0 0 0 0 2100 60
 259       1 nvme0n1p1 99 0 990 1 0 0 0 0 0 1 1
 252       0 dm-0 99 0 990 7 7 0 70 7 0 7 14
   9       0 md0 99 0 990 7 7 0 70 7 0 7 14
 230       0 zd0 99 0 990 7 7 0 70 7 0 7 14
   7       0 loop0 99 0 990 7 7 0 70 7 0 7 14
   1       0 ram0 99 0 990 7 7 0 70 7 0 7 14
EOT
}

@test "check_diskio: whole disks only, bytes = sectors * 512, busy from io_ticks and capped at 100" {
  diskio_fixture
  run "$P/check_diskio"
  [ "$status" -eq 0 ]
  [ "$output" = "DISKIO OK - read 1.2 MB/s write 2.1 MB/s (2 disks) | disks=2 sda_rd_Bps=1048576 sda_wr_Bps=2097152 sda_rd_iops=100 sda_wr_iops=50 sda_busy=25.0% nvme0n1_rd_Bps=102400 nvme0n1_wr_Bps=0 nvme0n1_rd_iops=10 nvme0n1_wr_iops=0 nvme0n1_busy=100.0%" ]
}

@test "check_diskio: no whole disk (a RAM node) is OK, not UNKNOWN" {
  printf '   7       0 loop0 1 0 1 1 1 0 1 1 0 1 1\n   1       0 ram0 1 0 1 1 1 0 1 1 0 1 1\n 252       0 dm-0 1 0 1 1 1 0 1 1 0 1 1\n' > "$TEST_DIR/root/proc/diskstats"
  run "$P/check_diskio"
  [ "$status" -eq 0 ]
  [ "$output" = "DISKIO OK - no disks | disks=0" ]
  : > "$TEST_DIR/root/proc/diskstats"
  run "$P/check_diskio"
  [ "$status" -eq 0 ]
  [ "$output" = "DISKIO OK - no disks | disks=0" ]
}

@test "check_diskio: an unreadable diskstats is UNKNOWN" {
  run "$P/check_diskio"
  [ "$status" -eq 3 ]
  [[ "$output" == "DISKIO UNKNOWN - cannot read"* ]]
}

# ---- check_zpool_io --------------------------------------------------------

zpool_shim() {
  printf '#!/bin/sh\n[ "$*" = "iostat -Hp 1 2" ] || { echo "bad args: $*" >&2; exit 2; }\n%s\n' "$1" > "$TEST_DIR/bin/zpool"
  chmod +x "$TEST_DIR/bin/zpool"
  export HPS_ZPOOL="$TEST_DIR/bin/zpool"
}

@test "check_zpool_io: the second sample, per pool, alloc and free from the same output" {
  zpool_shim "printf 'tank\t9\t9\t9\t9\t9\t9\nfast\t9\t9\t9\t9\t9\t9\ntank\t5000000000\t995000000000\t12\t34\t1500000\t2500000\nfast\t100\t900\t1\t2\t500000\t1000000\n'"
  run "$P/check_zpool_io"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL_IO OK - read 2.0 MB/s write 3.5 MB/s (2 pools) | pools=2 tank_alloc=5000000000B tank_free=995000000000B tank_rd_iops=12 tank_wr_iops=34 tank_rd_Bps=1500000 tank_wr_Bps=2500000 fast_alloc=100B fast_free=900B fast_rd_iops=1 fast_wr_iops=2 fast_rd_Bps=500000 fast_wr_Bps=1000000" ]
}

@test "check_zpool_io: no pools is OK; a failing zpool is UNKNOWN" {
  zpool_shim "echo 'no pools available' >&2"
  run "$P/check_zpool_io"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL_IO OK - no pools | pools=0" ]
  zpool_shim "echo 'no pools available' >&2; exit 1"
  run "$P/check_zpool_io"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL_IO OK - no pools | pools=0" ]
  zpool_shim "echo 'cannot open /dev/zfs' >&2; exit 1"
  run "$P/check_zpool_io"
  [ "$status" -eq 3 ]
  [[ "$output" == "ZPOOL_IO UNKNOWN - zpool iostat failed (exit 1): cannot open /dev/zfs" ]]
}

# ---- check_vms -------------------------------------------------------------

virsh_shim() {
  cat > "$TEST_DIR/bin/virsh" <<EOT
#!/bin/sh
[ "\$*" = "-c qemu:///system domstats --raw --list-running --cpu-total --balloon --vcpu --block --interface" ] || { echo "bad args: \$*" >&2; exit 2; }
cat "$TEST_DIR/root/virsh.out"
EOT
  chmod +x "$TEST_DIR/bin/virsh"
  export HPS_VIRSH="$TEST_DIR/bin/virsh"
}

# dom NAME CPU_NS RSS_KIB MEM_KIB VCPUS RD0 WR0 RD1 WR1 RX TX
dom() {
  cat <<EOT
Domain: '$1'
  state.state=1
  cpu.time=$2
  cpu.user=1
  cpu.system=1
  balloon.current=$4
  balloon.rss=$3
  vcpu.current=$5
  vcpu.maximum=$5
  vcpu.0.state=1
  vcpu.0.time=5
  block.count=2
  block.0.name=vda
  block.0.rd.bytes=$6
  block.0.wr.bytes=$7
  block.1.name=vdb
  block.1.rd.bytes=$8
  block.1.wr.bytes=$9
  net.count=1
  net.0.name=vnet0
  net.0.rx.bytes=${10}
  net.0.tx.bytes=${11}

EOT
}

@test "check_vms: per guest cpu %, memory, block and net rates, names sanitised, late guests ignored" {
  virsh_shim
  { dom web-1 10000000000 1048576 2097152 2 1000 2000 500 0 10000 20000; dom Db.2 1000000000 524288 1048576 1 0 0 0 0 0 0; } > "$TEST_DIR/root/virsh.out"
  { dom web-1 11500000000 1048576 2097152 2 3000 5000 1500 1000 15000 21000; dom Db.2 1250000000 524288 1048576 1 0 0 0 0 0 0; dom late 5 1 1 1 0 0 0 0 0 0; } > "$TEST_DIR/second/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [ "$output" = "VMS OK - 2 running VMs (rss 1.5 GiB) | vms=2 web-1_cpu_pct=150.0% web-1_vcpus=2 web-1_rss=1073741824B web-1_mem=2147483648B web-1_rd_Bps=3000 web-1_wr_Bps=4000 web-1_rx_Bps=5000 web-1_tx_Bps=1000 db_2_cpu_pct=25.0% db_2_vcpus=1 db_2_rss=536870912B db_2_mem=1073741824B db_2_rd_Bps=0 db_2_wr_Bps=0 db_2_rx_Bps=0 db_2_tx_Bps=0" ]
}

@test "check_vms: no running VMs is OK; a failing virsh is UNKNOWN" {
  virsh_shim
  : > "$TEST_DIR/root/virsh.out"
  run "$P/check_vms"
  [ "$status" -eq 0 ]
  [ "$output" = "VMS OK - no running VMs | vms=0" ]
  printf '#!/bin/sh\necho "error: failed to connect to the hypervisor" >&2\nexit 1\n' > "$TEST_DIR/bin/virsh"
  run "$P/check_vms"
  [ "$status" -eq 3 ]
  [ "$output" = "VMS UNKNOWN - virsh domstats failed: error: failed to connect to the hypervisor" ]
}

# ---- all plugins -----------------------------------------------------------

@test "the usage plugins are executable, shellcheck clean, reject a bad interval and carry the PATH placeholder" {
  local p
  for p in check_cpu check_net check_diskio check_zpool_io check_vms check_swap_use; do
    [ -x "$P/$p" ]
    run shellcheck -s bash -S warning "$P/$p"
    [ "$status" -eq 0 ]
    grep -qxF '# @HPS_PATH@' "$P/$p"
    run "$P/$p" -i 6
    [ "$status" -eq 3 ]
    [[ "$output" == *"UNKNOWN - -i must be 1 to 5" ]]
    run "$P/$p" -i 0
    [ "$status" -eq 3 ]
  done
}

@test "perf labels use only [a-z0-9_.-] and a UOM of %, B or c" {
  cpu_fixture
  run "$P/check_cpu"
  ! [[ ${output#*|} =~ [A-Z] ]]
  net_fixture
  run "$P/check_net"
  local label
  for label in $(printf '%s\n' "${output#*|}" | tr ' ' '\n' | cut -d= -f1); do
    [[ $label =~ ^[a-z0-9_-]+(_Bps|_pps)?$ ]]
  done
}

# ---- hps-monitor.nix wiring ------------------------------------------------

@test "wiring: cpu, net, diskio on every node; zpool_io on storage nodes; vms on compute nodes" {
  grep -qF '"cpu = check_cpu"' "$MOD"
  grep -qF '"net = check_net"' "$MOD"
  grep -qF '"diskio = check_diskio"' "$MOD"
  run awk '/lib.optionals isStorage \[/ {f=1} f && /"zpool_io = check_zpool_io"/ {print "storage"} f && /^  \]/ {f=0}' "$MOD"
  [ "$output" = storage ]
  grep -qF '++ lib.optional isCompute "vms = check_vms")' "$MOD"
  grep -qF 'isCompute = lib.hasInfix "TCH" config.hps.roles;' "$MOD"
  # the every-node checks sit before the storage block, not inside it
  run awk '/"diskio = check_diskio"/ {d=NR} /lib.optionals isStorage/ {s=NR} END {print (d && s && d < s) ? "before" : "bad"}' "$MOD"
  [ "$output" = before ]
}

@test "wiring: the plugins are installed from node-manager with a tool PATH and absolute zpool/virsh paths" {
  grep -qF 'pluginSrcDir = ../../node-manager/nixos-26/plugins;' "$MOD"
  grep -qF 'lib.makeBinPath [ pkgs.coreutils pkgs.gawk pkgs.jq ]' "$MOD"
  grep -qF -e "--replace-fail '# @HPS_PATH@'" "$MOD"
  local p
  for p in check_cpu check_net check_diskio check_zpool_io check_vms check_swap_use check_osvc_hb; do
    grep -qF "\"$p\"" "$MOD"
    [ -f "$P/$p" ]
  done
  grep -qF "HPS_ZPOOL:-\${config.boot.zfs.package}/bin/zpool}" "$MOD"
  grep -qF "HPS_VIRSH:-\${config.virtualisation.libvirtd.package}/bin/virsh}" "$MOD"
  grep -qF 'ZPOOL=${HPS_ZPOOL:-zpool}' "$P/check_zpool_io"
  grep -qF 'VIRSH=${HPS_VIRSH:-virsh}' "$P/check_vms"
  grep -qF '${usagePlugins}' "$MOD"
}

@test "wiring: the compute profile enables libvirtd, which is where virsh comes from" {
  grep -q 'virtualisation.libvirtd = {' "$ROOT/nix/modules/profiles/compute.nix"
  grep -q 'enable = true;' "$ROOT/nix/modules/profiles/compute.nix"
}

@test "docs: MONITORING.md lists every usage check and the label scheme" {
  local n
  for n in cpu net diskio zpool_io vms; do
    grep -q "^| \`$n\` " "$ROOT/docs/MONITORING.md"
  done
  grep -q '_Bps' "$ROOT/docs/MONITORING.md"
  grep -q '_pps' "$ROOT/docs/MONITORING.md"
  grep -q '_iops' "$ROOT/docs/MONITORING.md"
}
