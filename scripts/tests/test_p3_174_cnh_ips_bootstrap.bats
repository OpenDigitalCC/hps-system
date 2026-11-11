#!/usr/bin/env bats
#
# CS-3.11: cnh-ips-bootstrap - the IPS state from the outer IPS, by manifest,
# every file verified, resumable.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

BASE=http://10.99.1.1
PIN=nixos-26.05-20261111-0123456-abcdef0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-174.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  I="$HPS_CNH_ROOT/var/lib/hps-ips"
  mkdir -p "$I"
  p3_171_mount "$I" "$HPS_CNH_ROOT/var/lib/containers/hps-ips"
  make_tree v1
  serve_world
}

teardown() {
  rm -rf "$TEST_DIR"
}

# make_tree <marker>: an hps-system tarball served at packages/cnh/.
make_tree() {
  rm -rf "$TEST_DIR/tree"
  mkdir -p "$TEST_DIR/tree/scripts" "$TEST_DIR/tree/lib"
  printf '#!/bin/bash\necho %s\n' "$1" > "$TEST_DIR/tree/scripts/run-hps.sh"
  chmod 0755 "$TEST_DIR/tree/scripts/run-hps.sh"
  mkdir -p "$STATE/www/packages/cnh"
  tar -C "$TEST_DIR/tree" -czf "$STATE/www/packages/cnh/hps-system-$1.tar.gz" .
  TARBALL="packages/cnh/hps-system-$1.tar.gz"
}

serve_world() {
  p3_171_serve "nixos/$PIN/node-base/bzImage" "kernel-node-base"
  p3_171_serve "nixos/$PIN/node-base/initrd" "initrd-node-base-0123456789"
  p3_171_serve "nixos/$PIN/SHA256SUMS" "sums"
  p3_171_serve "packages/ctrl-exec/ctrl-exec-latest.tar.gz" "ctrl-exec"
}

# entry <dest path> <url path>
entry() {
  jq -n -c --arg p "$1" --arg u "$2" --arg s "$(p3_171_sha "$STATE/www/$2")" --argjson z "$(stat -c %s "$STATE/www/$2")" \
    '{path:$p, url:$u, sha256:$s, size:$z}'
}

# publish [extra entry json...]: write the manifest; sets MSUM.
publish() {
  local files
  files=$( {
    entry hps-system.tar.gz "$TARBALL"
    entry "srv/hps-resources/nixos/$PIN/node-base/bzImage" "nixos/$PIN/node-base/bzImage"
    entry "srv/hps-resources/nixos/$PIN/node-base/initrd" "nixos/$PIN/node-base/initrd"
    entry "srv/hps-resources/nixos/$PIN/SHA256SUMS" "nixos/$PIN/SHA256SUMS"
    entry srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz packages/ctrl-exec/ctrl-exec-latest.tar.gz
    local e
    for e in "$@"; do printf '%s\n' "$e"; done
  } | jq -s -c . )
  raw_manifest "$(jq -n -c --argjson f "$files" '{schema:"hps-cnh-manifest/1", created_at:"2026-11-11T00:00:00Z", source:{}, files:$f}')"
}

# raw_manifest <json>: serve it under its own hash; sets MSUM.
raw_manifest() {
  printf '%s\n' "$1" > "$TEST_DIR/manifest.json"
  MSUM=$(p3_171_sha "$TEST_DIR/manifest.json")
  cp "$TEST_DIR/manifest.json" "$STATE/www/packages/cnh/manifest-$MSUM.json"
}

@test "fills /var/lib/hps-ips: every file verified, the tree unpacked, the srv skeleton made" {
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BOOTSTRAP $MSUM files=5 fetched=5 present=0 replaced=0" ]
  [ "$(cat "$I/srv/hps-resources/nixos/$PIN/node-base/bzImage")" = "kernel-node-base" ]
  [ "$(cat "$I/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz")" = "ctrl-exec" ]
  [ -x "$I/hps-system/scripts/run-hps.sh" ]
  grep -q 'echo v1' "$I/hps-system/scripts/run-hps.sh"
  [ "$(cat "$I/hps-system/.hps-cnh-tarball-sha256")" = "$(p3_171_sha "$I/hps-system.tar.gz")" ]
  local d
  for d in hps-config hps-resources/packages/ctrl-exec hps-resources/nixos hps-resources/nix-cache hps-resources/distros hps-resources/images hps-log ctrl-exec/conf ctrl-exec/state hps-system; do
    [ -d "$I/srv/$d" ]
  done
  [ "$(cat "$I/bootstrap/applied")" = "$MSUM" ]
  grep -qF "curl --fail --silent --show-error --proto =http --max-redirs 0 --output $I/bootstrap/manifest-$MSUM.json.part $BASE/packages/cnh/manifest-$MSUM.json" "$SHIM_LOG"
  run ! bash -c "find '$I' -name '*.part' | grep ."
}

@test "a second run fetches nothing and keeps the unpacked tree" {
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  : > "$SHIM_LOG"
  run bash "$S/cnh-ips-bootstrap" "$BASE/" "$MSUM"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "BOOTSTRAP $MSUM files=5 fetched=0 present=5 replaced=0" ]
  run ! grep -q '^curl' "$SHIM_LOG"
  run ! grep -q '^tar' "$SHIM_LOG"
  [ ! -e "$I/hps-system.prev" ]
}

@test "an interrupted transfer is resumed from its .part on the next run" {
  publish
  echo 6 > "$STATE/partial.initrd"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED srv/hps-resources/nixos/$PIN/node-base/initrd: transfer error"* ]]
  [ "$(stat -c %s "$I/srv/hps-resources/nixos/$PIN/node-base/initrd.part")" -eq 6 ]
  [ ! -e "$I/hps-system" ]
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  grep -q -- "--continue-at - --output $I/srv/hps-resources/nixos/$PIN/node-base/initrd.part" "$SHIM_LOG"
  [ "$(cat "$I/srv/hps-resources/nixos/$PIN/node-base/initrd")" = "initrd-node-base-0123456789" ]
  [ "${lines[-1]}" = "BOOTSTRAP $MSUM files=5 fetched=1 present=4 replaced=0" ]
}

@test "a file that does not match its hash is removed and fails the run (1)" {
  publish
  p3_171_serve "nixos/$PIN/node-base/bzImage" "tampered-on-the-wire"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 mismatch"* ]]
  [ ! -e "$I/srv/hps-resources/nixos/$PIN/node-base/bzImage" ]
  [ ! -e "$I/srv/hps-resources/nixos/$PIN/node-base/bzImage.part" ]
  [ ! -e "$I/bootstrap/applied" ]
}

@test "a file on disk with a different hash is replaced, and the replacement is logged" {
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  echo "edited by hand" > "$I/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replacing srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz: on disk sha256 "*", manifest sha256 "* ]]
  [ "${lines[-1]}" = "BOOTSTRAP $MSUM files=5 fetched=1 present=4 replaced=1" ]
  [ "$(cat "$I/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz")" = "ctrl-exec" ]
}

@test "a new hps-system tarball is unpacked and the old tree kept as hps-system.prev" {
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  make_tree v2
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 0 ]
  grep -q 'echo v2' "$I/hps-system/scripts/run-hps.sh"
  grep -q 'echo v1' "$I/hps-system.prev/scripts/run-hps.sh"
  [[ "$output" == *"replacing hps-system.tar.gz"* ]]
}

@test "a tarball without scripts/run-hps.sh is not unpacked (1)" {
  rm -rf "$TEST_DIR/tree"
  mkdir -p "$TEST_DIR/tree/other"
  tar -C "$TEST_DIR/tree" -czf "$STATE/www/packages/cnh/hps-system-bad.tar.gz" .
  TARBALL=packages/cnh/hps-system-bad.tar.gz
  publish
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 1 ]
  [ ! -e "$I/hps-system" ]
  [ ! -e "$I/hps-system.new" ]
}

@test "a manifest that does not match the given hash is refused (3)" {
  publish
  cp "$STATE/www/packages/cnh/manifest-$MSUM.json" "$STATE/www/packages/cnh/manifest-$(printf 'b%.0s' {1..64}).json"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$(printf 'b%.0s' {1..64})"
  [ "$status" -eq 3 ]
  [[ "$output" == *"manifest sha256 mismatch"* ]]
}

@test "manifest entries outside the allowed paths, odd urls or duplicates refuse the whole manifest (3) before any download" {
  local bad
  for bad in \
    '{"path":"../etc/passwd","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-config/system.db","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-resources/nixos/../../../x","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-resources/nixos/a/b.part","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-resources/nixos/a","url":"http://evil/x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-resources/nixos/a","url":"../x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}' \
    '{"path":"srv/hps-resources/nixos/a","url":"x","sha256":"ABC","size":1}' \
    '{"path":"srv/hps-resources/nixos/a","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":"1"}' \
    '{"path":"hps-system.tar.gz","url":"x","sha256":"'"$(printf 'a%.0s' {1..64})"'","size":1}'; do
    publish "$bad"
    : > "$SHIM_LOG"
    run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
    [ "$status" -eq 3 ]
    [ "$(grep -c '^curl' "$SHIM_LOG")" -eq 1 ]
  done
}

@test "a manifest of the wrong schema or without the tarball is refused (3)" {
  raw_manifest '{"schema":"other/1","files":[]}'
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 3 ]
  raw_manifest "$(jq -n -c --argjson e "$(entry srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz packages/ctrl-exec/ctrl-exec-latest.tar.gz)" '{schema:"hps-cnh-manifest/1", files:[$e]}')"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no hps-system.tar.gz"* ]]
}

@test "only this node's IPS, plain http and no path in the base (3); the disk must be mounted (3)" {
  local b
  publish
  for b in http://10.99.1.2 https://10.99.1.1 http://10.99.1.1/packages "http://user@10.99.1.1" ftp://10.99.1.1; do
    run bash "$S/cnh-ips-bootstrap" "$b" "$MSUM"
    [ "$status" -eq 3 ]
  done
  run ! grep -q '^curl' "$SHIM_LOG"
  run bash "$S/cnh-ips-bootstrap" "http://10.99.1.1:80" "$MSUM"
  [ "$status" -eq 0 ]
  rm -f "$STATE/mounts"
  run bash "$S/cnh-ips-bootstrap" "$BASE" "$MSUM"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cnh-disk-prepare"* ]]
}

@test "usage errors exit 2" {
  run bash "$S/cnh-ips-bootstrap"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-bootstrap" "$BASE"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-bootstrap" --base "$BASE" x
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-bootstrap" "$BASE" ABC
  [ "$status" -eq 3 ]
}
