#!/usr/bin/env bats
#
# cnh-ips-operator-init: the first operator credential of the IPS a CNH runs,
# issued in the running hps-ips container; the credential leaves only on
# stdout (the script is allowlisted output=confidential).

bats_require_minimum_version 1.5.0
load p2_30_helpers
load p3_171_helpers

TOKEN=hpsop_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-182.XXXXXX")"
  export TEST_DIR
  p3_171_setup
  export TOKEN
  echo true > "$STATE/running"
  echo '[]' > "$STATE/operators"
  cat > "$STATE/ipaddr" <<'JSON'
[{"ifname":"lo","flags":["LOOPBACK","UP","LOWER_UP"],"addr_info":[{"family":"inet","local":"127.0.0.1","prefixlen":8,"scope":"host"}]},
 {"ifname":"ens3","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"addr_info":[{"family":"inet","local":"10.99.1.20","prefixlen":24,"scope":"global"}]},
 {"ifname":"ens4","flags":["BROADCAST","MULTICAST","UP","LOWER_UP"],"addr_info":[{"family":"inet","local":"10.11.0.1","prefixlen":24,"scope":"global"},{"family":"inet6","local":"fe80::1","prefixlen":64,"scope":"link"}]},
 {"ifname":"dummy0","flags":["BROADCAST","NOARP","UP"],"addr_info":[{"family":"inet","local":"10.11.9.9","prefixlen":32,"scope":"host"}]}]
JSON
  # podman: the container's state and what runs in it (logged as "ips ...").
  cat > "$TEST_DIR/bin/podman" <<'SHIM'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "container inspect")
    echo "podman container inspect" >> "$SHIM_LOG"
    [[ -s "$STATE/running" ]] || { echo "no such container" >&2; exit 125; }
    cat "$STATE/running"
    exit 0 ;;
esac
[[ "$1 $2" == "exec hps-ips" ]] || { echo "podman $*" >> "$SHIM_LOG"; exit 1; }
shift 2
case "$1 ${2:-}" in
  "/srv/hps-system/bin/hps-operator list")
    echo "ips hps-operator $2 $3" >> "$SHIM_LOG"
    cat "$STATE/operators" ;;
  "/srv/hps-system/bin/hps-operator issue")
    echo "ips hps-operator issue $3" >> "$SHIM_LOG"
    [[ -n "${FAKE_ISSUE_RC:-}" ]] && exit "$FAKE_ISSUE_RC"
    printf 'name = %s\nagent = ips.s1.hps\nurl = https://10.11.0.1:7445\ntoken = %s\n-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n' "$3" "$TOKEN" ;;
  "/srv/hps-system/bin/hps-cluster-config set")
    echo "ips hps-cluster-config set $3 $4" >> "$SHIM_LOG"
    echo "operator_api_listen: (unset) -> '$4'"
    exit "${FAKE_SET_RC:-0}" ;;
  "/srv/hps-system/bin/hps-operator-api-apply ")
    echo "ips hps-operator-api-apply" >> "$SHIM_LOG"
    echo "ctrl-exec-api: stopped"
    echo "operator API: https://10.11.0.1:7445"
    exit "${FAKE_APPLY_RC:-0}" ;;
  *)
    echo "ips $*" >> "$SHIM_LOG"
    exit 1 ;;
esac
SHIM
  cat > "$TEST_DIR/bin/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "$SHIM_LOG"
cat "$STATE/ipaddr"
SHIM
  chmod +x "$TEST_DIR/bin/podman" "$TEST_DIR/bin/ip"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ips_steps: the in-container steps, in order, one line each.
ips_steps() {
  grep '^ips ' "$SHIM_LOG" || true
}

@test "sets the listen address, applies it, then issues: the credential on stdout only, the summary last" {
  run --separate-stderr bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "OPERATOR-INIT done label=lab url=https://10.11.0.1:7445" ]
  [[ "$output" == *"token = $TOKEN"* ]]
  [[ "$output" == *"-----BEGIN CERTIFICATE-----"* ]]
  [[ "$stderr" != *"$TOKEN"* ]]
  [[ "${lines[-1]}" != *hpsop_* ]]
  # the setup steps' own output goes to stderr, not into the credential
  [[ "$output" != *"operator_api_listen:"* ]]
  [[ "$output" != *"ctrl-exec-api:"* ]]
  [[ "$output" != *"operator API:"* ]]
  [ "$(ips_steps)" = "ips hps-operator list --json
ips hps-cluster-config set operator_api_listen 10.11.0.1
ips hps-operator-api-apply
ips hps-operator issue lab" ]
  # every podman call through systemd-run
  [ "$(grep -c '^systemd-run --quiet --wait --pipe --collect -- podman ' "$SHIM_LOG")" -eq 5 ]
}

@test "an existing label is refused (3) before anything changes, and says how to revoke" {
  echo '[{"name":"lab","issued":1}]' > "$STATE/operators"
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"already exists"* ]]
  [[ "$output" == *"hps-operator revoke lab"* ]]
  [ "$(ips_steps)" = "ips hps-operator list --json" ]
}

@test "another label does not block; a label issued meanwhile is refused (3)" {
  echo '[{"name":"other","issued":1}]' > "$STATE/operators"
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 0 ]
  FAKE_ISSUE_RC=3 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing re-issued"* ]]
}

@test "the hps-ips container not running is refused (3) before anything runs in it" {
  : > "$STATE/running"
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"not running"* ]]
  [[ "$output" == *"cnh-ips-run"* ]]
  [ -z "$(ips_steps)" ]
  echo false > "$STATE/running"
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  [ -z "$(ips_steps)" ]
}

@test "an address not on a CNH interface, loopback or wildcard is refused (3)" {
  local a
  for a in 10.11.0.2 10.11.0.10 127.0.0.1 10.11.9.9 0.0.0.0 255.255.255.255; do
    run bash "$S/cnh-ips-operator-init" "$a:7445" lab
    [ "$status" -eq 3 ]
  done
  run bash "$S/cnh-ips-operator-init" 10.11.0.2:7445 lab
  [[ "$output" == *"not assigned to a (non-loopback) interface of this CNH"* ]]
  [ -z "$(ips_steps)" ]
  run ! grep -q 'container inspect' "$SHIM_LOG"
}

@test "malformed addresses, other ports and bad labels are refused (3); usage errors exit 2" {
  local v
  for v in 10.11.0.1 10.11.0.1:7446 10.11.0.1:0 10.11.0.256:7445 10.11.0:7445 \
    '10.11.0.1:7445;id' 'host.example:7445' '[::1]:7445' ' 10.11.0.1:7445'; do
    run bash "$S/cnh-ips-operator-init" "$v" lab
    [ "$status" -eq 3 ]
  done
  for v in Lab 1lab 'lab;id' 'lab name' '' 'a23456789012345678901234567890123' 'lab$(id)'; do
    run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 "$v"
    [ "$status" -eq 3 ]
  done
  [ -z "$(ips_steps)" ]
  run bash "$S/cnh-ips-operator-init"
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab extra
  [ "$status" -eq 2 ]
  run bash "$S/cnh-ips-operator-init" --help lab
  [ "$status" -eq 2 ]
}

@test "the IPS refusing the address stops before issuing: validation (3), bring-up leaving it off (3), a failure (1)" {
  FAKE_SET_RC=3 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  run ! grep -q 'hps-operator issue' "$SHIM_LOG"
  : > "$SHIM_LOG"
  FAKE_APPLY_RC=3 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 3 ]
  [[ "$output" == *"did not take 10.11.0.1"* ]]
  run ! grep -q 'hps-operator issue' "$SHIM_LOG"
  FAKE_APPLY_RC=1 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 1 ]
  FAKE_SET_RC=1 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 1 ]
  FAKE_ISSUE_RC=1 run bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 1 ]
  [[ "$output" != *OPERATOR-INIT* ]]
}

@test "the token is never in an argument, the command trace or a file the script writes" {
  run --separate-stderr bash "$S/cnh-ips-operator-init" 10.11.0.1:7445 lab
  [ "$status" -eq 0 ]
  run ! grep -rqF "$TOKEN" "$SHIM_LOG" "$HPS_CNH_ROOT"
  [[ "$stderr" == *"+ systemd-run"*"hps-operator issue lab"* ]]
}

@test "allowlisted on the CNH image under profile node with output=confidential" {
  local cnh="${BATS_TEST_DIRNAME}/../../nix/modules/profiles/container-host.nix"
  grep -qxF '      cnh-ips-operator-init.source = mkScript "cnh-ips-operator-init" (scriptsDir + "/cnh-ips-operator-init");' "$cnh"
  grep -qxF '      cnh-ips-operator-init.options.profile = "node";' "$cnh"
  grep -qxF '      cnh-ips-operator-init.options.output = "confidential";' "$cnh"
  [ -x "$S/cnh-ips-operator-init" ]
}

# --- the IPS side: ce_operator_api_apply (bin/hps-operator-api-apply) --------

# apply_env: the IPS library functions with the registry, bring-up and
# supervisorctl stubbed; FAKE_LISTEN is the key, FAKE_BIND what bring-up
# leaves in ctrl-exec.conf.
apply_env() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CTRL_EXEC_DISPATCHER_CONF_DIR="$TEST_DIR/etc"
  export CTRL_EXEC_DISPATCHER_CONF="$TEST_DIR/etc/ctrl-exec.conf"
  mkdir -p "$TEST_DIR/etc"
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  hps_log() { echo "log $*" >> "$SHIM_LOG"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo s1 ;;
      supervisord_conf) echo /fake/supervisord.conf ;;
    esac
  }
  cluster_registry() { [[ "$3" == operator_api_listen ]] && printf '%s\n' "${FAKE_LISTEN:-}"; return 0; }
  ce_api_bring_up() {
    echo "bring-up" >> "$SHIM_LOG"
    printf 'api_port = 7445\n%s\n' "${FAKE_BIND:-}" > "$CTRL_EXEC_DISPATCHER_CONF"
    return "${FAKE_BRINGUP_RC:-0}"
  }
  cat > "$TEST_DIR/bin/supervisorctl" <<'SHIM'
#!/usr/bin/env bash
echo "supervisorctl $*" >> "$SHIM_LOG"
exit "${FAKE_SV_RC:-0}"
SHIM
  chmod +x "$TEST_DIR/bin/supervisorctl"
}

@test "ce_operator_api_apply: bring-up, api_bind checked, then only ctrl-exec-api restarted" {
  apply_env
  local b
  for b in 'api_bind = 10.11.0.1' 'api_bind=10.11.0.1' '  api_bind = 10.11.0.1  '; do
    : > "$SHIM_LOG"
    FAKE_LISTEN=10.11.0.1 FAKE_BIND="$b" run --separate-stderr ce_operator_api_apply
    [ "$status" -eq 0 ]
    [ "$output" = "operator API: https://10.11.0.1:7445" ]
    [ "$(grep -v '^log' "$SHIM_LOG")" = "bring-up
supervisorctl -c /fake/supervisord.conf restart ctrl-exec-api" ]
  done
}

@test "ce_operator_api_apply: unset key, listener left off or another address is refused (3) without a restart" {
  apply_env
  FAKE_LISTEN="" run ce_operator_api_apply
  [ "$status" -eq 3 ]
  [[ "$output" == *"operator_api_listen is unset"* ]]
  run ! grep -q bring-up "$SHIM_LOG"
  local b
  for b in '' 'api_bind = 10.11.0.10' 'api_bind = 10.11.0.2' '# api_bind = 10.11.0.1'; do
    FAKE_LISTEN=10.11.0.1 FAKE_BIND="$b" run ce_operator_api_apply
    [ "$status" -eq 3 ]
    [[ "$output" == *"left the operator API off for 10.11.0.1"* ]]
  done
  run ! grep -q supervisorctl "$SHIM_LOG"
}

@test "ce_operator_api_apply: bring-up or the restart failing fails (1)" {
  apply_env
  FAKE_LISTEN=10.11.0.1 FAKE_BIND='api_bind = 10.11.0.1' FAKE_BRINGUP_RC=1 run ce_operator_api_apply
  [ "$status" -eq 1 ]
  run ! grep -q supervisorctl "$SHIM_LOG"
  FAKE_LISTEN=10.11.0.1 FAKE_BIND='api_bind = 10.11.0.1' FAKE_SV_RC=7 run ce_operator_api_apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not restart"* ]]
}

@test "bin/hps-operator-api-apply takes no arguments and runs ce_operator_api_apply" {
  local bin="$BATS_TEST_DIRNAME/../../bin/hps-operator-api-apply"
  [ -x "$bin" ]
  run bash "$bin" 10.11.0.1
  [ "$status" -eq 2 ]
  grep -qxF 'ce_operator_api_apply || rc=$?' "$bin"
}
