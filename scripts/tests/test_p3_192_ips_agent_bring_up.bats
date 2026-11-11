#!/usr/bin/env bats
#
# ce_ips_agent_bring_up: the IPS's own ctrl-exec agent ips.<domain> is
# installed from the tarball when absent, persisted under /srv, configured
# (127.0.0.1 only, the ips-admin allowlist), and paired with the IPS's own
# dispatcher by the IPS, approving only that name from 127.0.0.1. Then the
# supervisord program and the run-hps.sh wiring. The dispatcher (ced) and the
# agent CLI are shims; the tarball install is a stub.

bats_require_minimum_version 1.5.0

FPR="SHA256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-192.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export CALLS="$TEST_DIR/calls"
  : > "$CALLS"
  mkdir -p "$TEST_DIR/bin" "$TEST_DIR/etc/ctrl-exec-dispatcher" "$TEST_DIR/sys/bin" "$TEST_DIR/sys/ips-admin"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  export -f hps_log

  export CTRL_EXEC_DISPATCHER_CONF_DIR="$TEST_DIR/etc/ctrl-exec-dispatcher"
  export CTRL_EXEC_IPS_AGENT_ETC="$TEST_DIR/etc/ctrl-exec-agent"
  export CTRL_EXEC_IPS_AGENT_STATE="$TEST_DIR/var/lib/ctrl-exec-agent"
  export CTRL_EXEC_PERSIST_AGENT_CONF="$TEST_DIR/srv/ctrl-exec/agent-conf"
  export CTRL_EXEC_PERSIST_AGENT_STATE="$TEST_DIR/srv/ctrl-exec/agent-state"
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/bin/ced"
  export CTRL_EXEC_AGENT="$TEST_DIR/bin/ctrl-exec-agent"
  export HPS_SYSTEM_BASE="$TEST_DIR/sys"
  export CE_IPS_AGENT_PAIR_WAIT=2
  export FAKE_REQID=ab12cd34

  # ced: the CA fingerprint, the pairing window, one pending request, approve
  # (which "delivers" the certificate, as the agent's background poll would).
  cat > "$CTRL_EXEC_DISPATCHER" <<EOT
#!/bin/bash
case "\$1" in
  ca-fingerprint) echo "$FPR" ;;
  pairing-mode) echo "ced pairing-mode \$2" >> "\$CALLS" ;;
  list-requests)
    echo "ID        HOSTNAME   SOURCE IP"
    echo "\$FAKE_REQID \${FAKE_REQ_HOST:-ips.lab.hps} \${FAKE_REQ_SRC:-127.0.0.1} - 123456 (v2)" ;;
  approve)
    echo "ced \$*" >> "\$CALLS"
    [[ -n "\${FAKE_NO_CERT:-}" ]] || echo cert > "\$CTRL_EXEC_IPS_AGENT_ETC/agent.crt" ;;
esac
EOT
  cat > "$CTRL_EXEC_AGENT" <<'EOT'
#!/bin/bash
echo "agent $*" >> "$CALLS"
[[ "$1" == request-pairing ]] && echo "$FAKE_REQID"
exit 0
EOT
  cat > "$TEST_DIR/sys/bin/hps-operator" <<'EOT'
#!/bin/bash
echo "hps-operator $*" >> "$CALLS"
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER" "$CTRL_EXEC_AGENT" "$TEST_DIR/sys/bin/hps-operator"

  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  _ce_is_root() { return 0; }
  cluster_dns_domain() { echo "${FAKE_DOMAIN-lab.hps}"; }
  fqdn_join() { printf '%s.%s\n' "$1" "$2"; }
  ce_agent_names() { cat "$TEST_DIR/agents" 2> /dev/null; }
  _ce_tarball_install() { echo "tarball $1" >> "$CALLS"; }
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "agent.conf: the agent port, 127.0.0.1 only, the ips-admin script dir and profile" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  c="$CTRL_EXEC_IPS_AGENT_ETC/agent.conf"
  grep -qx 'port = 7446' "$c"
  grep -qx 'allowed_ips = 127.0.0.1' "$c"
  grep -qx "script_dirs = $TEST_DIR/sys/ips-admin" "$c"
  grep -qx '\[profile ips-admin\]' "$c"
  grep -qx '\[profile default\]' "$c"
  run ! grep -q '^executor_socket' "$c"
}

@test "scripts.conf: every ips-admin script under profile ips-admin, the two credential paths input=raw" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  s="$CTRL_EXEC_IPS_AGENT_ETC/scripts.conf"
  [ "$(grep -c ' profile=ips-admin' "$s")" -eq 13 ]
  grep -qx "hps-onboard = $TEST_DIR/sys/ips-admin/hps-onboard profile=ips-admin" "$s"
  grep -qx "hps-bmc-credential = $TEST_DIR/sys/ips-admin/hps-bmc-credential profile=ips-admin input=raw" "$s"
  grep -qx "hps-cluster-config-apply = $TEST_DIR/sys/ips-admin/hps-cluster-config-apply profile=ips-admin input=raw" "$s"
  [ "$(grep -c 'input=raw' "$s")" -eq 2 ]
}

@test "the auth hook's hps-operator.conf names the agent and the scripts" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  h="$CTRL_EXEC_DISPATCHER_CONF_DIR/hps-operator.conf"
  grep -qx 'ips_agent = ips.lab.hps' "$h"
  grep -q '^scripts = hps-onboard hps-cluster-config .*ips-syslog-forward$' "$h"
}

@test "an unpaired agent is paired: window, verified request under ips.<domain>, guarded approve, window closed" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'ced pairing-mode start' "$CALLS"
  grep -qx "agent request-pairing --dispatcher 127.0.0.1 --dispatcher-fingerprint $FPR --name ips.lab.hps --background --timeout 120" "$CALLS"
  grep -qx 'ced approve ab12cd34 --ip 127.0.0.1 --lookup-by ip --agent-port 7446' "$CALLS"
  grep -qx 'ced pairing-mode stop' "$CALLS"
  grep -q 'ips.lab.hps paired' "$TEST_DIR/hps.log"
}

@test "a request under another name is not approved" {
  FAKE_REQ_HOST=tch-001.lab.hps run ce_ips_agent_bring_up
  [ "$status" -eq 1 ]
  run ! grep -q 'ced approve' "$CALLS"
  grep -q "is for 'tch-001.lab.hps', not ips.lab.hps" "$TEST_DIR/hps.log"
  grep -qx 'ced pairing-mode stop' "$CALLS"
}

@test "a request from another address is not approved" {
  FAKE_REQ_SRC=10.99.1.77 run ce_ips_agent_bring_up
  [ "$status" -eq 1 ]
  run ! grep -q 'ced approve' "$CALLS"
  grep -q "came from '10.99.1.77', not 127.0.0.1" "$TEST_DIR/hps.log"
}

@test "an approval with no certificate arriving fails" {
  FAKE_NO_CERT=1 run ce_ips_agent_bring_up
  [ "$status" -eq 1 ]
  grep -q 'no certificate arrived' "$TEST_DIR/hps.log"
}

@test "a paired agent the dispatcher lists is not paired again" {
  mkdir -p "$CTRL_EXEC_PERSIST_AGENT_CONF"
  echo cert > "$CTRL_EXEC_PERSIST_AGENT_CONF/agent.crt"
  echo ips.lab.hps > "$TEST_DIR/agents"
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  run ! grep -q 'request-pairing' "$CALLS"
}

@test "a certificate the dispatcher does not list is paired again" {
  mkdir -p "$CTRL_EXEC_PERSIST_AGENT_CONF"
  echo cert > "$CTRL_EXEC_PERSIST_AGENT_CONF/agent.crt"
  echo tch-001.lab.hps > "$TEST_DIR/agents"
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  grep -q 'request-pairing' "$CALLS"
}

@test "the agent config and state live under /srv" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  [ -L "$CTRL_EXEC_IPS_AGENT_ETC" ]
  [ "$(readlink "$CTRL_EXEC_IPS_AGENT_ETC")" = "$CTRL_EXEC_PERSIST_AGENT_CONF" ]
  [ "$(readlink "$CTRL_EXEC_IPS_AGENT_STATE")" = "$CTRL_EXEC_PERSIST_AGENT_STATE" ]
  [ -f "$CTRL_EXEC_PERSIST_AGENT_CONF/agent.conf" ]
}

@test "the agent is installed from the tarball only when absent" {
  run ce_ips_agent_bring_up
  run ! grep -q '^tarball' "$CALLS"
  export CTRL_EXEC_AGENT="$TEST_DIR/bin/not-installed"
  _ce_tarball_install() { echo "tarball $1" >> "$CALLS"; cp "$TEST_DIR/bin/ctrl-exec-agent" "$CTRL_EXEC_AGENT"; }
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'tarball --agent' "$CALLS"
}

@test "bring-up restores the hook's credential digests (hps-operator export)" {
  run ce_ips_agent_bring_up
  [ "$status" -eq 0 ]
  grep -qx 'hps-operator export' "$CALLS"
}

@test "no cluster DNS domain: nothing is written, the bring-up fails" {
  FAKE_DOMAIN="" run ce_ips_agent_bring_up
  [ "$status" -eq 1 ]
  [ ! -e "$CTRL_EXEC_IPS_AGENT_ETC" ]
  grep -q 'no network_dns_domain' "$TEST_DIR/hps.log"
}

@test "supervisord runs the agent as root, logging to syslog, once" {
  mkdir -p "$TEST_DIR/services" "$TEST_DIR/log"
  : > "$TEST_DIR/supervisord.conf"
  hps_get_config() {
    case "$1" in
      cluster_services) echo "$TEST_DIR/services" ;;
      active_cluster) echo lab ;;
      supervisord_conf) echo "$TEST_DIR/supervisord.conf" ;;
      *) return 1 ;;
    esac
  }
  install_opensvc_foreground_wrapper() { :; }
  _get_hps_environment() { echo "HPS_X=1"; }
  export HPS_LOG="$TEST_DIR/log"
  source "$ROOT/lib/functions.d/configure-supervisor.sh"
  supervisor_configure_core_services
  supervisor_configure_core_services
  [ "$(grep -c '^\[program:ctrl-exec-agent\]' "$TEST_DIR/supervisord.conf")" -eq 1 ]
  b=$(awk '$0 == "[program:ctrl-exec-agent]" {f=1; next} /^\[/ {f=0} f' "$TEST_DIR/supervisord.conf")
  [[ "$b" == *"exec ctrl-exec-agent serve'"* ]]
  [[ "$b" == *"ctrl-exec-agent promote-cert"* ]]
  [[ "$b" == *"user=root"* ]]
  [[ "$b" == *"stdout_logfile=syslog"* ]]
  [[ "$b" == *"stderr_logfile=syslog"* ]]
}

@test "run-hps.sh brings the agent up after the dispatcher and before the services, with a cluster only" {
  f="$ROOT/scripts/run-hps.sh"
  d=$(grep -n 'ce_dispatcher_bring_up ||' "$f" | cut -d: -f1)
  a=$(grep -n 'ce_ips_agent_bring_up ||' "$f" | cut -d: -f1)
  s=$(grep -n '_supervisor_pre_start ||' "$f" | cut -d: -f1)
  [ "$d" -lt "$a" ]
  [ "$a" -lt "$s" ]
  grep -q 'CLUSTER_CONFIGURED}" == "true" ]] && declare -f ce_ips_agent_bring_up' "$f"
}
