#!/usr/bin/env bats
#
# CS-1.16: hps-run never matches a stale-* registration, and prefers the
# <name>.<domain> candidate that --name registers.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-152.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RUN="$ROOT/scripts/hps-run.sh"
  mkdir -p "$TEST_DIR/sys/lib" "$TEST_DIR/hosts/aabbccddeeff"
  echo -n stale-held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOF
hps_log() { :; }
normalise_mac() { local m="\${1//[:.-]/}"; echo "\${m,,}"; }
host_registry() {
  local d="$TEST_DIR/hosts/\$1"
  case "\$2" in
    exists) [[ -d "\$d" ]] ;;
    get) [[ -f "\$d/\$3" ]] && cat "\$d/\$3" ;;
  esac
}
hps_get_config() { echo c1; }
cluster_registry() { echo lab.example; }
get_host_mac_by_keyvalue() { return 1; }
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
fi
exit 0
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a stale-* registration is never matched, even when it equals the registry name" {
  printf 'stale-held01  10.0.0.5  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" aabbccddeeff node-facts
  [ "$status" -eq 4 ]
  ! grep -q '^run' "$CE_LOG"
}

@test "the <name>.<domain> registration wins over a bare name and the name used is printed" {
  echo -n held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
  printf 'held01  10.0.0.5  7443\nheld01.lab.example  10.0.0.5  7443\nstale-held01.lab.example  10.0.0.5  7443\n' > "$TEST_DIR/agents"
  run bash "$RUN" aabbccddeeff node-facts
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> agent held01.lab.example,"* ]]
  [ "$(tail -n 1 "$CE_LOG")" = "run held01.lab.example node-facts" ]
}
