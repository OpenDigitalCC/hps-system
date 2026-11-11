# Helpers for the CS-2.1 storage-script tests (test_p2_30_* .. test_p2_39_*).
# Source from setup() after TEST_DIR is set; call p2_setup_dirs, then the shim
# installers a test needs. Shims record every call in $SHIM_LOG and keep their
# fake machine state as files under $STATE.

p2_setup_dirs() {
  export STATE="$TEST_DIR/state"
  export SHIM_LOG="$TEST_DIR/shim.log"
  export TMPDIR="$TEST_DIR/tmp"
  export WORK="$TEST_DIR/work"
  mkdir -p "$STATE" "$TMPDIR" "$WORK" "$TEST_DIR/bin"
  : > "$SHIM_LOG"
  export PATH="$TEST_DIR/bin:$PATH"
  S="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  echo "BOOT_IMAGE=bzImage hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=converged" > "$HPS_CMDLINE"
  cd "$WORK"
}

# xxd: only "-r -p" (hex on stdin to bytes) is used by the scripts.
p2_shim_xxd() {
  cat > "$TEST_DIR/bin/xxd" <<'SHIM'
#!/usr/bin/env bash
exec perl -e 'local $/; my $h = <STDIN>; $h =~ s/\s+//g; print pack("H*", $h);'
SHIM
  chmod +x "$TEST_DIR/bin/xxd"
}

# The disk-side shims: readlink -e, lsblk, blkid, zdb, wipefs.
# State files: missing.<name>, lsblk.<dev basename> (TYPE MOUNTPOINTS lines),
# lsblk-d.<name>, blkid.<dev basename>, zdb.<dev basename>.
p2_shim_disks() {
  cat > "$TEST_DIR/bin/readlink" <<'SHIM'
#!/usr/bin/env bash
echo "readlink $*" >> "$SHIM_LOG"
path="${@: -1}"
name="${path##*/}"
[[ -e "$STATE/missing.$name" ]] && exit 1
echo "/dev/fake-$name"
SHIM
  cat > "$TEST_DIR/bin/lsblk" <<'SHIM'
#!/usr/bin/env bash
echo "lsblk $*" >> "$SHIM_LOG"
dev="${@: -1}"
name="${dev##*/}"
name="${name#fake-}"
if [[ "$*" == *" -D "* || "$1" == "-D" ]]; then
  if [[ -e "$STATE/lsblk-d.$name" ]]; then cat "$STATE/lsblk-d.$name"; else echo "$name 4096 2147483648"; fi
  exit 0
fi
if [[ -e "$STATE/lsblk.$name" ]]; then cat "$STATE/lsblk.$name"; else echo "disk "; fi
SHIM
  cat > "$TEST_DIR/bin/blkid" <<'SHIM'
#!/usr/bin/env bash
echo "blkid $*" >> "$SHIM_LOG"
dev="${@: -1}"
name="${dev##*/}"; name="${name#fake-}"
if [[ -e "$STATE/blkid.$name" ]]; then echo "TYPE=zfs_member"; exit 0; fi
exit 2
SHIM
  cat > "$TEST_DIR/bin/zdb" <<'SHIM'
#!/usr/bin/env bash
echo "zdb $*" >> "$SHIM_LOG"
dev="${@: -1}"
name="${dev##*/}"; name="${name#fake-}"
[[ -e "$STATE/zdb.$name" ]] && exit 0
exit 1
SHIM
  cat > "$TEST_DIR/bin/wipefs" <<'SHIM'
#!/usr/bin/env bash
echo "wipefs $*" >> "$SHIM_LOG"
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

# zpool: state files pool-imported, import-listing, import-fail, import-needs-m,
# status-pool, status-all, status-t; FAKE_TRIM_RC.
p2_shim_zpool() {
  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
case "$1" in
  list) [[ -e "$STATE/pool-imported" ]] && exit 0; exit 1 ;;
  import)
    if [[ "$*" == "import -d /dev/disk/by-id" ]]; then
      [[ -e "$STATE/import-listing" ]] && cat "$STATE/import-listing"
      exit 0
    fi
    [[ -e "$STATE/import-fail" ]] && exit 1
    if [[ -e "$STATE/import-needs-m" && "$*" != *" -m "* ]]; then exit 1; fi
    touch "$STATE/pool-imported"
    exit 0 ;;
  status)
    if [[ "$*" == *" -t "* ]]; then cat "$STATE/status-t" 2> /dev/null; exit 0; fi
    last="${@: -1}"
    if [[ "$last" == "-P" ]]; then cat "$STATE/status-all" 2> /dev/null; exit 0; fi
    cat "$STATE/status-pool" 2> /dev/null; exit 0 ;;
  get) echo "lab	health	ONLINE	-"; exit 0 ;;
  create) touch "$STATE/pool-imported"; exit "${FAKE_CREATE_RC:-0}" ;;
  export | destroy) rm -f "$STATE/pool-imported"; exit 0 ;;
  trim) exit "${FAKE_TRIM_RC:-0}" ;;
  labelclear) exit "${FAKE_LABELCLEAR_RC:-0}" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/zpool"
}

# zfs: state files datasets (names, one per line), zvols, keystatus; the key
# bytes a command read on stdin are kept in $STATE/stdin.<verb> and the loaded
# key in $STATE/loaded-key (state, outside the dirs the scripts may write to).
p2_shim_zfs() {
  cat > "$TEST_DIR/bin/zfs" <<'SHIM'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
verb="$1"
last="${@: -1}"
case "$verb" in
  list)
    if [[ "$*" == *"-o type"* ]]; then
      grep -qxF "$last" "$STATE/zvols" 2> /dev/null && { echo volume; exit 0; }
      grep -qxF "$last" "$STATE/datasets" 2> /dev/null && { echo filesystem; exit 0; }
      exit 1
    fi
    grep -qxF "$last" "$STATE/datasets" 2> /dev/null && exit 0
    exit 1 ;;
  get) cat "$STATE/keystatus" 2> /dev/null || echo unavailable ;;
  create)
    cat > "$STATE/stdin.create"
    echo "$last" >> "$STATE/datasets"
    exit "${FAKE_ZFS_CREATE_RC:-0}" ;;
  load-key)
    cat > "$STATE/stdin.load-key"
    if [[ "$2" == "-n" ]]; then
      cmp -s "$STATE/stdin.load-key" "$STATE/loaded-key" && exit 0
      exit 1
    fi
    cp "$STATE/stdin.load-key" "$STATE/loaded-key"
    echo available > "$STATE/keystatus"
    exit "${FAKE_LOADKEY_RC:-0}" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/zfs"
}

# targetcli: a small stateful LIO tree under $STATE/ls/.
p2_shim_targetcli() {
  mkdir -p "$STATE/ls"
  cat > "$TEST_DIR/bin/targetcli" <<'SHIM'
#!/usr/bin/env bash
echo "targetcli $*" >> "$SHIM_LOG"
L="$STATE/ls"
key() { local k="${1//\//_}"; echo "$L/$k"; }
if [[ "$1" == ls ]]; then
  if [[ "$2" == /iscsi ]]; then
    cat "$L/_iscsi" 2> /dev/null
    cat "$L"/_iscsi_*_luns 2> /dev/null
    exit 0
  fi
  cat "$(key "$2")" 2> /dev/null
  exit 0
fi
[[ "$1" == saveconfig ]] && exit 0
path="$1"; verb="$2"
case "$path $verb" in
  "/backstores/block create")
    echo "  o- $3 ...... [$4 (1.0GiB) write-thru activated]" >> "$(key /backstores/block)" ;;
  "/backstores/block delete")
    grep -vF "o- $3 " "$(key /backstores/block)" > "$L/tmp" || true; mv "$L/tmp" "$(key /backstores/block)" ;;
  "/iscsi create")
    echo "  o- $3 ...... [TPGs: 1]" >> "$L/_iscsi"
    echo "  o- [::0]:3260 ...... [OK]" > "$(key "/iscsi/$3/tpg1/portals")" ;;
  "/iscsi delete")
    grep -vF "o- $3 " "$L/_iscsi" > "$L/tmp" || true; mv "$L/tmp" "$L/_iscsi"
    rm -f "$(key "/iscsi/$3/tpg1/luns")" "$(key "/iscsi/$3/tpg1/acls")" "$(key "/iscsi/$3/tpg1/portals")" ;;
  */tpg1/luns\ create)
    n="${3##*/}"
    echo "  o- lun0 ...... [block/$n (/dev/zvol/x) (default_tg_pt_gp)]" >> "$(key "$path")" ;;
  */tpg1/acls\ create)
    echo "  o- $3 ...... [Mapped LUNs: 1]" >> "$(key "$path")" ;;
  */tpg1/portals\ create)
    echo "  o- $3:3260 ...... [OK]" >> "$(key "$path")" ;;
  */tpg1/portals\ delete)
    # targetcli lists an IPv6 portal in brackets: delete ::0 3260 removes [::0]:3260
    case "$3" in *:*) ip="[$3]" ;; *) ip="$3" ;; esac
    grep -vF "o- $ip:$4 " "$(key "$path")" > "$L/tmp" || true; mv "$L/tmp" "$(key "$path")" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/targetcli"
}

# --- the key document of storage-pool-create -----------------------------------

P2_KEY=a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90
P2_DISK_A=ata-DISK-A
P2_DISK_B=ata-DISK-B

# p2_key_payload [key_hex]: the stdin document of storage-pool-create.
p2_key_payload() {
  jq -n -c --arg k "${1:-$P2_KEY}" '{key_hex:$k}'
}
