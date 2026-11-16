#!/usr/bin/env bats
#
# storage-zfs-set: sync and logbias on <pool>/enc and the zvols under it, nothing
# else and nowhere else; idempotent; the resulting properties are the last
# stdout lines. Also the --sync/--logbias options of storage-zvol-create and
# storage-pool-create's enc dataset (the cluster's policy for new zvols), and
# the allowlist entry.

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p2_70_helpers

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-75.XXXXXX")"
  export TEST_DIR
  p2_setup_dirs
  p2_shim_zfs_zvol
  SCRIPT="$S/storage-zfs-set"
  echo available > "$STATE/keystatus"
  printf 'lab/enc\nlab/enc/vm\n' > "$STATE/datasets"
  printf 'lab/enc/t0 1073741824\nlab/enc/vm/g1-root 1073741824\n' > "$STATE/zvols"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail, one run() logger, shellcheck clean, allowlisted under profile node" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
  grep -q '^run() {' "$SCRIPT"
  run ! grep -E '^[[:space:]]*(source|\.) ' "$SCRIPT"
  shellcheck -S warning "$SCRIPT"
  local nix="$BATS_TEST_DIRNAME/../../nix/modules/hps-ctrl-exec.nix"
  grep -qF 'storage-zfs-set.source = mkScript "storage-zfs-set" (scriptsDir + "/storage-zfs-set");' "$nix"
  grep -qF 'storage-zfs-set.options.profile = "node";' "$nix"
}

@test "usage: no dataset, no property, an option: exit 2, nothing runs" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" lab/enc/t0
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --force lab/enc/t0 sync=disabled
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "a pool root or a dataset outside <pool>/enc is refused (3) before any command" {
  local d
  for d in lab lab/t0 lab/other/x Lab/enc/t0 /lab/enc/t0 'lab/enc/../x' lab/enc/a/b 'lab/enc/t0;x' lab/enc/vm/a/b lab/enc/; do
    run bash "$SCRIPT" "$d" sync=disabled
    [ "$status" -eq 3 ] || { echo "accepted: [$d]"; false; }
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "only sync and logbias with their values are accepted; anything else is refused before any command" {
  local p
  for p in sync=on sync=off sync= =disabled sync compression=off volsize=2G 'sync=disabled;x' 'sync=disabled logbias=x' readonly=on mountpoint=/x; do
    run bash "$SCRIPT" lab/enc/t0 "$p"
    [ "$status" -eq 3 ] || { echo "accepted: [$p]"; false; }
  done
  run bash "$SCRIPT" lab/enc/t0 sync=disabled sync=standard
  [ "$status" -eq 3 ]
  [[ "$output" == *"given twice"* ]]
  [ ! -s "$SHIM_LOG" ]
}

@test "a dataset that does not exist is refused (3), nothing set" {
  run --separate-stderr bash "$SCRIPT" lab/enc/nope sync=disabled
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"does not exist"* ]]
  run ! grep -q '^zfs set' "$SHIM_LOG"
}

@test "sets sync and logbias on a zvol in one zfs set; the resulting zfs get is the last stdout lines" {
  run --separate-stderr bash "$SCRIPT" lab/enc/vm/g1-root sync=disabled logbias=throughput
  [ "$status" -eq 0 ]
  grep -qxF 'zfs set sync=disabled logbias=throughput lab/enc/vm/g1-root' "$SHIM_LOG"
  [ "$(grep -c '^zfs set' "$SHIM_LOG")" -eq 1 ]
  [ "${lines[-2]}" = $'lab/enc/vm/g1-root\tsync\tdisabled\tlocal' ]
  [ "${lines[-1]}" = $'lab/enc/vm/g1-root\tlogbias\tthroughput\tlocal' ]
  [[ "$stderr" == *"+ zfs set sync=disabled logbias=throughput lab/enc/vm/g1-root"* ]]
}

@test "<pool>/enc and <pool>/enc/vm (the parents) are accepted" {
  run bash "$SCRIPT" lab/enc sync=disabled
  [ "$status" -eq 0 ]
  grep -qxF 'zfs set sync=disabled lab/enc' "$SHIM_LOG"
  run bash "$SCRIPT" lab/enc/vm logbias=throughput
  [ "$status" -eq 0 ]
  grep -qxF 'zfs set logbias=throughput lab/enc/vm' "$SHIM_LOG"
}

@test "idempotent: a property already at the value is not set again; a mixed call sets only the other" {
  bash "$SCRIPT" lab/enc/t0 sync=disabled logbias=throughput > /dev/null 2>&1
  : > "$SHIM_LOG"
  run --separate-stderr bash "$SCRIPT" lab/enc/t0 sync=disabled logbias=throughput
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"nothing to change"* ]]
  [ "${lines[-2]}" = $'lab/enc/t0\tsync\tdisabled\tlocal' ]
  run ! grep -q '^zfs set' "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$SCRIPT" lab/enc/t0 sync=standard logbias=throughput
  [ "$status" -eq 0 ]
  grep -qxF 'zfs set sync=standard lab/enc/t0' "$SHIM_LOG"
  [ "$(grep -c '^zfs set' "$SHIM_LOG")" -eq 1 ]
}

@test "a failing zfs set exits 1" {
  FAKE_ZFS_SET_RC=1 run bash "$SCRIPT" lab/enc/t0 sync=disabled
  [ "$status" -eq 1 ]
}

@test "no destroy, create, rollback, rename or zpool anywhere in the script" {
  run ! grep -E 'zfs (destroy|rollback|create|rename|snapshot)|zpool ' "$SCRIPT"
}

#--- the create-time policy

@test "storage-zvol-create --sync/--logbias become -o on the create; without them nothing is added" {
  : > "$STATE/zvols"
  run bash "$S/storage-zvol-create" lab/enc/vm/g2-root 1G --sync disabled --logbias throughput
  [ "$status" -eq 0 ]
  grep -qxF 'zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 -o sync=disabled -o logbias=throughput lab/enc/vm/g2-root' "$SHIM_LOG"
  run bash "$S/storage-zvol-create" lab/enc/t1 1G --logbias throughput
  [ "$status" -eq 0 ]
  grep -qxF 'zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 -o logbias=throughput lab/enc/t1' "$SHIM_LOG"
  run bash "$S/storage-zvol-create" lab/enc/t2 1G
  [ "$status" -eq 0 ]
  grep -qxF 'zfs create -V 1G -s -o volblocksize=16k -o compression=lz4 lab/enc/t2' "$SHIM_LOG"
}

@test "storage-zvol-create refuses a --sync or --logbias value outside the enum (3), a missing value is usage (2)" {
  : > "$SHIM_LOG"
  run bash "$S/storage-zvol-create" lab/enc/t3 1G --sync off
  [ "$status" -eq 3 ]
  run bash "$S/storage-zvol-create" lab/enc/t3 1G --logbias fast
  [ "$status" -eq 3 ]
  run bash "$S/storage-zvol-create" lab/enc/t3 1G --sync
  [ "$status" -eq 2 ]
  run ! grep -q '^zfs create' "$SHIM_LOG"
}

@test "storage-zvol-create leaves an existing zvol's properties alone (same size: no change)" {
  run --separate-stderr bash "$S/storage-zvol-create" lab/enc/t0 1G --sync disabled
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"already exists"* ]]
  run ! grep -E '^zfs (create|set)' "$SHIM_LOG"
}
