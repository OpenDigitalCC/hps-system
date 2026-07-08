#!/bin/bash
#
# Container-local integration test for the ctrl-exec enrolment flow.
#
# Runs a REAL ctrl-exec dispatcher and agent on localhost and drives the HPS
# registry-bound approver (ce_approve_pair_request) against the real pending
# request - no docker, no root, no provisioning network. ctrl-exec's hardcoded
# /etc and /var/lib paths are made writable by running inside a rootless
# user+mount namespace (unshare -rm) with tmpfs mounted over them.
#
# Exercises: dispatcher CA setup, agent pairing, registry-bound auto-approval,
# a rogue request refusal, and 'ced run hps-node -- ping' over mTLS.
#
# Usage: bash scripts/tests/integration/ctrl-exec-pairing.sh
# Requires: perl, IO::Socket::SSL, JSON, openssl, unshare (rootless userns).

set -u

CE_SRC="${CE_SRC:-/srv/projects/ctrl-exec}"
HPS_SRC="${HPS_SRC:-/srv/projects/hps/hps-system}"

# Re-exec into a rootless user+mount namespace so the hardcoded ctrl-exec paths
# are writable without real root.
if [[ "${CE_IT_NS:-0}" != "1" ]]; then
  export CE_IT_NS=1 CE_SRC HPS_SRC
  exec unshare -rm bash "$0" "$@"
fi

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }

DISP="$CE_SRC/bin/ctrl-exec-dispatcher"
AGENT="$CE_SRC/bin/ctrl-exec-agent"
DHOST="127.0.0.1"
PAIR_PORT=7444
OP_PORT=7443

cleanup() {
  [[ -n "${PAIR_PID:-}" ]] && kill "$PAIR_PID" 2>/dev/null
  [[ -n "${SERVE_PID:-}" ]] && kill "$SERVE_PID" 2>/dev/null
  wait 2>/dev/null
  [[ -n "${SCRATCH:-}" ]] && rm -rf "$SCRATCH" 2>/dev/null
}
trap cleanup EXIT

echo "# ctrl-exec enrolment integration test"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# --- writable scratch over the hardcoded paths ------------------------------
# The rootless userns maps us to uid 0, but /etc and /var/lib are owned by the
# real root and stay read-only. Bind a writable copy of /etc over /etc (keeps
# /etc/ssl etc. for openssl/perl) and a fresh tmpfs over /var/lib, then create
# the ctrl-exec dirs the binaries hardcode.
SCRATCH="/tmp/ce-it-$$"
mkdir -p "$SCRATCH/sbin"
cp -a /etc "$SCRATCH/etc" 2>/dev/null
mount --bind "$SCRATCH/etc" /etc
mount -t tmpfs none /var/lib
mkdir -p /etc/ctrl-exec /etc/ctrl-exec-agent /var/lib/ctrl-exec /var/lib/ctrl-exec-agent
# The agent scrubs the environment before exec, so hps-node reads its default
# paths. Make /usr/local/{sbin,lib} writable and place the plugin and a stub
# node bundle at the real deployed locations, so the test exercises them.
mount -t tmpfs none /usr/local/sbin
mount -t tmpfs none /usr/local/lib

# --- dispatcher config + CA -------------------------------------------------
cat > /etc/ctrl-exec/ctrl-exec.conf <<EOF
cert = /etc/ctrl-exec/dispatcher.crt
key  = /etc/ctrl-exec/dispatcher.key
ca   = /etc/ctrl-exec/ca.crt
EOF

"$DISP" setup-ca >/dev/null 2>&1
"$DISP" setup-ctrl-exec >/dev/null 2>&1
if [[ -f /etc/ctrl-exec/ca.crt && -f /etc/ctrl-exec/dispatcher.crt ]]; then
  ok "dispatcher CA and cert initialised"
else
  bad "dispatcher CA setup"; echo "VERDICT: FAIL"; exit 1
fi

# --- agent + hps-node plugin (at the real deployed paths) -------------------
install -m 0750 "$HPS_SRC/node-manager/plugins/hps-node/hps-node.sh" /usr/local/sbin/hps-node
# Stub HPS node bundle so 'hps-node ping' resolves without a PXE node.
cat > /usr/local/lib/hps-bootstrap-lib.sh <<'EOF'
hps_load_node_functions() { :; }
EOF

cat > /etc/ctrl-exec-agent/agent.conf <<EOF
port = $OP_PORT
cert = /etc/ctrl-exec-agent/agent.crt
key  = /etc/ctrl-exec-agent/agent.key
ca   = /etc/ctrl-exec-agent/ca.crt

[profile default]
run_as = root
no_new_privileges = yes
EOF
cat > /etc/ctrl-exec-agent/scripts.conf <<EOF
hps-node = /usr/local/sbin/hps-node
EOF

# --- start the pairing listener ---------------------------------------------
"$DISP" pairing-mode --timeout 120 >/dev/null 2>&1 &
PAIR_PID=$!
for _ in $(seq 1 20); do
  { exec 3<>"/dev/tcp/$DHOST/$PAIR_PORT"; } 2>/dev/null && { exec 3>&-; break; }
  sleep 0.3
done

# --- agent requests pairing (background), we capture the reqid --------------
# Run under setsid so the detached child that holds the pairing socket (and
# receives the signed cert on approval) survives independently of this shell;
# read the reqid the foreground prints from a file.
setsid bash -c "'$AGENT' request-pairing --background --timeout 90 \
  --dispatcher '$DHOST' --lookup-by ip > '$SCRATCH/reqid.out' 2>'$SCRATCH/pair.err'" &
for _ in $(seq 1 30); do [[ -s "$SCRATCH/reqid.out" ]] && break; sleep 0.3; done
REQID="$(tr -dc 'a-f0-9' < "$SCRATCH/reqid.out" 2>/dev/null)"
if [[ -n "$REQID" ]]; then
  ok "agent submitted pairing request (reqid $REQID)"
else
  bad "agent pairing request"; echo "VERDICT: FAIL"; exit 1
fi

# --- drive the HPS registry-bound approver ----------------------------------
# Stub host_registry with a binding that matches the pending request
# (source_ip 127.0.0.1), then call the real approver, which calls real ced.
export CTRL_EXEC_DISPATCHER="$DISP"
export CTRL_EXEC_PAIRING_DIR=/var/lib/ctrl-exec/pairing
TEST_MAC="52:54:00:aa:bb:cc"

hps_log() { :; }
declare -A REG
host_registry() {
  local mac="$1" cmd="$2" key="$3" val="${4:-}"
  case "$cmd" in
    get) [[ -n "${REG[$mac|$key]:-}" ]] && printf '%s\n' "${REG[$mac|$key]}" || return 1 ;;
    set) REG["$mac|$key"]="$val" ;;
  esac
}
# Bind the test MAC to the agent's identity: source_ip in the request is the
# connection peer, 127.0.0.1 here. HOSTNAME left unset (advisory).
REG["$TEST_MAC|STATE"]=INSTALLING
REG["$TEST_MAC|IP"]=127.0.0.1

# shellcheck source=/dev/null
source "$HPS_SRC/lib/functions.d/ctrl-exec-functions.sh"

# Rogue request first: a MAC whose allocated IP does not match the request.
REG["52:54:00:de:ad:00|STATE"]=INSTALLING
REG["52:54:00:de:ad:00|IP"]=10.0.0.99
if ce_approve_pair_request "52:54:00:de:ad:00" "$REQID"; then
  bad "rogue request (wrong IP) was approved"
else
  ok "rogue request (wrong IP) refused"
fi

# Legitimate approval.
if ce_approve_pair_request "$TEST_MAC" "$REQID"; then
  ok "registry-bound approver approved the bound request"
else
  bad "approver rejected a correctly-bound request"
fi

# --- wait for the agent to receive its signed cert --------------------------
for _ in $(seq 1 30); do
  [[ -s /etc/ctrl-exec-agent/agent.crt ]] && break
  sleep 0.5
done
if [[ -s /etc/ctrl-exec-agent/agent.crt ]]; then
  ok "agent received signed certificate"
else
  bad "agent did not receive certificate"; echo "VERDICT: FAIL"; exit 1
fi
kill "$PAIR_PID" 2>/dev/null; PAIR_PID=""

# --- start the agent and run hps-node over mTLS -----------------------------
# Do NOT probe the mTLS port with a raw TCP connect - a non-TLS connection can
# disrupt the agent. Use the proper 'ced ping' as the readiness signal.
"$AGENT" serve > "$SCRATCH/serve.log" 2>&1 &
SERVE_PID=$!

AGENT_HOST="$("$DISP" list-agents --json 2>/dev/null | \
  perl -MJSON -0777 -ne 'my $d=eval{decode_json($_)}; exit unless $d; my @a=ref $d eq "ARRAY"?@$d:@{$d->{agents}//[]}; print $a[0]{hostname}//"" if @a' 2>/dev/null)"
[[ -z "$AGENT_HOST" ]] && AGENT_HOST="$(hostname)"

ready=0
for _ in $(seq 1 30); do
  if "$DISP" ping "$AGENT_HOST" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
if [[ $ready -eq 1 ]]; then
  ok "agent reachable over mTLS (ced ping)"
else
  bad "agent not reachable via ced ping (serve log: $(tr '\n' ' ' < "$SCRATCH/serve.log" | cut -c1-160))"
fi

RUN_OUT="$("$DISP" run "$AGENT_HOST" hps-node -- ping 2>&1)"
if printf '%s' "$RUN_OUT" | grep -q "bundle loaded"; then
  ok "ced run hps-node -- ping executed over mTLS"
else
  bad "ced run hps-node -- ping"
  echo "    run output: $(printf '%s' "$RUN_OUT" | tr '\n' ' ' | cut -c1-200)"
  echo "    serve log:  $(tr '\n' ' ' < "$SCRATCH/serve.log" | cut -c1-200)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -eq 0 ]]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[[ $FAIL -eq 0 ]]
