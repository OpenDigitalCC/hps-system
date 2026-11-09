#!/usr/bin/env bats
#
# CS-2.4: scripts/hps-run.sh --input finds ctrl-exec-cli on PATH, else where the
# ctrl-exec-api-plugins .deb installs it, and points it at the IPS API socket
# unless the caller names another socket or a URL.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-64.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RUN="$ROOT/scripts/hps-run.sh"
  mkdir -p "$TEST_DIR/sys/lib" "$TEST_DIR/hosts/aabbccddeeff" "$TEST_DIR/bin"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOT
hps_log() { :; }
normalise_mac() { echo "\${1//[:.-]/}"; }
host_registry() {
  case "\$2" in
    exists) [[ -d "$TEST_DIR/hosts/\$1" ]] ;;
    get) [[ -f "$TEST_DIR/hosts/\$1/\$3" ]] && cat "$TEST_DIR/hosts/\$1/\$3" ;;
  esac
}
get_host_mac_by_keyvalue() { return 1; }
EOT
  echo -n held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/ced"
  printf '#!/usr/bin/env bash\nprintf "HOSTNAME\\n--\\nheld01 10.0.0.5 7443\\n"\n' > "$CTRL_EXEC_DISPATCHER"
  cat > "$TEST_DIR/bin/ctrl-exec-cli" <<'EOT'
#!/usr/bin/env bash
cat > /dev/null
echo "$*" > "$TEST_DIR/cli.env"
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER" "$TEST_DIR/bin/ctrl-exec-cli"
  unset CTRL_EXEC_CLI CTRL_EXEC_API_SOCKET CTRL_EXEC_API_URL
  export PATH="$TEST_DIR/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "ctrl-exec-cli on PATH is used with the IPS API socket by default" {
  run bash -c "echo doc | bash '$RUN' --input aabbccddeeff dataset-unlock lab/enc"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_DIR/cli.env")" == "--socket /run/ctrl-exec-api/api.sock run "* ]]
}

@test "a socket named by the caller is kept" {
  run bash -c "echo doc | CTRL_EXEC_API_SOCKET=/x/api.sock bash '$RUN' --input aabbccddeeff dataset-unlock lab/enc"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_DIR/cli.env")" == "--socket /x/api.sock run "* ]]
}

@test "a URL named by the caller means no socket is set" {
  run bash -c "echo doc | CTRL_EXEC_API_URL=http://h:7445 bash '$RUN' --input aabbccddeeff dataset-unlock lab/enc"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_DIR/cli.env")" == "--url http://h:7445 run "* ]]
}

@test "without ctrl-exec-cli on PATH the plugins .deb location is tried" {
  rm -f "$TEST_DIR/bin/ctrl-exec-cli"
  run -127 bash -c "echo doc | bash '$RUN' --input aabbccddeeff dataset-unlock lab/enc 2>&1"
  [[ "$output" == *"/usr/share/ctrl-exec/plugins/ce-api-plugins/ctrl-exec-cli/ctrl-exec-cli"* ]]
}
