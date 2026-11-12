#!/usr/bin/env bats
#
# Persistent filesystem checks (docs/MONITORING.md): check_fs (disk_<mount
# slug>, disk_other), check_zpool -m cap (zpool_cap), and their wiring in
# hps-monitor.nix. check_fs reads a fake mountinfo under $TEST_DIR/proc and a
# stat shim that answers `stat -f` from $TEST_DIR/statfs/<mount with / as _>:
# "<block size> <blocks> <free> <avail> <inodes> <free inodes>".

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/node-manager/nixos-26/plugins"
  MOD="$ROOT/nix/modules/hps-monitor.nix"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-207.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/proc/self" "$TEST_DIR/statfs" "$TEST_DIR/bin"
  cat > "$TEST_DIR/bin/stat" <<'EOF'
#!/bin/bash
p="${*: -1}"
f="$TEST_DIR/statfs/${p//\//_}"
[[ -f "$f" ]] || { echo "stat: cannot read file system information for '$p'" >&2; exit 1; }
cat "$f"
EOF
  chmod +x "$TEST_DIR/bin/stat"
  export HPS_PROC="$TEST_DIR/proc" HPS_STAT="$TEST_DIR/bin/stat"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# mnt <id> <maj:min> <mount point> <fstype>
mnt() {
  printf '%s 1 %s / %s rw,noatime shared:1 - %s /dev/x rw\n' "$1" "$2" "$3" "$4" >> "$TEST_DIR/proc/self/mountinfo"
}

# fs <mount> <used %> [inode used %]: 100 blocks of 4096, no reserve.
fs() {
  local used=$1 inode=${3:-1}
  used=$2
  printf '4096 100 %d %d 1000 %d\n' $((100 - used)) $((100 - used)) $((1000 - inode * 10)) > "$TEST_DIR/statfs/${1//\//_}"
}

cnh_table() {
  mnt 20 0:20 / tmpfs
  mnt 21 0:21 /proc proc
  mnt 22 0:22 /nix/.ro-store squashfs
  mnt 23 0:23 /nix/store overlay
  mnt 30 8:1 /var/lib/containers ext4
  mnt 31 8:1 /var/lib/hps-ips ext4
}

@test "check_fs is shellcheck clean; bad usage is UNKNOWN" {
  run shellcheck -s bash -S warning "$P/check_fs"
  [ "$status" -eq 0 ]
  run "$P/check_fs"
  [ "$status" -eq 3 ]
  run "$P/check_fs" -p relative
  [ "$status" -eq 3 ]
  run "$P/check_fs" -p /x -w 90 -c 80
  [ "$status" -eq 3 ]
  [[ "$output" == "DISK UNKNOWN - -w and -c must be percentages with -w below -c" ]]
  run "$P/check_fs" -p /x extra
  [ "$status" -eq 3 ]
}

@test "check_fs -p: below 80% OK, 80% WARNING, 90% CRITICAL, with the perfdata hps-monitor grades" {
  cnh_table
  fs /var/lib/containers 41 3
  run "$P/check_fs" -p /var/lib/containers -w 80 -c 90
  [ "$status" -eq 0 ]
  [ "$output" = "DISK OK - /var/lib/containers 41% used (0.2 MiB of 0.4 MiB), inodes 3% | used_pct=41%;80;90;0;100 inode_pct=3%;80;90;0;100 used=167936B size=409600B" ]
  fs /var/lib/containers 80
  run "$P/check_fs" -p /var/lib/containers -w 80 -c 90
  [ "$status" -eq 1 ]
  [[ "$output" == "DISK WARNING - /var/lib/containers 80% used"* ]]
  fs /var/lib/containers 100
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 2 ]
  [[ "$output" == "DISK CRITICAL - /var/lib/containers 100% used"* ]]
}

@test "check_fs -p: inodes alone can make it WARNING or CRITICAL" {
  cnh_table
  fs /var/lib/containers 10 85
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 1 ]
  [[ "$output" == *"inodes 85%"* ]]
  fs /var/lib/containers 10 95
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 2 ]
}

@test "check_fs -p: a filesystem with no fixed inode count reports space only" {
  cnh_table
  printf '4096 100 50 50 0 0\n' > "$TEST_DIR/statfs/_var_lib_containers"
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 0 ]
  [[ "$output" != *inode* ]]
}

@test "check_fs -p: not mounted, or on tmpfs, is OK and says so; a statfs failure is UNKNOWN" {
  mnt 20 0:20 / tmpfs
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 0 ]
  [ "$output" = "DISK OK - /var/lib/containers not mounted (on the RAM root; disk_root watches it)" ]
  mnt 30 0:30 /var/lib/containers tmpfs
  run "$P/check_fs" -p /var/lib/containers
  [ "$status" -eq 0 ]
  [[ "$output" == "DISK OK - /var/lib/containers is tmpfs (RAM"* ]]
  mnt 31 8:1 /var/lib/hps-builder ext4
  run "$P/check_fs" -p /var/lib/hps-builder
  [ "$status" -eq 3 ]
  [[ "$output" == "DISK UNKNOWN - statfs /var/lib/hps-builder failed" ]]
}

@test "check_fs -a: every persistent filesystem but the excluded, RAM, pseudo, network, ZFS and bind duplicates" {
  cnh_table
  mnt 40 8:2 /srv ext4
  mnt 41 8:3 /mnt/my\\040data xfs
  mnt 42 0:42 /tank zfs
  mnt 43 0:43 /net nfs4
  mnt 44 8:2 /srv/again ext4
  fs /srv 85 2
  fs "/mnt/my data" 10 1
  run "$P/check_fs" -a -x /var/lib/containers -x /var/lib/hps-ips
  [ "$status" -eq 1 ]
  [[ "$output" == "DISK WARNING - 2 filesystems: /srv 85% (inodes 2%); /mnt/my data 10% (inodes 1%) | srv_used_pct=85%;80;90;0;100 srv_inode_pct=2%;80;90;0;100 "* ]]
  [[ "$output" == *" mnt_my_data_used_pct=10%;80;90;0;100 "* ]]
  [[ "$output" != *tank* && "$output" != *containers* && "$output" != *again* && "$output" != */net* ]]
}

@test "check_fs -a: a node with nothing persistent mounted is OK" {
  mnt 20 0:20 / tmpfs
  mnt 23 0:23 /nix/store overlay
  run "$P/check_fs" -a
  [ "$status" -eq 0 ]
  [ "$output" = "DISK OK - no other persistent filesystem mounted" ]
}

zpool_stub() {
  printf '#!/bin/sh\n%s\n' "$1" > "$TEST_DIR/bin/zpool"
  chmod +x "$TEST_DIR/bin/zpool"
}

@test "check_zpool -m cap: capacity graded at -w and -c, health aside" {
  zpool_stub "printf 'tank\tDEGRADED\t41%%\nfast\tONLINE\t3%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool" -m cap -w 80 -c 90
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL_CAP OK - 2 pools: tank 41% fast 3% | tank_cap=41%;80;90;0;100 fast_cap=3%;80;90;0;100" ]
  zpool_stub "printf 'tank\tONLINE\t80%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool" -m cap
  [ "$status" -eq 1 ]
  zpool_stub "printf 'tank\tONLINE\t80%%\nfull\tONLINE\t97%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool" -m cap
  [ "$status" -eq 2 ]
  [[ "$output" == "ZPOOL_CAP CRITICAL - 2 pools: tank 80% full 97% |"* ]]
}

@test "check_zpool -m cap: no pools OK, zpool failing UNKNOWN, bad options UNKNOWN; health mode unchanged" {
  zpool_stub "exit 0"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool" -m cap
  [ "$output" = "ZPOOL_CAP OK - no pools imported" ]
  zpool_stub "exit 1"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool" -m cap
  [ "$status" -eq 3 ]
  run "$P/check_zpool" -m size
  [ "$status" -eq 3 ]
  run "$P/check_zpool" -m cap -w 95 -c 90
  [ "$status" -eq 3 ]
  zpool_stub "printf 'tank\tONLINE\t97%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$P/check_zpool"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL OK - 1 pools: tank=ONLINE | tank_cap=97%;80;90;0;100" ]
}

@test "hps-monitor.nix: check_fs everywhere, a disk_<slug> per role disk, disk_other, zpool_cap on storage" {
  grep -qF '(usagePlugin "check_fs" "")' "$MOD"
  grep -qF 'isCnh = lib.hasInfix "CNH" config.hps.roles;' "$MOD"
  grep -qF 'isBuilder = lib.hasInfix "BLD" config.hps.roles;' "$MOD"
  grep -qF 'lib.optionals isCnh [ "/var/lib/containers" "/var/lib/hps-ips" ]' "$MOD"
  grep -qF '++ lib.optional isBuilder "/var/lib/hps-builder";' "$MOD"
  grep -qF 'map (m: "disk_${mountSlug m} = check_fs -p ${m} ${diskThresholds}") roleMounts' "$MOD"
  grep -qF '"disk_other = check_fs -a" + lib.concatMapStrings (m: " -x ${m}") roleMounts' "$MOD"
  grep -qF 'diskWarn = "80";' "$MOD"
  grep -qF 'diskCrit = "90";' "$MOD"
  grep -qF '"zpool_cap = check_zpool -m cap ${diskThresholds}"' "$MOD"
  grep -qF '++ diskLines' "$MOD"
  grep -q '^# @HPS_PATH@$' "$P/check_fs"
}
