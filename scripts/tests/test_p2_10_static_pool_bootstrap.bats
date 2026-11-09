#!/usr/bin/env bats
#
# CS-2.0b: cluster-bootstrap.sh declares the static address pool
# (network_static_start/_end) and the reserved addresses (network_reserved).
# The accepted run uses the real script and registry; refusals happen before
# anything is written, so they are cheap.

common_env() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$ROOT/scripts/cluster-bootstrap.sh"
  export HPS_SYSTEM_PATH="$ROOT"
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\ntrue\n' > "$1/bin/logger"
  chmod +x "$1/bin/logger"
  export PATH="$1/bin:$PATH"
  export HPS_RESOLV_CONF="$1/resolv.conf"
  export HPS_BASE="$1/base"
  DB="$HPS_BASE/hps-config/clusters/lab/cluster.db"
  ARGS=(--name lab --dhcp-iface ens9 --network 10.100.1.0/24
        --ips-ip 10.100.1.1 --dhcp-range 10.100.1.100-10.100.1.199)
}

setup_file() {
  common_env "$BATS_FILE_TMPDIR"
  "$SCRIPT" "${ARGS[@]}" --reserve 10.100.1.2,10.100.1.10 \
    > "$BATS_FILE_TMPDIR/default.out" 2>&1
}

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-10.XXXXXX")"
  common_env "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

key() { jq -r . "$1/$2.json"; }

shared_db() { echo "$BATS_FILE_TMPDIR/base/hps-config/clusters/lab/cluster.db"; }

@test "the default pool runs from IPS+9 to the DHCP range start minus one" {
  [ "$(key "$(shared_db)" network_static_start)" = "10.100.1.10" ]
  [ "$(key "$(shared_db)" network_static_end)" = "10.100.1.99" ]
}

@test "reserved addresses are written space separated" {
  [ "$(key "$(shared_db)" network_reserved)" = "10.100.1.2 10.100.1.10" ]
}

@test "the summary prints the new keys" {
  grep -Eq 'network_static_start[[:space:]]+10.100.1.10' "$BATS_FILE_TMPDIR/default.out"
  grep -Eq 'network_static_end[[:space:]]+10.100.1.99' "$BATS_FILE_TMPDIR/default.out"
}

@test "an explicit pool is written and reserved defaults to empty" {
  run "$SCRIPT" "${ARGS[@]}" --static-range 10.100.1.20-10.100.1.40
  [ "$status" -eq 0 ]
  [ "$(key "$DB" network_static_start)" = "10.100.1.20" ]
  [ "$(key "$DB" network_static_end)" = "10.100.1.40" ]
  [ "$(key "$DB" network_reserved)" = "" ]
}

@test "help states the default rule" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--static-range"* ]]
  [[ "$output" == *"--reserve"* ]]
  [[ "$output" == *"--ips-ip + 9"* ]]
}

@test "a pool overlapping the DHCP range is refused and nothing is written" {
  run "$SCRIPT" "${ARGS[@]}" --static-range 10.100.1.50-10.100.1.100
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlaps"* ]]
  run "$SCRIPT" "${ARGS[@]}" --static-range 10.100.1.150-10.100.1.250
  [ "$status" -eq 1 ]
  [[ "$output" == *"overlaps"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "a pool containing the IPS address is refused" {
  run "$SCRIPT" "${ARGS[@]}" --static-range 10.100.1.1-10.100.1.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"contains the IPS address"* ]]
  [ ! -e "$HPS_BASE" ]
}

@test "a pool outside the network, inverted or malformed is refused" {
  local bad
  for bad in 10.100.2.10-10.100.2.20 10.100.1.50-10.100.1.10 10.100.1.10 10.100.1.10-10.100.1.255 x-y; do
    run "$SCRIPT" "${ARGS[@]}" --static-range "$bad"
    [ "$status" -eq 1 ] || { echo "accepted $bad"; return 1; }
  done
  [ ! -e "$HPS_BASE" ]
}

@test "a reserved address outside the network or malformed is refused" {
  local bad
  for bad in 10.100.2.5 10.100.1.256 not-an-ip 10.100.1.5,10.100.2.5 10.100.1.0; do
    run "$SCRIPT" "${ARGS[@]}" --reserve "$bad"
    [ "$status" -eq 1 ] || { echo "accepted $bad"; return 1; }
    [[ "$output" == *"--reserve"* ]] || { echo "$bad: $output"; return 1; }
  done
  [ ! -e "$HPS_BASE" ]
}

@test "an empty default pool is refused with a pointer to --static-range" {
  run "$SCRIPT" "${ARGS[@]}" --dhcp-range 10.100.1.5-10.100.1.50
  [ "$status" -eq 1 ]
  [[ "$output" == *"give --static-range"* ]]
  [ ! -e "$HPS_BASE" ]
}
