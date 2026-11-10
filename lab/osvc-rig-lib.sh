#!/usr/bin/env bash
# osvc-rig-lib.sh - helpers shared by osvc-rig-1.sh and osvc-rig-2.sh.
# Sourced on the IPS (lab only). Every node action is an allowlisted node script
# called through scripts/hps-run.sh; nothing here touches a node any other way.
#
# Environment: HPS_RUN (default <hps-system>/scripts/hps-run.sh), RIG_OBJ
# (default rig0), RIG_WAIT (seconds a state change is awaited, default 30),
# RIG_POLL (seconds between looks, default 2).

RIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${HPS_RUN:=$RIG_DIR/../scripts/hps-run.sh}"
: "${RIG_OBJ:=rig0}"
: "${RIG_WAIT:=30}"
: "${RIG_POLL:=2}"

PASS=0
FAIL=0
SKIP=0
LAST_OUT=""
LAST_RC=0

say() {
  printf '%s\n' "$*"
}

# node_run <host> <script> [args...]: run a node script, keep output and status.
node_run() {
  local host="$1" script="$2"
  shift 2
  say "-- $host: $script $*"
  set +e
  LAST_OUT=$(bash "$HPS_RUN" "$host" "$script" "$@" 2>&1)
  LAST_RC=$?
  set -e
  printf '%s\n' "$LAST_OUT" | sed 's/^/   | /'
  say "   exit $LAST_RC"
}

# verdict <label> <0|1>: PASS when the condition status is 0.
verdict() {
  if [[ "$2" -eq 0 ]]; then
    say "PASS: $1"
    PASS=$((PASS + 1))
  else
    say "FAIL: $1"
    FAIL=$((FAIL + 1))
  fi
}

# chk <label> <command...>: PASS when the command succeeds.
chk() {
  local label="$1"
  shift
  if "$@"; then
    verdict "$label" 0
  else
    verdict "$label" 1
  fi
}

# is_frozen <host>: the node reports frozen=yes.
is_frozen() {
  summary "$1" | grep -q 'frozen=yes'
}

# peers_ok <host>: no stale peer in the summary line.
peers_ok() {
  summary "$1" | grep -q 'stale=-'
}

skip() {
  say "SKIP: $1"
  SKIP=$((SKIP + 1))
}

# status_json <host>: the om daemon status JSON of the node (empty on failure).
status_json() {
  set +e
  bash "$HPS_RUN" "$1" osvc-status 2> /dev/null | awk '/^== om daemon status/ {on=1; next} /^== om mon/ {on=0} on'
  set -e
}

# summary <host>: the OSVC summary line.
summary() {
  set +e
  bash "$HPS_RUN" "$1" osvc-status 2> /dev/null | grep '^OSVC '
  set -e
}

# self_name <host>: the node's name as OpenSVC knows it.
self_name() {
  summary "$1" | awk '{print $2}'
}

# avail_on <host> <node> <obj>: availability of the object's instance on <node>
# as <host> sees it: up, down, warn, n/a ..., or "absent" when no instance.
avail_on() {
  status_json "$1" | jq -r --arg n "$2" --arg o "$3" '
    (.cluster.node[$n].instance // {}) | to_entries
    | map(select(.key | test("(^|/)" + $o + "$"))) | .[0].value.status.avail // "absent"'
}

# wait_avail <host> <node> <obj> <state>: wait up to RIG_WAIT s for the state.
wait_avail() {
  local i state="" n=$((RIG_WAIT / RIG_POLL))
  for ((i = 0; i <= n; i++)); do
    state=$(avail_on "$1" "$2" "$3")
    if [[ "$state" == "$4" ]]; then
      return 0
    fi
    sleep "$RIG_POLL"
  done
  say "   last seen: $state (wanted $4)"
  return 1
}

# stays_not <host> <node> <obj> <state>: for RIG_WAIT s the instance is never <state>.
stays_not() {
  local i state n=$((RIG_WAIT / RIG_POLL))
  for ((i = 0; i <= n; i++)); do
    state=$(avail_on "$1" "$2" "$3")
    if [[ "$state" == "$4" ]]; then
      say "   $2 showed $3 as $state"
      return 1
    fi
    sleep "$RIG_POLL"
  done
  return 0
}

# create_rig <host> <node>: the throwaway object, pinned to <node>.
create_rig() {
  node_run "$1" osvc-object-set "$RIG_OBJ" "nodes=$2" topology=failover orchestrate=no \
    monitor_action=none placement=none 'fs#1.type=flag'
  verdict "create $RIG_OBJ pinned to $2 with the enforced keywords" "$LAST_RC"
}

summary_line() {
  say "== $PASS passed, $FAIL failed, $SKIP skipped"
  [[ "$FAIL" -eq 0 ]]
}
