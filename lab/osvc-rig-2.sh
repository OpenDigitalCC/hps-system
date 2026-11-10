#!/usr/bin/env bash
# osvc-rig-2.sh - rig test 2 of plans/opensvc-finding.md: om node drain,
# om cluster thaw and a plain om <obj> start never start an instance on a peer
# when the object has orchestrate = no and nodes = the one owner node.
#
#   bash lab/osvc-rig-2.sh <host> [<peer>]    (MAC or registry HOSTNAME each)
#
# Run on the IPS (lab only). Without <peer> only the owner node is checked and
# the peer checks are SKIPped: that does NOT answer the finding's question.
# With <peer>, both daemons must already be up and see each other. The three
# commands run through the lab-only node script osvc-rig-probe, which refuses
# unless rig objects are the only objects on the node. rig0 is a trivial
# fs.flag resource; it is deleted at the end and the owner's frozen state is
# put back as found. Exit 1 if any check failed.
set -euo pipefail

HOST="${1:?usage: osvc-rig-2.sh <host> [<peer>]}"
PEER="${2:-}"
# shellcheck source=lab/osvc-rig-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/osvc-rig-lib.sh"

say "== rig 2 on $HOST${PEER:+ with peer $PEER}: drain, cluster thaw, plain start"
NODE=$(self_name "$HOST")
if [[ -z "$NODE" ]]; then
  say "FAIL: osvc-status gave no node name (daemon not running?)"
  exit 1
fi
PEER_NODE=""
if [[ -n "$PEER" ]]; then
  PEER_NODE=$(self_name "$PEER")
  if [[ -z "$PEER_NODE" ]]; then
    say "FAIL: the peer $PEER gave no node name (daemon not running?)"
    exit 1
  fi
  chk "owner sees its peers beating before the test" peers_ok "$HOST"
fi
WAS_FROZEN=no
if is_frozen "$HOST"; then
  WAS_FROZEN=yes
fi
say "owner $NODE, peer ${PEER_NODE:-none}, owner frozen at the start: $WAS_FROZEN"

# peer_idle <state>: absent, down or n/a.
peer_idle() {
  [[ "$1" == absent || "$1" == down || "$1" == "n/a" ]]
}

# no_peer_instance <label>: $RIG_OBJ is not up on the peer (as the peer sees it).
no_peer_instance() {
  if [[ -z "$PEER_NODE" ]]; then
    skip "$1 (no peer given)"
    return 0
  fi
  chk "$1: $RIG_OBJ never up on the peer" stays_not "$PEER" "$PEER_NODE" "$RIG_OBJ" up
  local seen
  seen=$(avail_on "$PEER" "$PEER_NODE" "$RIG_OBJ")
  say "   peer instance state: $seen"
  chk "$1: peer holds no running instance (state $seen)" peer_idle "$seen"
}

create_rig "$HOST" "$NODE"

say "== case A: drain with the object running on the owner"
node_run "$HOST" osvc-object-start "$RIG_OBJ"
verdict "start --local on the owner" "$LAST_RC"
node_run "$HOST" osvc-rig-probe drain
verdict "om node drain accepted" "$LAST_RC"
chk "drain stopped $RIG_OBJ on the owner" wait_avail "$HOST" "$NODE" "$RIG_OBJ" down
no_peer_instance "after drain"

say "== case B: cluster thaw"
node_run "$HOST" osvc-rig-probe thaw-cluster
verdict "om cluster thaw accepted" "$LAST_RC"
chk "cluster thaw does not restart $RIG_OBJ on the owner (orchestrate = no)" stays_not "$HOST" "$NODE" "$RIG_OBJ" up
no_peer_instance "after cluster thaw"

say "== case C: plain om <obj> start"
node_run "$HOST" osvc-rig-probe plain-start "$RIG_OBJ"
say "   (the exit status of a plain start is recorded, not judged: only the peer matters)"
no_peer_instance "after a plain start"
node_run "$HOST" osvc-object-stop "$RIG_OBJ"

say "== cleanup"
node_run "$HOST" osvc-object-delete "$RIG_OBJ"
verdict "cleanup: $RIG_OBJ deleted" "$LAST_RC"
if [[ "$WAS_FROZEN" == no ]]; then
  node_run "$HOST" osvc-thaw
  verdict "owner thawed again" "$LAST_RC"
fi
say "FAILURE TEXT if a peer check failed: \"OpenSVC v3 can disable orchestration per object, but <command> started a service on a peer, so it cannot be trusted as a no-failover manager.\""
summary_line
