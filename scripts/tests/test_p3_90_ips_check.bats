#!/usr/bin/env bats
#
# IPS-01: bin/hps-ips-check. The function library is a stub (HPS_SYSTEM_PATH);
# curl, dig, ctrl-exec-*, logger, chronyc and df are PATH shims steered by
# FAKE_* variables. Nothing here touches a real service.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-90.XXXXXX")"
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TEST_DIR ROOT
  SYS="$TEST_DIR/sys"
  BIN="$TEST_DIR/bin"
  mkdir -p "$SYS/lib" "$BIN" "$TEST_DIR/res/nixos/pin1/audit" "$TEST_DIR/log/ips" \
    "$TEST_DIR/tftp" "$TEST_DIR/services" "$TEST_DIR/db"
  export HPS_SYSTEM_PATH="$SYS"
  export CURL_LOG="$TEST_DIR/curl.log" LOGGER_LOG="$TEST_DIR/logger.log"
  export HPS_IPS_CHECK_SYSLOG_WAIT=1

  # stub function library
  cat > "$SYS/lib/functions.sh" <<'EOF'
hps_get_config() {
  case "$1" in
    active_cluster) [[ -n "${FAKE_NO_CLUSTER:-}" ]] && return 1; echo lab ;;
    resources) echo "$TEST_DIR/res" ;;
    log) echo "$TEST_DIR/log" ;;
    tftp) echo "$TEST_DIR/tftp" ;;
    cluster_services) echo "$TEST_DIR/services" ;;
    cluster_registry) echo "$TEST_DIR/db" ;;
    *) return 1 ;;
  esac
}
cluster_registry() {
  case "$3" in
    network_dhcp_ip) echo 192.0.2.1 ;;
    network_dns_domain) echo lab.test ;;
    *) return 1 ;;
  esac
}
list_cluster_hosts() { cut -d' ' -f1 "$TEST_DIR/hosts" 2> /dev/null; }
host_registry() { grep "^$1 " "$TEST_DIR/hosts" | cut -d' ' -f2; }
EOF
  printf 'aabbccddeeff node1\n' > "$TEST_DIR/hosts"

  # fixtures: tftp files, nixos pin, API socket and dispatcher config
  echo loader > "$TEST_DIR/tftp/snponly.efi"
  echo loader > "$TEST_DIR/tftp/undionly.kpxe"
  echo pin1 > "$TEST_DIR/res/nixos/latest"
  echo '{"pin":"pin1"}' > "$TEST_DIR/res/nixos/pin1/audit/boot.json"
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die $!' "$TEST_DIR/api.sock"
  printf 'api_socket = %s\napi_socket_group = %s\n' "$TEST_DIR/api.sock" "$(id -gn)" > "$TEST_DIR/ctrl-exec.conf"
  export CTRL_EXEC_DISPATCHER_CONF="$TEST_DIR/ctrl-exec.conf"

  shim_curl
  shim_other
  export PATH="$BIN:$PATH"
}

teardown() {
  rm -rf "$TEST_DIR"
}

shim_curl() {
  cat > "$BIN/curl" <<'EOF'
#!/bin/bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--max-time) shift 2 ;;
    --data-binary) printf '[data-binary:%s]' "$2" >> "$CURL_LOG"; shift 2 ;;
    -X) printf '[method:%s]' "$2" >> "$CURL_LOG"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$CURL_LOG"
if [[ -n "${FAKE_CURL_DOWN:-}" ]]; then
  printf 'curl: (7) Failed to connect\n' >&2
  printf '000'
  exit 7
fi
case "$url" in
  *cmd=init*) code="${FAKE_INIT:-200}"; body="${FAKE_INIT_BODY-#!ipxe}" ;;
  *cmd=log_message*) code="${FAKE_LOGMSG:-200}"; body="" ;;
  *cmd=cluster_variable*) code="${FAKE_CV:-200}"; body="${FAKE_CV_BODY-lab.test}" ;;
  */boot.json) code="${FAKE_BOOTJSON:-200}"; body="${FAKE_BOOTJSON_BODY-{\"pin\":\"pin1\"\}}" ;;
  *) code=404; body="" ;;
esac
[[ -z "$out" ]] || printf '%s\n' "$body" > "$out"
printf '%s' "$code"
EOF
  chmod +x "$BIN/curl"
}

shim_other() {
  cat > "$BIN/dig" <<'EOF'
#!/bin/bash
name=""
for a in "$@"; do case "$a" in +*|@*|A) ;; *) name="$a" ;; esac; done
printf '%s\n' "$name" >> "$TEST_DIR/dig.log"
[[ "$name" == "${FAKE_DIG_EMPTY:-none}" ]] && exit 0
echo 192.0.2.9
EOF
  cat > "$BIN/ctrl-exec-dispatcher" <<'EOF'
#!/bin/bash
echo "ctrl-exec-dispatcher 0.14.4"
EOF
  cat > "$BIN/ctrl-exec-api" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$BIN/ctrl-exec-cli" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_DIR/cli.log"
case "$*" in
  *--version*) echo "ctrl-exec-cli 0.3.11" ;;
  *health*)
    if [[ -n "${FAKE_HEALTH_FAIL:-}" ]]; then echo "cannot connect" >&2; exit 1; fi
    printf 'STATUS       ok\nVERSION      0.14.4\n' ;;
esac
EOF
  cat > "$BIN/logger" <<'EOF'
#!/bin/bash
tag=""; [[ "$1" == "-t" ]] && { tag="$2"; shift 2; }
printf '%s|%s\n' "$tag" "$*" >> "$LOGGER_LOG"
if [[ "$tag" == hps-ips-check-probe && -z "${FAKE_LOGGER_DROPS:-}" ]]; then
  printf '%s\n' "$*" >> "$TEST_DIR/log/ips/$(date +%Y-%m-%d).log"
fi
EOF
  cat > "$BIN/chronyc" <<'EOF'
#!/bin/bash
case "${FAKE_CHRONY:-synced}" in
  down) echo "506 Cannot talk to daemon" >&2; exit 1 ;;
  unsync) printf 'Stratum         : 0\nLeap status     : Not synchronised\n' ;;
  *) printf 'Stratum         : 3\nLeap status     : Normal\n' ;;
esac
EOF
  cat > "$BIN/df" <<'EOF'
#!/bin/bash
path="${@: -1}"
used=10
case "$path" in */res) used="${FAKE_DF_RES:-10}" ;; */log) used="${FAKE_DF_LOG:-10}" ;; esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/x 1000 %s 100 %s%% %s\n' "$used" "$used" "$path"
EOF
  chmod +x "$BIN"/*
}

@test "all checks pass: exit 0, summary, versions shown, JSON result written" {
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS boot_manager init:"* ]]
  [[ "$output" == *"ctrl-exec-dispatcher 0.14.4"* ]]
  [[ "$output" == *"ctrl-exec-cli 0.3.11"* ]]
  [[ "$output" == *"summary: "*"0 WARN, 0 FAIL"* ]]
  f="$TEST_DIR/services/ips-check.json"
  jq -e '.timestamp and .cluster == "lab" and .summary.fail == 0 and ([.checks[].status] | all(. == "PASS"))' "$f"
}

@test "writes one syslog line per check and a summary, tagged hps-ips-check" {
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  grep -q '^hps-ips-check|PASS boot_manager POST log_message: ' "$LOGGER_LOG"
  grep -q '^hps-ips-check|summary: ' "$LOGGER_LOG"
  lines="$(grep -c '^hps-ips-check|\(PASS\|FAIL\|WARN\) ' "$LOGGER_LOG")"
  [ "$lines" -eq "$(jq '.checks | length' "$TEST_DIR/services/ips-check.json")" ]
}

@test "--json prints the result on stdout" {
  run "$ROOT/bin/hps-ips-check" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.summary.fail == 0 and (.checks | length) > 8'
}

@test "usage errors exit 2" {
  run "$ROOT/bin/hps-ips-check" --bogus
  [ "$status" -eq 2 ]
  run "$ROOT/bin/hps-ips-check" --wait abc
  [ "$status" -eq 2 ]
}

@test "log_message is POSTed with an explicit empty body" {
  run "$ROOT/bin/hps-ips-check"
  grep -q '^\[method:POST\]\[data-binary:\]http://192.0.2.1/cgi-bin/boot_manager.sh?cmd=log_message' "$CURL_LOG"
}

@test "a 411 on the log_message POST is a FAIL naming 411" {
  FAKE_LOGMSG=411 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager POST log_message: HTTP 411"* ]]
}

@test "init: a 500 is a FAIL naming 500; a body that is not iPXE is a FAIL" {
  FAKE_INIT=500 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager init: HTTP 500"* ]]
  FAKE_INIT_BODY="<html>" run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager init: HTTP 200 but the body is not an iPXE script"* ]]
}

@test "cluster_variable: a 404 and an empty value are FAILs" {
  FAKE_CV=404 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager cluster_variable: HTTP 404"* ]]
  FAKE_CV_BODY="" run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager cluster_variable: HTTP 200 but network_dns_domain is empty"* ]]
}

@test "boot.json: fetched at the latest pin, a 404 and a JSON without pin are FAILs" {
  run "$ROOT/bin/hps-ips-check"
  grep -q 'http://192.0.2.1/nixos/pin1/audit/boot.json' "$CURL_LOG"
  FAKE_BOOTJSON=404 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL nixos boot.json: HTTP 404"* ]]
  FAKE_BOOTJSON_BODY='{"x":1}' run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL nixos boot.json: HTTP 200 but not JSON with a pin"* ]]
}

@test "no nixos/latest is a WARN, not a FAIL" {
  rm "$TEST_DIR/res/nixos/latest"
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN nixos boot.json:"* ]]
}

@test "nothing answering HTTP fails every boot_manager check and says so" {
  FAKE_CURL_DOWN=1 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL boot_manager init: no HTTP answer"* ]]
  [[ "$output" == *"FAIL boot_manager POST log_message: no HTTP answer"* ]]
}

@test "tftp: a missing or empty boot file is a FAIL naming it" {
  rm "$TEST_DIR/tftp/snponly.efi"
  : > "$TEST_DIR/tftp/undionly.kpxe"
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL tftp boot files: "*"snponly.efi undionly.kpxe"* ]]
}

@test "dns: the IPS name and a registry host are queried at the IPS address" {
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  grep -qx 'ips.lab.test' "$TEST_DIR/dig.log"
  grep -qx 'node1.lab.test' "$TEST_DIR/dig.log"
}

@test "dns: no answer for the IPS name is a FAIL; no registry host is a WARN" {
  FAKE_DIG_EMPTY=ips.lab.test run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL dns ips: 192.0.2.1 gave no answer for ips.lab.test"* ]]
  : > "$TEST_DIR/hosts"
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN dns registry host:"* ]]
}

@test "ctrl-exec: health is called over the configured socket" {
  run "$ROOT/bin/hps-ips-check"
  grep -qx -- "--socket $TEST_DIR/api.sock health" "$TEST_DIR/cli.log"
}

@test "ctrl-exec: missing dispatcher, CLI or API are FAILs" {
  rm "$BIN/ctrl-exec-dispatcher" "$BIN/ctrl-exec-api" "$BIN/ctrl-exec-cli"
  CTRL_EXEC_DISPATCHER=ctrl-exec-nosuch CTRL_EXEC_API_BIN=ctrl-exec-nosuch2 CTRL_EXEC_CLI_INSTALLED="$TEST_DIR/none" run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL ctrl-exec dispatcher: ctrl-exec-nosuch not found"* ]]
  [[ "$output" == *"FAIL ctrl-exec api: ctrl-exec-nosuch2 not found"* ]]
  [[ "$output" == *"FAIL ctrl-exec cli: ctrl-exec-cli not found"* ]]
}

@test "ctrl-exec: absent socket and wrong group are FAILs" {
  rm "$TEST_DIR/api.sock"
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL ctrl-exec api socket: $TEST_DIR/api.sock is not a socket"* ]]
  perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die $!' "$TEST_DIR/api.sock"
  printf 'api_socket = %s\napi_socket_group = nosuchgroup\n' "$TEST_DIR/api.sock" > "$TEST_DIR/ctrl-exec.conf"
  run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL ctrl-exec api socket: "*"configured nosuchgroup"* ]]
}

@test "ctrl-exec: a failing health call is a FAIL with its message" {
  FAKE_HEALTH_FAIL=1 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL ctrl-exec api health: "*"cannot connect"* ]]
}

@test "rsyslog: a probe that never reaches ips/<date>.log is a FAIL" {
  FAKE_LOGGER_DROPS=1 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL rsyslog: tagged message not in "* ]]
}

@test "chrony: unsynchronised is a WARN and does not fail; not running is a FAIL" {
  FAKE_CHRONY=unsync run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN chrony: running, Not synchronised"* ]]
  FAKE_CHRONY=down run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL chrony: chronyd not answering"* ]]
}

@test "disk: below 15% free is a WARN, below 5% a FAIL" {
  FAKE_DF_RES=90 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN disk resources: "*"10% free (below 15%)"* ]]
  FAKE_DF_LOG=97 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL disk log: "*"3% free (below 5%)"* ]]
}

@test "registry: no active cluster is a FAIL" {
  FAKE_NO_CLUSTER=1 run "$ROOT/bin/hps-ips-check"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL registry: no active cluster set"* ]]
}

@test "an unwritable result file makes the run fail" {
  chmod 555 "$TEST_DIR/services"
  run "$ROOT/bin/hps-ips-check"
  chmod 755 "$TEST_DIR/services"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot write"* ]]
}

@test "--wait gives up after the time and still checks" {
  FAKE_CURL_DOWN=1 run "$ROOT/bin/hps-ips-check" --wait 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"waited 1s"* ]]
  [[ "$output" == *"summary: "* ]]
}
