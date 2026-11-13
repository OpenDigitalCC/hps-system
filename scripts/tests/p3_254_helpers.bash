# Helpers for the I/O discovery tests (test_p3_254_* .. test_p3_256_*): a dd that
# logs its real arguments and then runs the real dd on files, with direct I/O
# (not available on a tmpfs test directory) taken out of the flags it is given.
#   FAKE_DD_FAIL_OF  a substring: a dd whose of= contains it exits 1 (nothing written)
# A script's /dev/disk/by-id/X in if= or of= is read as $HPS_DEV/disk/by-id/X.
# HPS_DEV is $TEST_DIR/dev, so /dev/disk/by-id/X of a script is a plain file.

p3_254_setup() {
  p2_setup_dirs
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_IO_TMP="$TEST_DIR/tmp"
  export HPS_IO_MIB=4
  export HPS_IO_SYNC_COUNT=5
  export HPS_IO_WAIT=2
  mkdir -p "$HPS_DEV/disk/by-id" "$HPS_DEV/zvol"
  S="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts"
  cat > "$TEST_DIR/bin/dd" <<'SHIM'
#!/usr/bin/env bash
echo "dd $*" >> "$SHIM_LOG"
args=()
for a in "$@"; do
  a="${a/#if=\/dev\/disk\/by-id\//if=$HPS_DEV/disk/by-id/}"
  a="${a/#of=\/dev\/disk\/by-id\//of=$HPS_DEV/disk/by-id/}"
  if [[ -n "${FAKE_DD_FAIL_OF:-}" && "$a" == of=*"$FAKE_DD_FAIL_OF"* ]]; then
    echo "dd: failing write to ${a#of=}: Input/output error" >&2
    exit 1
  fi
  case "$a" in
    oflag=direct | iflag=direct) ;;
    oflag=direct,dsync) args+=(oflag=dsync) ;;
    *) args+=("$a") ;;
  esac
done
exec /usr/bin/dd "${args[@]}"
SHIM
  chmod +x "$TEST_DIR/bin/dd"
}

# p3_254_disk <by-id>: a 16 MiB stand-in for a whole disk.
p3_254_disk() {
  head -c 16777216 /dev/zero > "$HPS_DEV/disk/by-id/$1"
}
