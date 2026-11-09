#!/usr/bin/env bats
#
# CS-1.10: node-manager/nixos-26/scripts/storage-pool-inspect with zpool and zfs
# shims. Proves: argument and pool-name refusals, the already-imported refusal
# (and --already-imported inspecting in place without exporting), the read-only
# import flags (readonly=on, -N, never -f), -m only with --import-missing-log,
# the export on every exit (including a failing zfs command), no write verbs,
# and every command logged.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-100.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  SCRIPT="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts/storage-pool-inspect"
  mkdir -p "$TEST_DIR/bin"
  export PATH="$TEST_DIR/bin:$PATH"

  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
case "$1" in
  list) exit "${FAKE_ZPOOL_LIST_RC:-1}" ;;
  import)
    if [[ $# -eq 1 ]]; then
      echo "   pool: tank"
      exit 0
    fi
    exit "${FAKE_IMPORT_RC:-0}" ;;
  status) echo "  pool: tank state: ONLINE" ;;
  get)
    printf 'tank\tsize\t928G\t-\n'
    printf 'tank\tallocated\t100G\t-\n'
    printf 'tank\tfree\t828G\t-\n'
    printf 'tank\tashift\t12\tlocal\n'
    printf 'tank\tautotrim\ton\tlocal\n'
    printf 'tank\thealth\tONLINE\t-\n'
    printf 'tank\tfeature@encryption\tactive\tlocal\n'
    printf 'tank\tcomment\tSHOULD-NOT-APPEAR\t-\n' ;;
  export) exit "${FAKE_EXPORT_RC:-0}" ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/zfs" <<'SHIM'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
case "$1" in
  list)
    if [[ "$*" == *"-t snapshot"* ]]; then
      [[ "${FAKE_ZFS_FAIL:-}" == snapshots ]] && exit 1
      n="${FAKE_SNAPS:-3}"
      i=1
      while [[ $i -le $n ]]; do
        printf 'tank/data@s%03d\t1M\tMon Nov  9 12:00 2026\n' "$i"
        i=$((i + 1))
      done
    else
      [[ "${FAKE_ZFS_FAIL:-}" == datasets ]] && exit 1
      echo "tank 100G 96K 800G /tank off lz4"
    fi ;;
  get) echo "tank	compression	lz4" ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable, env shebang, set -euo pipefail" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  grep -q '^set -euo pipefail' "$SCRIPT"
}

@test "no pool name is a usage error (2) and touches no zfs command" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "an unknown option or a second pool name is a usage error (2)" {
  run bash "$SCRIPT" tank --force
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" tank other
  [ "$status" -eq 2 ]
  [ ! -s "$SHIM_LOG" ]
}

@test "refuses a pool name outside ^[a-z][a-z0-9_.-]*\$ (3) before any command" {
  for bad in Tank 1tank 'tank;ls' 'tank/child' 'tank$x' 'a b'; do
    run bash "$SCRIPT" "$bad"
    [ "$status" -eq 3 ]
  done
  [ ! -s "$SHIM_LOG" ]
}

@test "refuses a pool that is already imported (3) without importing or exporting" {
  FAKE_ZPOOL_LIST_RC=0 run bash "$SCRIPT" tank
  [ "$status" -eq 3 ]
  [[ "$output" == *"already imported"* ]]
  grep -qx 'zpool list -H tank' "$SHIM_LOG"
  ! grep -q '^zpool import' "$SHIM_LOG"
  ! grep -q '^zpool export' "$SHIM_LOG"
}

@test "--already-imported inspects in place and never imports or exports" {
  FAKE_ZPOOL_LIST_RC=0 run bash "$SCRIPT" tank --already-imported
  [ "$status" -eq 0 ]
  grep -qx 'zpool status tank' "$SHIM_LOG"
  ! grep -q '^zpool import' "$SHIM_LOG"
  ! grep -q '^zpool export' "$SHIM_LOG"
}

@test "--already-imported on a pool that is not imported is refused (3)" {
  run bash "$SCRIPT" tank --already-imported
  [ "$status" -eq 3 ]
}

@test "lists importable pools, imports read-only with -N, inspects, then exports" {
  run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  grep -qx 'zpool import' "$SHIM_LOG"
  grep -qx 'zpool import -o readonly=on -N tank' "$SHIM_LOG"
  grep -qx 'zpool status tank' "$SHIM_LOG"
  grep -qx 'zpool get -H all tank' "$SHIM_LOG"
  grep -qx 'zfs list -o name,used,refer,avail,mountpoint,encryption,compression -r tank' "$SHIM_LOG"
  grep -qx 'zfs get -H -o name,property,value -r -s local all tank' "$SHIM_LOG"
  [ "$(tail -n 1 "$SHIM_LOG")" = "zpool export tank" ]
}

@test "never forces, mounts or writes: no -f, no mount, no zfs set, no other write verb" {
  run bash "$SCRIPT" tank --import-missing-log
  [ "$status" -eq 0 ]
  ! grep -qE ' -f( |$)' "$SHIM_LOG"
  ! grep -qE '^zfs (set|mount|create|destroy|rollback|snapshot|send|receive)' "$SHIM_LOG"
  ! grep -qE '^zpool (create|destroy|add|remove|attach|detach|scrub|clear|set|labelclear|upgrade)' "$SHIM_LOG"
  ! grep -qE 'mount|wipefs|dd |mkfs' "$SHIM_LOG"
  run bash -c "grep -v '^ *#' '$SCRIPT' | grep -nE '(^| )-[A-Za-z]*f[A-Za-z]*( |\$)'"
  [ "$status" -eq 1 ]
}

@test "-m is passed only with --import-missing-log" {
  run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  ! grep -qE '^zpool import .* -m' "$SHIM_LOG"
  : > "$SHIM_LOG"
  run bash "$SCRIPT" tank --import-missing-log
  [ "$status" -eq 0 ]
  grep -qx 'zpool import -o readonly=on -N -m tank' "$SHIM_LOG"
}

@test "exports even when a zfs command fails part-way (datasets, then snapshots)" {
  FAKE_ZFS_FAIL=datasets run bash "$SCRIPT" tank
  [ "$status" -eq 1 ]
  grep -qx 'zpool export tank' "$SHIM_LOG"
  ! grep -q 'snapshot' "$SHIM_LOG"
  : > "$SHIM_LOG"
  FAKE_ZFS_FAIL=snapshots run bash "$SCRIPT" tank
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$SHIM_LOG")" = "zpool export tank" ]
}

@test "a failed import is reported (1) and nothing is exported" {
  FAKE_IMPORT_RC=1 run bash "$SCRIPT" tank
  [ "$status" -eq 1 ]
  [[ "$output" == *"import of tank failed"* ]]
  ! grep -q '^zpool export' "$SHIM_LOG"
  ! grep -q '^zpool status' "$SHIM_LOG"
}

@test "prints only the selected pool properties" {
  run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"928G"* ]]
  [[ "$output" == *"feature@encryption"* ]]
  [[ "$output" != *"SHOULD-NOT-APPEAR"* ]]
}

@test "snapshots: total count and only the last 50 shown" {
  FAKE_SNAPS=120 run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"snapshots total: 120"* ]]
  [[ "$output" == *"tank/data@s120"* ]]
  [[ "$output" == *"tank/data@s071"* ]]
  [[ "$output" != *"tank/data@s070"* ]]
}

@test "no snapshots: count 0, still exits 0" {
  FAKE_SNAPS=0 run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"snapshots total: 0"* ]]
}

@test "logs every command as it runs" {
  run bash "$SCRIPT" tank
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ zpool import -o readonly=on -N tank"* ]]
  [[ "$output" == *"+ zpool status tank"* ]]
  [[ "$output" == *"+ zpool export tank"* ]]
}
