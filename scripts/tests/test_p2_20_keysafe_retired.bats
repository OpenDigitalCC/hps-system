#!/usr/bin/env bats
#
# CS-2.2: the Bash keysafe is retired in favour of HPS::Keysafe. Nothing of it
# remains in lib/, node-manager/ or the CGI route (which answers 410 Gone); the
# historical docs say so; and hps-approve never lets the HMAC secret reach its
# output or the registry.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-20.XXXXXX")"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "the Bash keysafe files are gone" {
  [ ! -e "$ROOT/lib/functions.d/keysafe-functions.sh" ]
  [ ! -e "$ROOT/node-manager/base/n_keysafe-node.sh" ]
  [ ! -e "$ROOT/scripts/tests/test_keysafe.sh" ]
}

@test "no keysafe_ function remains in lib/ and no n_keysafe in node-manager/" {
  run grep -rnE '(^|[^A-Za-z_])(keysafe_[a-z_]+|get_keysafe_dir)[[:space:]]*(\(\)|\{)' "$ROOT/lib" --include='*.sh'
  [ "$status" -eq 1 ]
  run grep -rn 'keysafe_' "$ROOT/lib" --include='*.sh'
  [ "$status" -eq 1 ]
  run grep -rn 'n_keysafe' "$ROOT/node-manager" "$ROOT/lib" "$ROOT/http"
  [ "$status" -eq 1 ]
  [ -z "$(find "$ROOT/node-manager" -iname '*keysafe*')" ]
}

@test "the keysafe_request_token route answers 410 Gone and logs it" {
  # Run just the route block of boot_manager.sh with the CGI helpers stubbed.
  awk '/^if \[\[ "\$cmd" == "keysafe_request_token" \]\]; then/,/^fi$/' \
    "$ROOT/http/cgi-bin/boot_manager.sh" > "$TEST_DIR/route.sh"
  [ -s "$TEST_DIR/route.sh" ]
  cat > "$TEST_DIR/run.sh" <<EOS
hps_log() { echo "\$*" >> "$TEST_DIR/hps.log"; }
cgi_status() { echo "Status: \$1 \$2"; }
cgi_header_plain() { printf 'Content-Type: text/plain\n\n'; }
cgi_fail() { cgi_status "\${2:-500}" "\${3:-Internal Server Error}"; cgi_header_plain; printf '%s' "\$1"; }
cmd=keysafe_request_token
mac=52:54:00:aa:bb:01
source "$TEST_DIR/route.sh"
echo "ROUTE NOT TAKEN"
EOS
  run bash "$TEST_DIR/run.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Status: 410 Gone" ]
  [[ "$output" != *"ROUTE NOT TAKEN"* ]]
  grep -q 'keysafe_request_token refused (410 Gone)' "$TEST_DIR/hps.log"
}

@test "boot_manager.sh no longer calls a keysafe function" {
  run grep -n 'keysafe_handle_token_request\|keysafe_issue\|keysafe_validate' "$ROOT/http/cgi-bin/boot_manager.sh"
  [ "$status" -eq 1 ]
}

@test "the historical docs carry the banner" {
  for f in biscuit.md auth-flow-drh-backup-session.md; do
    head -3 "$ROOT/DOCUMENTATION/100-system-reference/$f" | grep -q 'Historical — never implemented; superseded by HPS::Keysafe (2026-11-09)'
  done
}

@test "SECURITY.md no longer lists the keysafe secure-mode stub" {
  run grep -n 'secure (cryptographic) mode\|keysafe secure' "$ROOT/docs/SECURITY.md"
  [ "$status" -eq 1 ]
  grep -q 'HPS::Keysafe' "$ROOT/docs/SECURITY.md"
  grep -q 'HMAC single-use pairing ticket' "$ROOT/docs/adr/0002-ctrl-exec-enrolment-trust.md"
}

# Build a minimal registry by hand (plain JSON files, as the Bash side writes it).
make_registry() {
  local b="$TEST_DIR/cfg"
  mkdir -p "$b/system.db" "$b/clusters/lab/cluster.db" "$b/clusters/lab/hosts/525400aabb01.db"
  echo '"lab"' > "$b/system.db/ACTIVE_CLUSTER.json"
  echo '"NETWORK_BOOT"' > "$b/clusters/lab/hosts/525400aabb01.db/STATE.json"
  export HPS_CONFIG_BASE="$b" HPS_SYSTEM_REGISTRY="$b/system.db"
}

@test "hps-approve output, errors and the registry never contain the HMAC secret" {
  make_registry
  run "$ROOT/bin/hps-approve" pool-create 52:54:00:aa:bb:01 --pool lab --disk ata-A --disk ata-B --wipe
  [ "$status" -eq 0 ]
  out1="$output"
  run "$ROOT/bin/hps-approve" pool-create 52:54:00:aa:bb:01 --pool lab --disk ata-A --json
  [ "$status" -eq 0 ]
  out2="$output"
  run "$ROOT/bin/hps-approve" list 52:54:00:aa:bb:01 --json
  out3="$output"
  run "$ROOT/bin/hps-approve" pool-create 52:54:00:aa:bb:01 --pool tank --disk ata-A
  out4="$output"
  secret_file="$HPS_CONFIG_BASE/clusters/lab/keysafe/approval.hmac"
  [ -f "$secret_file" ]
  [ "$(stat -c %a "$secret_file")" = "600" ]
  [ "$(stat -c %a "$HPS_CONFIG_BASE/clusters/lab/keysafe")" = "700" ]
  hex="$(od -An -v -tx1 "$secret_file" | tr -d ' \n')"
  [ "${#hex}" -eq 64 ]
  # Every output channel
  for o in "$out1" "$out2" "$out3" "$out4"; do
    [[ "$o" != *"$hex"* ]]
  done
  # Every file of the registry outside the keysafe directory
  run grep -rIl -e "$hex" "$HPS_CONFIG_BASE" --exclude-dir=keysafe
  [ "$status" -eq 1 ]
  # The raw bytes are not in the registry either
  run grep -rlF -f "$secret_file" "$HPS_CONFIG_BASE/system.db" "$HPS_CONFIG_BASE/clusters/lab/hosts" "$HPS_CONFIG_BASE/clusters/lab/cluster.db"
  [ "$status" -eq 1 ]
}
