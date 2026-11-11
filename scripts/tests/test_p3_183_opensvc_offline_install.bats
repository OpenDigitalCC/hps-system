#!/usr/bin/env bats
#
# IPS-30: the IPS never installs OpenSVC and never reaches the internet for it
# (owner ruling 2026-11-11). The install path (ensure_opensvc_installed,
# ips_install_opensvc: apt-get update against deb.debian.org) is removed; om3
# is built in the flake and runs on the nodes.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-183.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  source "$ROOT/lib/functions.d/opensvc-function-helpers.sh"
  source "$ROOT/lib/functions.d/opensvc-functions.sh"
  export CALLS="$TEST_DIR/calls.log"
  : > "$CALLS"
  mkdir -p "$TEST_DIR/bin"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  _osvc_setup_directories() { echo dirs >> "$CALLS"; }
  _osvc_create_conf() { echo conf >> "$CALLS"; }
  for c in apt-get apt dpkg; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$TEST_DIR/bin/$c"
    chmod +x "$TEST_DIR/bin/$c"
  done
  ORIG_PATH="$PATH"
}

teardown() {
  PATH="$ORIG_PATH"
  rm -rf "$TEST_DIR"
}

@test "no om on the IPS: osvc_prepare_cluster succeeds, prepares nothing, installs nothing" {
  # shellcheck disable=SC2123  # om must not be found
  PATH="$TEST_DIR/bin"
  run osvc_prepare_cluster
  PATH="$ORIG_PATH"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  grep -q 'om not on this IPS' "$TEST_DIR/hps.log"
}

@test "om present: the IPS-side preparation still runs" {
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/bin/om"
  chmod +x "$TEST_DIR/bin/om"
  PATH="$TEST_DIR/bin:$ORIG_PATH"
  run osvc_prepare_cluster
  PATH="$ORIG_PATH"
  [ "$status" -eq 0 ]
  grep -qx dirs "$CALLS"
  grep -qx conf "$CALLS"
  if grep -qE '^(apt|dpkg)' "$CALLS"; then return 1; fi
}

@test "the install functions are gone" {
  run ! declare -F ensure_opensvc_installed
  run ! declare -F ips_install_opensvc
}

@test "no apt-get, dpkg or packages/opensvc anywhere in the IPS OpenSVC code" {
  run ! grep -nE '^[^#]*(apt-get|dpkg|packages/opensvc)' \
    "$ROOT/lib/functions.d/opensvc-function-helpers.sh" "$ROOT/lib/functions.d/opensvc-functions.sh"
}
