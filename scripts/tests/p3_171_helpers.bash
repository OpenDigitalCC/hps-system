# Helpers for the CS-3.11 container-host tests (test_p3_171_* .. test_p3_175_*).
# Load after p2_30_helpers (p2_setup_dirs: TEST_DIR/bin on PATH, $STATE,
# $SHIM_LOG, HPS_CMDLINE with hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff).
#
# Shims log every call to $SHIM_LOG and keep fake machine state under $STATE:
#   sig.<dev basename>   blkid -p -o export output (absent: blank device)
#   sigrc.<dev basename> blkid -p exit status to return instead
#   labelled             devices blkid -t LABEL=hps-cnh lists, one per line
#   mounts               "<dir> <source>" lines (findmnt, mount)
#   www/<url path>       what curl serves for http://<host>/<url path>
#   partial.<file name>  N: curl writes only the first N bytes, exits 18
#   images               image names podman image exists accepts
#   ipaddr.<iface>       ip -j -4 addr show dev <iface> output
#   fw                   the nixos-fw chain exists; fw-rules: inserted rules
#   df                   "<avail> <size>" bytes df reports (absent: 100 GiB free of 200)

p3_171_setup() {
  p2_setup_dirs
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_CNH_ROOT="$TEST_DIR/root"
  export HPS_SYS_NET="$TEST_DIR/sys-net"
  export HPS_PROC_VLAN="$TEST_DIR/proc-vlan"
  export HPS_IPS_WAIT=1
  export HPS_IPS_STEP=0.1
  export HPS_CNH_SETTLE=0
  mkdir -p "$HPS_DEV/disk/by-id" "$HPS_DEV/md" "$HPS_CNH_ROOT" "$HPS_SYS_NET" "$HPS_PROC_VLAN" "$STATE/www"
  export B="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/boot"
  p3_171_shims
}

# p3_171_disk <name>: a fake block device (a regular file) under $HPS_DEV.
p3_171_disk() {
  mkdir -p "$(dirname "$HPS_DEV/$1")"
  : > "$HPS_DEV/$1"
}

# p3_171_mount <dir> <source>: record a mount the shims report.
p3_171_mount() {
  echo "$1 $2" >> "$STATE/mounts"
}

# p3_171_nic <iface> <mac> [vlan]
p3_171_nic() {
  mkdir -p "$HPS_SYS_NET/$1"
  echo "$2" > "$HPS_SYS_NET/$1/address"
  if [[ -n "${3:-}" ]]; then
    : > "$HPS_PROC_VLAN/$1"
  fi
}

# p3_171_serve <url path> <content>
p3_171_serve() {
  mkdir -p "$(dirname "$STATE/www/$1")"
  printf '%s' "$2" > "$STATE/www/$1"
}

p3_171_sha() {
  local s
  s=$(/usr/bin/sha256sum "$1")
  printf '%s\n' "${s%% *}"
}

p3_171_shims() {
  cat > "$TEST_DIR/bin/blkid" <<'SHIM'
#!/usr/bin/env bash
echo "blkid $*" >> "$SHIM_LOG"
if [[ "$*" == *"-t LABEL=hps-cnh"* ]]; then
  [[ -s "$STATE/labelled" ]] || exit 2
  cat "$STATE/labelled"
  exit 0
fi
dev="${@: -1}"
name="${dev##*/}"
[[ -e "$STATE/sigrc.$name" ]] && exit "$(cat "$STATE/sigrc.$name")"
[[ -e "$STATE/sig.$name" ]] || exit 2
if [[ "$*" == *"-s TYPE"* ]]; then
  sed -n 's/^TYPE=//p' "$STATE/sig.$name"
  exit 0
fi
cat "$STATE/sig.$name"
SHIM
  cat > "$TEST_DIR/bin/mkfs.ext4" <<'SHIM'
#!/usr/bin/env bash
echo "mkfs.ext4 $*" >> "$SHIM_LOG"
[[ "${FAKE_MKFS_RC:-0}" -ne 0 ]] && exit "$FAKE_MKFS_RC"
dev="${@: -1}"
printf 'DEVNAME=%s\nLABEL=hps-cnh\nUUID=0000\nTYPE=ext4\nUSAGE=filesystem\n' "$dev" > "$STATE/sig.${dev##*/}"
SHIM
  cat > "$TEST_DIR/bin/findmnt" <<'SHIM'
#!/usr/bin/env bash
echo "findmnt $*" >> "$SHIM_LOG"
dir="${@: -1}"
[[ -f "$STATE/mounts" ]] || exit 1
src=$(awk -v d="$dir" '$1 == d {print $2; exit}' "$STATE/mounts")
[[ -n "$src" ]] || exit 1
echo "$src"
SHIM
  cat > "$TEST_DIR/bin/mount" <<'SHIM'
#!/usr/bin/env bash
echo "mount $*" >> "$SHIM_LOG"
[[ "${FAKE_MOUNT_RC:-0}" -ne 0 ]] && exit "$FAKE_MOUNT_RC"
dir="${@: -1}"
src="${@: -2:1}"
echo "$dir $src" >> "$STATE/mounts"
SHIM
  cat > "$TEST_DIR/bin/udevadm" <<'SHIM'
#!/usr/bin/env bash
echo "udevadm $*" >> "$SHIM_LOG"
SHIM
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
out="" resume=0 url="${@: -1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out=$2; shift ;;
    --continue-at) resume=1; shift ;;
  esac
  shift
done
path="${url#http://*/}"
src="$STATE/www/$path"
[[ -f "$src" ]] || exit 22
name="${path##*/}"
if [[ $resume -eq 1 && -f "$out" ]]; then
  have=$(stat -c %s "$out")
  tail -c +"$((have + 1))" "$src" >> "$out"
  exit 0
fi
if [[ -f "$STATE/partial.$name" ]]; then
  head -c "$(cat "$STATE/partial.$name")" "$src" > "$out"
  rm -f "$STATE/partial.$name"
  exit 18
fi
cp "$src" "$out"
SHIM
  cat > "$TEST_DIR/bin/sha256sum" <<'SHIM'
#!/usr/bin/env bash
echo "sha256sum $*" >> "$SHIM_LOG"
exec /usr/bin/sha256sum "$@"
SHIM
  cat > "$TEST_DIR/bin/systemd-run" <<'SHIM'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$SHIM_LOG"
while [[ $# -gt 0 && "$1" != "--" ]]; do shift; done
shift
exec "$@"
SHIM
  cat > "$TEST_DIR/bin/podman" <<'SHIM'
#!/usr/bin/env bash
echo "podman $*" >> "$SHIM_LOG"
case "$1 ${2:-}" in
  "load --input")
    [[ "${FAKE_LOAD_RC:-0}" -ne 0 ]] && exit "$FAKE_LOAD_RC"
    printf 'Getting image source signatures\n%s\n' "${FAKE_LOADED:-Loaded image: localhost/hps-container:latest}" ;;
  "image exists") grep -qxF "$3" "$STATE/images" 2> /dev/null || exit 1 ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SHIM_LOG"
[[ "$1" == is-active ]] && exit "${FAKE_ACTIVE_RC:-0}"
exit 0
SHIM
  cat > "$TEST_DIR/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
if [[ "$*" == "-j -4 addr show dev "* ]]; then
  cat "$STATE/ipaddr.${@: -1}" 2> /dev/null || echo '[]'
fi
exit 0
SHIM
  cat > "$TEST_DIR/bin/iptables" <<'SHIM'
#!/usr/bin/env bash
echo "iptables $*" >> "$SHIM_LOG"
[[ -e "$STATE/fw" ]] || exit 1
shift  # -w
case "$1" in
  -n) exit 0 ;;
  -C) grep -qxF "$4" "$STATE/fw-rules" 2> /dev/null ;;
  -I) echo "$5" >> "$STATE/fw-rules" ;;
  -D) grep -vxF "$4" "$STATE/fw-rules" > "$STATE/fw-rules.new" || true; mv "$STATE/fw-rules.new" "$STATE/fw-rules" ;;
esac
SHIM
  cat > "$TEST_DIR/bin/df" <<'SHIM'
#!/usr/bin/env bash
echo "df $*" >> "$SHIM_LOG"
read -r avail size < "$STATE/df" 2> /dev/null || { avail=107374182400; size=214748364800; }
case "$*" in
  *--output=avail,size*) printf '    Avail   1B-blocks\n%s %s\n' "$avail" "$size" ;;
  *--output=avail*) printf '    Avail\n%s\n' "$avail" ;;
  *--output=size*) printf ' 1B-blocks\n%s\n' "$size" ;;
esac
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

# p3_171_cmds: the logged command names, space separated.
p3_171_cmds() {
  awk '{print $1}' "$SHIM_LOG" | paste -sd' ' -
}
