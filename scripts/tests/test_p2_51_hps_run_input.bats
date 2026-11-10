#!/usr/bin/env bats
#
# CS-2.3: scripts/hps-run.sh --input sends its stdin to an `input = raw` node
# script. ced 0.14.4 has no input option, so the real script hands the document
# to the API client:  ctrl-exec-cli --socket <api.sock> run <agent> --script <s> --input - [--json] -- args
# which posts it as the one field "input" of POST /run. Here ced and
# ctrl-exec-cli are shims; the function library is a fake tree over a file
# registry (as in test_p1_104). The last test drives the Perl runner through the
# real hps-run.sh and asserts the node script would read the exact JSON.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-51.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RUN="$ROOT/scripts/hps-run.sh"
  mkdir -p "$TEST_DIR/sys/lib" "$TEST_DIR/hosts"
  cat > "$TEST_DIR/sys/lib/functions.sh" <<EOT
source "$ROOT/lib/functions.d/host-functions.sh"
hps_get_config() { echo c1; }
cluster_registry() { echo lab.hps; }
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
source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
EOT
  export HPS_SYSTEM_PATH="$TEST_DIR/sys"
  export CED_LOG="$TEST_DIR/ced.log"
  export CLI_LOG="$TEST_DIR/cli.log"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/ced"
  export CTRL_EXEC_CLI="$TEST_DIR/ctrl-exec-cli"
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CED_LOG"
if [[ "$1" == list-agents ]]; then
  printf 'HOSTNAME  IP  PORT\n----\n'
  cat "$TEST_DIR/agents"
  exit 0
fi
echo "ced-run-output"
exit "${FAKE_CED_RC:-0}"
EOT
  # The API client: logs its arguments, keeps stdin byte for byte, and answers
  # as the real one does (text, or --json).
  cat > "$CTRL_EXEC_CLI" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLI_LOG"
cat > "$TEST_DIR/node.stdin"
if [[ " $* " == *" --json "* ]]; then
  printf '{"ok":1,"results":[{"host":"held01","exit":%s,"stdout":"unlocked\\n","stderr":"+ zfs load-key\\n"}]}\n' "${FAKE_NODE_EXIT:-0}"
else
  echo "==> held01 [ok]"
fi
exit "${FAKE_CLI_RC:-0}"
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER" "$CTRL_EXEC_CLI"
  printf 'held01.lab.hps  10.0.0.5  7443\n' > "$TEST_DIR/agents"
  mkdir -p "$TEST_DIR/hosts/aabbccddeeff"
  echo -n held01 > "$TEST_DIR/hosts/aabbccddeeff/HOSTNAME"
  KEY_DOC='{"key_hex":"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"}'
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "--input passes stdin, byte for byte and without a trailing newline, to ctrl-exec-cli" {
  printf '%s' "$KEY_DOC" | bash "$RUN" --input aabbccddeeff dataset-unlock lab/enc
  [ "$(cat "$TEST_DIR/node.stdin")" = "$KEY_DOC" ]
  [ "$(wc -c < "$TEST_DIR/node.stdin")" -eq "${#KEY_DOC}" ]
}

@test "the client is called as: --socket <api.sock> run <agent> --script <script> --input - -- args" {
  printf '%s' "$KEY_DOC" | bash "$RUN" --input AA:BB:CC:DD:EE:FF dataset-unlock lab/enc
  [ "$(tail -n 1 "$CLI_LOG")" = "--socket /run/ctrl-exec-api/api.sock run held01.lab.hps --script dataset-unlock --input - -- lab/enc" ]
}

@test "no script arguments: no '--' is sent" {
  printf '%s' "$KEY_DOC" | bash "$RUN" --input held01 iscsi-status
  [ "$(tail -n 1 "$CLI_LOG")" = "--socket /run/ctrl-exec-api/api.sock run held01.lab.hps --script iscsi-status --input -" ]
}

@test "--input --json adds --json and prints the client's JSON untouched" {
  run bash -c "printf '%s' '$KEY_DOC' | bash '$RUN' --input --json aabbccddeeff dataset-unlock lab/enc 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CLI_LOG")" = "--socket /run/ctrl-exec-api/api.sock run held01.lab.hps --script dataset-unlock --input - --json -- lab/enc" ]
  [[ "$output" == '{"ok":1,"results":[{"host":"held01","exit":0,'* ]]
}

@test "the client's exit status is passed through" {
  FAKE_CLI_RC=1 run bash -c "printf '%s' '$KEY_DOC' | bash '$RUN' --input held01 dataset-unlock lab/enc"
  [ "$status" -eq 1 ]
}

@test "the document never reaches ced, an argument or the output" {
  run bash -c "printf '%s' '$KEY_DOC' | bash '$RUN' --input held01 dataset-unlock lab/enc 2>&1"
  [ "$status" -eq 0 ]
  ! grep -q 00112233 "$CED_LOG"
  ! grep -q 00112233 "$CLI_LOG"
  [[ "$output" != *00112233* ]]
  # ced is used for name resolution only
  ! grep -q '^run ' "$CED_LOG"
  grep -qx 'list-agents' "$CED_LOG"
}

@test "without --input the call is 'ced run' and the client is not used" {
  run bash "$RUN" aabbccddeeff storage-pool-import lab
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CED_LOG")" = "run held01.lab.hps storage-pool-import -- lab" ]
  [ ! -e "$CLI_LOG" ]
}

@test "--json without --input calls the client with --json and no --input, prints its JSON, ced run unused" {
  FAKE_NODE_EXIT=3 run bash "$RUN" --json aabbccddeeff image-fetch debian --dest /x < /dev/null
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$CLI_LOG")" = "--socket /run/ctrl-exec-api/api.sock run held01.lab.hps --script image-fetch --json -- debian --dest /x" ]
  [[ "$output" == *'"exit":3'* ]]
  ! grep -q '^run ' "$CED_LOG"
}

@test "--json without --input: the client's own failure is passed through, stdin is not read" {
  FAKE_CLI_RC=1 run bash "$RUN" --json held01 iscsi-status
  [ "$status" -eq 1 ]
  [ "$(wc -c < "$TEST_DIR/node.stdin")" -eq 0 ]
}

@test "--input with an unknown host (3) or no agent (4) calls no client" {
  run bash "$RUN" --input nobody dataset-unlock lab/enc < /dev/null
  [ "$status" -eq 3 ]
  mkdir -p "$TEST_DIR/hosts/112233445566"
  run bash "$RUN" --input 112233445566 dataset-unlock lab/enc < /dev/null
  [ "$status" -eq 4 ]
  [ ! -e "$CLI_LOG" ]
}

@test "the Perl runner through the real hps-run.sh: the node script would read the exact JSON" {
  doc='{"approval":{"action":"pool-create","disks":["ata-A","ata-B"],"expires":1800003600,"hmac":"aa","issued_by":"op","mac":"aabbccddeeff","pool":"lab","wipe":0},"key_hex":"k","secret":"s"}'
  export HPS_RUN_CMD="$RUN"
  run perl -I"$ROOT/lib/perl" -MHPS::Storage -MJSON::PP -e '
    my $r = HPS::Storage::Runner::HpsRun->new->call(mac => "aabbccddeeff", script => "storage-pool-create",
        args => ["lab", "--disk", "ata-A", "--disk", "ata-B", "--approval-file", "-"], input => $ARGV[0]);
    print encode_json($r), "\n";
  ' "$doc"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_DIR/node.stdin")" = "$doc" ]
  [ "$(tail -n 1 "$CLI_LOG")" = "--socket /run/ctrl-exec-api/api.sock run held01.lab.hps --script storage-pool-create --input - --json -- lab --disk ata-A --disk ata-B --approval-file -" ]
  [[ "$output" == *'"rc":0'* ]]
  [[ "$output" == *'"stdout":"unlocked\n"'* ]]
  FAKE_NODE_EXIT=3 run perl -I"$ROOT/lib/perl" -MHPS::Storage -MJSON::PP -e '
    my $r = HPS::Storage::Runner::HpsRun->new->call(mac => "aabbccddeeff", script => "dataset-unlock", args => ["lab/enc"], input => "{}");
    print $r->{rc}, "\n";
  '
  [ "$output" = "3" ]
}
