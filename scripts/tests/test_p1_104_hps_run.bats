#!/usr/bin/env bats
#
# CS-1.10: scripts/hps-run.sh resolves a MAC (any format) or a registry HOSTNAME
# to the ctrl-exec agent name and runs `ced run <agent> <script> -- args`,
# passing output and exit code through. The function library is a fake tree
# holding a file-backed registry; ce_run is the real one, over a ced shim.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-104.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RUN="$ROOT/scripts/hps-run.sh"
  mkdir -p "$TEST_DIR/sys/lib" "$TEST_DIR/hosts"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOF
# the real name helpers first; the stubs below replace the registry accessors
source "$ROOT/lib/functions.d/host-functions.sh"
hps_log() { :; }
normalise_mac() {
  local m="\${1//[:.-]/}"
  m="\${m,,}"
  [[ "\$m" =~ ^[0-9a-f]{12}\$ ]] || return 1
  echo "\$m"
}
host_registry() {
  local d="$TEST_DIR/hosts/\$1"
  case "\$2" in
    exists) [[ -d "\$d" ]] ;;
    get) [[ -f "\$d/\$3" ]] && cat "\$d/\$3" ;;
  esac
}
get_host_mac_by_keyvalue() {
  local f
  for f in "$TEST_DIR"/hosts/*/"\$1"; do
    [[ -f "\$f" && "\$(cat "\$f")" == "\$2" ]] && basename "\$(dirname "\$f")"
  done | head -n 1 | grep .
}
hps_get_config() { [[ "\$1" == active_cluster ]] && echo lab; }
cluster_registry() { [[ -f "$TEST_DIR/domain" ]] && cat "$TEST_DIR/domain"; }
source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
EOF
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CE_LOG"
if [[ "$1" == list-agents ]]; then
  printf 'HOSTNAME  IP  PORT\n----\n'
  cat "$TEST_DIR/agents"
  exit 0
fi
echo "ced-stdout"
echo "ced-stderr" >&2
exit "${FAKE_CED_RC:-0}"
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER"
  printf 'held01.lab.hps  10.0.0.5  7443\nhps-112233445566.lab.hps  10.0.0.6  7443\nheld01  10.0.0.7  7443\n' > "$TEST_DIR/agents"
  echo -n lab.hps > "$TEST_DIR/domain"
  mkdir -p "$TEST_DIR/hosts/aabbccddeeff" "$TEST_DIR/hosts/112233445566"
  echo -n held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "is executable with the env shebang" {
  [ -x "$RUN" ]
  [ "$(head -1 "$RUN")" = "#!/usr/bin/env bash" ]
}

@test "needs a target and a script (2)" {
  run bash "$RUN"
  [ "$status" -eq 2 ]
  run bash "$RUN" aabbccddeeff
  [ "$status" -eq 2 ]
  [ ! -e "$CE_LOG" ]
}

@test "a MAC in any format resolves to the registry HOSTNAME as the agent name" {
  for m in aabbccddeeff AA:BB:CC:DD:EE:FF aa-bb-cc-dd-ee-ff aabb.ccdd.eeff; do
    : > "$CE_LOG"
    run bash "$RUN" "$m" node-facts
    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.hps node-facts" ]
  done
}

@test "a hostname resolves through the registry to the same agent" {
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.hps node-facts" ]
}

@test "arguments follow -- exactly as given" {
  run bash "$RUN" held01 storage-pool-inspect tank --import-missing-log
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.hps storage-pool-inspect -- tank --import-missing-log" ]
}

@test "the FQDN is the one agent name: a short-name registration is not used" {
  printf 'held01  10.0.0.7  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 4 ]
  [[ "$output" == *"expected the FQDN held01.lab.hps"* ]]
  ! grep -q "^run" "$CE_LOG"
}

@test "a hostname given as its FQDN resolves to the same host" {
  run bash "$RUN" held01.lab.hps node-facts
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.hps node-facts" ]
}

@test "an FQDN over 63 characters is refused (1) and ced is not run" {
  printf 'd%.0s' {1..60} > "$TEST_DIR/domain"
  run bash "$RUN" held01 node-facts
  [ "$status" -eq 1 ]
  [[ "$output" == *"limit is 63"* ]]
  ! grep -q "^run" "$CE_LOG"
}

@test "a MAC whose host has no HOSTNAME uses the hps-<mac> fallback agent name" {
  run bash "$RUN" 11:22:33:44:55:66 node-dmesg hpsa
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CE_LOG")" = "run hps-112233445566.lab.hps node-dmesg -- hpsa" ]
}

@test "an unknown MAC or hostname is refused (3) and ced is not called" {
  run bash "$RUN" 00:00:00:00:00:01 node-facts
  [ "$status" -eq 3 ]
  run bash "$RUN" nosuchhost node-facts
  [ "$status" -eq 3 ]
  [[ "$output" == *"no host in the registry"* ]]
  [ ! -e "$CE_LOG" ]
}

@test "output and the exit code of ced pass through" {
  FAKE_CED_RC=7 run bash "$RUN" held01 node-facts
  [ "$status" -eq 7 ]
  [[ "$output" == *"ced-stdout"* ]]
  [[ "$output" == *"ced-stderr"* ]]
}

@test "a script name outside [A-Za-z0-9_-] is a usage error (2)" {
  run bash "$RUN" held01 '../etc/passwd'
  [ "$status" -eq 2 ]
  [ ! -e "$CE_LOG" ]
}

@test "a missing function library is reported (1)" {
  HPS_SYSTEM_PATH="$TEST_DIR/none" run bash "$RUN" held01 node-facts
  [ "$status" -eq 1 ]
  [[ "$output" == *"function library not found"* ]]
}
