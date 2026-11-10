#!/usr/bin/env bash
# osvc-rig-1.sh - rig test 1 of plans/opensvc-finding.md: an explicit
# om <obj> start|stop --local works while the node is frozen, and thawing the
# node does not start the object by itself (orchestrate = no).
#
#   bash lab/osvc-rig-1.sh <host>        (<host>: MAC or registry HOSTNAME)
#
# Run on the IPS (lab only), against ONE node, after hps-osvc deliver <host>
# has started the daemon. Creates the throwaway object rig0 (a trivial fs.flag
# resource), deletes it at the end, and puts the node's frozen state back as it
# found it. It stops and starts nothing but rig0. Output: the node scripts'
# output, then PASS/FAIL per check; exit 1 if any check failed.
set -euo pipefail

HOST="${1:?usage: osvc-rig-1.sh <host>}"
# shellcheck source=lab/osvc-rig-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/osvc-rig-lib.sh"

say "== rig 1 on $HOST: --local start/stop under freeze"
NODE=$(self_name "$HOST")
if [[ -z "$NODE" ]]; then
  say "FAIL: osvc-status gave no node name (daemon not running?)"
  exit 1
fi
say "node name: $NODE"
WAS_FROZEN=no
if is_frozen "$HOST"; then
  WAS_FROZEN=yes
fi
say "node frozen at the start: $WAS_FROZEN"

create_rig "$HOST" "$NODE"

node_run "$HOST" osvc-freeze
verdict "node freeze accepted" "$LAST_RC"
chk "node reports frozen=yes" is_frozen "$HOST"

node_run "$HOST" osvc-object-start "$RIG_OBJ"
verdict "start --local succeeds on a frozen node" "$LAST_RC"
chk "$RIG_OBJ is up after the --local start (frozen node)" wait_avail "$HOST" "$NODE" "$RIG_OBJ" up

node_run "$HOST" osvc-object-stop "$RIG_OBJ"
verdict "stop --local succeeds on a frozen node" "$LAST_RC"
chk "$RIG_OBJ is down after the --local stop (frozen node)" wait_avail "$HOST" "$NODE" "$RIG_OBJ" down

if [[ "$WAS_FROZEN" == no ]]; then
  node_run "$HOST" osvc-thaw
  verdict "node thaw accepted" "$LAST_RC"
  chk "thawing the node does not start $RIG_OBJ (orchestrate = no)" stays_not "$HOST" "$NODE" "$RIG_OBJ" up
else
  skip "thaw check: the node was frozen before the test and stays so"
fi

node_run "$HOST" osvc-object-delete "$RIG_OBJ"
verdict "cleanup: $RIG_OBJ deleted" "$LAST_RC"
say "NOT COVERED HERE: a node reboot must not auto-start objects (reboot by hand, then osvc-status)."
summary_line
