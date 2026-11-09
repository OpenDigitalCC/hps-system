#!/usr/bin/env bats
#
# CS-2.1: storage-trim-check. Proves the verdict on the last line both ways
# (TRIM OK / TRIM NOT REACHING <disk>), the exit codes, the commands run.

bats_require_minimum_version 1.5.0
load p2_30_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-34.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_disks
  p2_shim_zpool
  SCRIPT="$S/storage-trim-check"
  touch "$STATE/pool-imported"
  printf '\tmirror-0\n\t  /dev/disk/by-id/%s-part1  ONLINE\n\t  /dev/disk/by-id/%s-part1  ONLINE\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-pool"
  printf '\t    %s-part1  ONLINE  0 0 0  (100%% trimmed, completed at Mon Nov  9 12:00:00 2026)\n\t    %s-part1  ONLINE  0 0 0  (100%% trimmed, completed at Mon Nov  9 12:00:00 2026)\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-t"
}

teardown() {
  rm -rf "$TEST_DIR"
}

last_line() {
  printf '%s\n' "$output" | tail -n 1
}

@test "is executable, env shebang, set -euo pipefail, shellcheck clean" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
}

@test "usage 2, bad name 3, pool not imported 3" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" 'a;b'
  [ "$status" -eq 3 ]
  rm "$STATE/pool-imported"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  run ! grep -q 'zpool trim' "$SHIM_LOG"
}

@test "TRIM OK on the last line, exit 0; lsblk -D, trim -w and status -t all ran" {
  run bash "$SCRIPT" lab
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "TRIM OK" ]
  grep -q '^lsblk -D .*-o NAME,DISC-GRAN,DISC-MAX /dev/disk/by-id/'"$P2_DISK_A" "$SHIM_LOG"
  grep -q '^lsblk -D .*-o NAME,DISC-GRAN,DISC-MAX /dev/disk/by-id/'"$P2_DISK_B" "$SHIM_LOG"
  grep -qxF 'zpool trim -w lab' "$SHIM_LOG"
  grep -qxF 'zpool status -t lab' "$SHIM_LOG"
}

@test "a disk that advertises no discard: TRIM NOT REACHING <disk>, exit 3" {
  echo "$P2_DISK_B-part1 0 0" > "$STATE/lsblk-d.$P2_DISK_B-part1"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [ "$(last_line)" = "TRIM NOT REACHING $P2_DISK_B" ]
}

@test "a vdev that status -t reports untrimmed or unsupported: not reaching, exit 3" {
  printf '\t    %s-part1  ONLINE  0 0 0  (100%% trimmed, completed at x)\n\t    %s-part1  ONLINE  0 0 0  (untrimmed)\n' "$P2_DISK_A" "$P2_DISK_B" > "$STATE/status-t"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [ "$(last_line)" = "TRIM NOT REACHING $P2_DISK_B" ]
  printf '\t    %s-part1  ONLINE  0 0 0  (trim unsupported)\n' "$P2_DISK_A" > "$STATE/status-t"
  run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [ "$(last_line)" = "TRIM NOT REACHING $P2_DISK_A" ]
}

@test "a failing zpool trim is not OK (3)" {
  FAKE_TRIM_RC=1 run bash "$SCRIPT" lab
  [ "$status" -eq 3 ]
  [[ "$(last_line)" == "TRIM NOT REACHING "* ]]
}

@test "the check writes nothing but the trim itself" {
  run bash "$SCRIPT" lab
  run ! grep -E '^(zpool (create|destroy|labelclear|import|export)|zfs |wipefs)' "$SHIM_LOG"
}
