#!/usr/bin/env bats
#
# IPS-30: the IPS installs OpenSVC only from its own repository
# (<resources>/packages/opensvc/*.deb) and never reaches the internet
# (owner ruling 2026-11-11). The old check ran `test -s $OSVC_DEB` unquoted,
# which is true with no package, and apt-get update followed.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-183.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/functions.d/opensvc-function-helpers.sh"
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  RES="$TEST_DIR/res"
  mkdir -p "$RES/packages" "$TEST_DIR/bin"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  hps_get_config() { echo "$RES"; }
  for c in apt-get apt dpkg om; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit ${FAKE_RC:-0}\n' "$c" "$CALLS" > "$TEST_DIR/bin/$c"
    chmod +x "$TEST_DIR/bin/$c"
  done
  ORIG_PATH="$PATH"
  PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
  PATH="$ORIG_PATH"
  rm -rf "$TEST_DIR"
}

@test "no package: refused with a warning, and no apt call at all" {
  run ips_install_opensvc
  [ "$status" -eq 1 ]
  if grep -q '^apt' "$CALLS"; then return 1; fi
  if grep -q '^dpkg' "$CALLS"; then return 1; fi
  grep -q 'warn.*no package' "$TEST_DIR/hps.log"
}

@test "an empty package file counts as no package" {
  mkdir -p "$RES/packages/opensvc"
  : > "$RES/packages/opensvc/opensvc.deb"
  run ips_install_opensvc
  [ "$status" -eq 1 ]
  [ ! -s "$CALLS" ]
}

@test "a published package is installed with dpkg only, never apt" {
  mkdir -p "$RES/packages/opensvc"
  echo x > "$RES/packages/opensvc/opensvc-3.deb"
  run ips_install_opensvc
  [ "$status" -eq 0 ]
  grep -qx "dpkg -i $RES/packages/opensvc/opensvc-3.deb" "$CALLS"
  if grep -q '^apt' "$CALLS"; then return 1; fi
}

@test "dpkg failing (missing dependencies) is a failure, with no apt fallback" {
  mkdir -p "$RES/packages/opensvc"
  echo x > "$RES/packages/opensvc/opensvc-3.deb"
  FAKE_RC=1
  export FAKE_RC
  run ips_install_opensvc
  [ "$status" -eq 1 ]
  if grep -q '^apt' "$CALLS"; then return 1; fi
  grep -q 'error.*dpkg -i' "$TEST_DIR/hps.log"
}

@test "no apt-get anywhere in the IPS OpenSVC helpers" {
  run ! grep -nE '^[^#]*apt-get' "$ROOT/lib/functions.d/opensvc-function-helpers.sh"
}
