#!/usr/bin/env bats
#
# CS-2.0b: scripts/nixos-prune-pins.sh against a fixture pin tree and a fake
# function library standing in for the registry.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-12.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/scripts/nixos-prune-pins.sh"
  PINS="$TEST_DIR/res/nixos"
  mkdir -p "$TEST_DIR/sys/lib"
  # hosts file: "<mac> <system_pin> <system_pin_previous>" per line
  : > "$TEST_DIR/hosts"
  echo "" > "$TEST_DIR/default_pin"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOF2
hps_log() { :; }
hps_get_config() {
  case "\$1" in
    resources) echo "$TEST_DIR/res" ;;
    active_cluster) echo lab ;;
  esac
}
cluster_registry() { cat "$TEST_DIR/default_pin"; }
list_cluster_hosts() { awk '{print \$1}' "$TEST_DIR/hosts"; }
host_registry() {
  case "\$3" in
    system_pin) awk -v m="\$1" '\$1==m {print \$2}' "$TEST_DIR/hosts" ;;
    system_pin_previous) awk -v m="\$1" '\$1==m {print \$3}' "$TEST_DIR/hosts" ;;
  esac
}
EOF2
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
  for p in pin-old pin-older pin-prev pin-host pin-default pin-latest pin-new; do
    mkdir -p "$PINS/$p/audit"
    echo '{}' > "$PINS/$p/audit/boot.json"
  done
  echo pin-latest > "$PINS/latest"
  # mtimes: pin-older oldest ... pin-new newest
  touch -d '2026-11-01' "$PINS/pin-older"
  touch -d '2026-11-02' "$PINS/pin-old"
  touch -d '2026-11-03' "$PINS/pin-prev"
  touch -d '2026-11-04' "$PINS/pin-host"
  touch -d '2026-11-05' "$PINS/pin-default"
  touch -d '2026-11-06' "$PINS/pin-new"
  touch -d '2026-11-07' "$PINS/pin-latest"
  echo "525400000001 pin-host pin-prev" > "$TEST_DIR/hosts"
  echo pin-default > "$TEST_DIR/default_pin"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "script is executable with the env shebang" {
  [ -x "$SCRIPT" ]
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
}

@test "dry run is the default, lists the unreferenced pins and changes nothing" {
  find "$TEST_DIR/res" | sort > "$TEST_DIR/before"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove pin-old"* ]]
  [[ "$output" == *"would remove pin-older"* ]]
  [[ "$output" == *"would remove pin-new"* ]]
  find "$TEST_DIR/res" | sort > "$TEST_DIR/after"
  diff "$TEST_DIR/before" "$TEST_DIR/after"
}

@test "explicit --dry-run changes nothing" {
  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [ -d "$PINS/pin-old" ]
}

@test "referenced pins are kept and say why" {
  run "$SCRIPT"
  [[ "$output" == *"keep      pin-latest (latest)"* ]]
  [[ "$output" == *"keep      pin-host (system_pin of 525400000001)"* ]]
  [[ "$output" == *"keep      pin-prev (system_pin_previous of 525400000001)"* ]]
  [[ "$output" == *"keep      pin-default (cluster nixos_default_pin)"* ]]
}

@test "apply removes only the unreferenced pins" {
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ ! -e "$PINS/pin-old" ]
  [ ! -e "$PINS/pin-older" ]
  [ ! -e "$PINS/pin-new" ]
  [ -d "$PINS/pin-latest" ]
  [ -d "$PINS/pin-host" ]
  [ -d "$PINS/pin-prev" ]
  [ -d "$PINS/pin-default" ]
  [ "$(cat "$PINS/latest")" = "pin-latest" ]
}

@test "--keep n also keeps the n newest unreferenced pins" {
  run "$SCRIPT" --apply --keep 2
  [ "$status" -eq 0 ]
  [ -d "$PINS/pin-new" ]
  [ -d "$PINS/pin-old" ]
  [ ! -e "$PINS/pin-older" ]
}

@test "a pin two hosts name survives and several hosts are all read" {
  echo "525400000002 pin-old pin-older" >> "$TEST_DIR/hosts"
  run "$SCRIPT" --apply
  [ -d "$PINS/pin-old" ]
  [ -d "$PINS/pin-older" ]
  [ ! -e "$PINS/pin-new" ]
}

@test "refuses when latest is missing and removes nothing" {
  rm "$PINS/latest"
  run "$SCRIPT" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"latest"* ]]
  [ -d "$PINS/pin-old" ]
}

@test "refuses when latest is empty or names a missing pin" {
  : > "$PINS/latest"
  run "$SCRIPT" --apply
  [ "$status" -eq 1 ]
  echo pin-gone > "$PINS/latest"
  run "$SCRIPT" --apply
  [ "$status" -eq 1 ]
  [ -d "$PINS/pin-old" ]
}

@test "directories that are not pin names are left alone" {
  mkdir -p "$PINS/Not_A_Pin"
  run "$SCRIPT" --apply
  [ "$status" -eq 0 ]
  [ -d "$PINS/Not_A_Pin" ]
  [[ "$output" == *"skipped   Not_A_Pin"* ]]
}

@test "bad options are usage errors" {
  run "$SCRIPT" --apply --dry-run
  [ "$status" -eq 2 ]
  run "$SCRIPT" --keep x
  [ "$status" -eq 2 ]
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}

@test "fails clearly when the function library is missing" {
  HPS_SYSTEM_PATH="$TEST_DIR/none" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"function library not found"* ]]
}
