# Helpers for the image builder tests (test_p3_202_*, test_p3_203_*).
# Load after p2_30_helpers and p3_171_helpers: the container-host shims
# (findmnt, mount, curl, sha256sum, systemd-run, udevadm) and their state
# files, with blkid, mkfs.ext4 and systemctl replaced for the builder:
#   labelled          devices blkid -t LABEL=hps-builder lists, one per line
#   unit-state        what systemctl show -p ActiveState reports (default inactive)

p3_202_setup() {
  p3_171_setup
  export HPS_BUILDER_ROOT="$TEST_DIR/root"
  export HPS_BUILDER_SETTLE=0
  export MNT="$HPS_BUILDER_ROOT/var/lib/hps-builder"
  cat > "$TEST_DIR/bin/blkid" <<'SHIM'
#!/usr/bin/env bash
echo "blkid $*" >> "$SHIM_LOG"
if [[ "$*" == *"-t LABEL=hps-builder"* ]]; then
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
dev="${@: -1}"
printf 'DEVNAME=%s\nLABEL=hps-builder\nUUID=0000\nTYPE=ext4\nUSAGE=filesystem\n' "$dev" > "$STATE/sig.${dev##*/}"
SHIM
  cat > "$TEST_DIR/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SHIM_LOG"
if [[ "$1" == show ]]; then
  cat "$STATE/unit-state" 2> /dev/null || echo inactive
fi
exit 0
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

# p3_202_blank <name>: a blank fake device.
p3_202_blank() {
  p3_171_disk "$1"
}

# p3_202_prepared: a mounted builder disk (vdb) with its directories.
p3_202_prepared() {
  p3_171_disk vdb
  printf 'DEVNAME=%s\nLABEL=hps-builder\nTYPE=ext4\n' "$HPS_DEV/vdb" > "$STATE/sig.vdb"
  p3_171_mount "$MNT" "$HPS_DEV/vdb"
  mkdir -p "$MNT"/{root,out,cache,src,inputs,state,tmp}
}

# p3_202_source <dir>: a tarball of <dir> served as
# packages/cnh/hps-system-<sha16>.tar.gz; prints its sha256.
p3_202_source() {
  local dir="$1" tar sum
  tar="$TEST_DIR/src.tar.gz"
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -I 'gzip -n' -C "$dir" -cf "$tar" .
  sum=$(p3_171_sha "$tar")
  mkdir -p "$STATE/www/packages/cnh"
  cp "$tar" "$STATE/www/packages/cnh/hps-system-${sum:0:16}.tar.gz"
  printf '%s\n' "$sum"
}

# p3_202_input <name> <dir>: as p3_202_source, served as packages/builder/<name>-<sha16>.tar.gz.
p3_202_input() {
  local name="$1" dir="$2" tar sum
  tar="$TEST_DIR/$name.tar.gz"
  tar -I 'gzip -n' -C "$dir" -cf "$tar" .
  sum=$(p3_171_sha "$tar")
  mkdir -p "$STATE/www/packages/builder"
  cp "$tar" "$STATE/www/packages/builder/$name-${sum:0:16}.tar.gz"
  printf '%s\n' "$sum"
}
