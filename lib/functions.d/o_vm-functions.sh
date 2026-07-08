


# shellcheck shell=bash
#===============================================================================
# o_vm_create
# -----------
# Create and start a VM on a TCH node, executing the node-side creation over
# ctrl-exec (ADR 0001). OpenSVC is retained only for the health gate that
# selects a placement-ready node; the exec transport is no longer a transient
# OpenSVC task service.
#
# Usage:
#   o_vm_create <vm_identifier> <target_node> [title] [description]
#
# Parameters:
#   vm_identifier - Unique VM identifier/GUID (required)
#   target_node   - TCH node name / ctrl-exec agent host (e.g. "tch-001")
#   title         - Optional VM title passed to n_vm_create
#   description   - Optional VM description passed to n_vm_create
#
# Behaviour:
#   Step 1: Validate parameters
#   Step 2: Validate target node health via OpenSVC (o_vm_validate_node)
#   Step 3: Run 'hps-node vm-create <id> [title] [desc]' on the node over mTLS
#
# Dependencies:
#   - o_vm_validate_node: OpenSVC health/placement gate (retained role)
#   - ce_run: ctrl-exec execution wrapper (lib/functions.d/ctrl-exec-functions.sh)
#   - n_vm_create: node-side VM creation, invoked via the hps-node plugin
#
# Returns:
#   0: VM created
#   1: Parameter validation failure
#   2: Target node not found in cluster
#   3: Target node OpenSVC daemon not running
#   4: Target node frozen or in error state
#   5: ctrl-exec execution failure (VM not created)
#
# Example usage:
#   node=$(o_vm_select_node 4 8192) && o_vm_create "abc-123-def" "$node"
#
#===============================================================================
o_vm_create() {
  local vm_identifier="$1"
  local target_node="$2"
  local vm_title="${3:-}"
  local vm_description="${4:-}"

  # Step 1: Parameter Validation
  if [ -z "$vm_identifier" ] || [ -z "$target_node" ]; then
    o_log "o_vm_create: Usage: o_vm_create <vm_identifier> <target_node> [title] [description]" "err"
    return 1
  fi

  # Step 2: Validate Target Node (OpenSVC health/placement gate - retained role)
  o_log "Validating target node ${target_node}" "info"

  o_vm_validate_node "${target_node}"
  local validate_result=$?

  if [ $validate_result -ne 0 ]; then
    case $validate_result in
      2)
        o_log "Target node ${target_node} not found in cluster" "err"
        return 2
        ;;
      3)
        o_log "OpenSVC daemon not running on target node ${target_node}" "err"
        return 3
        ;;
      4)
        o_log "Target node ${target_node} is frozen or in error state" "err"
        return 4
        ;;
      *)
        o_log "Node validation failed with unknown error: ${validate_result}" "err"
        return 2
        ;;
    esac
  fi

  # Step 3: Execute node-side creation over ctrl-exec.
  o_log "Creating VM ${vm_identifier} on node ${target_node} via ctrl-exec" "info"

  if ! ce_run "${target_node}" hps-node vm-create "${vm_identifier}" "${vm_title}" "${vm_description}"; then
    o_log "VM creation failed on ${target_node} for ${vm_identifier}" "err"
    return 5
  fi

  o_log "Successfully created VM ${vm_identifier} on ${target_node}" "info"
  return 0
}


#===============================================================================
# o_vm_validate_node
# ------------------
# Validate that a node exists in the cluster and is healthy for VM operations.
#
# Usage:
#   o_vm_validate_node <node_name>
#
# Parameters:
#   node_name - Node name to validate (required)
#
# Behavior:
#   1. Check node exists in OpenSVC cluster (om node ls)
#   2. Check node is reachable via heartbeat generation counters
#   3. Check node is not frozen
#
# Note:
#   Uses official OpenSVC status.gen API to check connectivity.
#   "cluster.node.<node>.status.gen is reliable" - OpenSVC team
#   If the gen object exists and has peer entries, the node is alive.
#
# Returns:
#   0: Node is valid and healthy
#   1: Parameter validation failure
#   2: Node does not exist in cluster
#   3: Node not reachable (no heartbeat gen data)
#   4: Node is frozen
#
# Example usage:
#   if o_vm_validate_node "tch-001"; then
#     o_vm_create "abc-123" "tch-001"
#   else
#     echo "Node not ready for VM operations"
#   fi
#
#===============================================================================
o_vm_validate_node() {
  local node_name="$1"
  
  # Parameter validation
  if [ -z "$node_name" ]; then
    o_log "o_vm_validate_node: node_name is required" "err"
    return 1
  fi
  
  o_log "Validating node ${node_name} for VM operations" "info"
  
  # Check 1: Node exists in cluster
  if ! om node ls 2>/dev/null | grep -qx "${node_name}"; then
    o_log "Node ${node_name} not found in cluster" "err"
    return 2
  fi
  
  o_log "Node ${node_name} exists in cluster" "debug"
  
  # Check 2: Node reachability using status.gen (official method)
  # The status.gen object contains generation counters for heartbeat with peers
  # If it exists and has entries, the node is participating in cluster heartbeat
  local gen_data
  gen_data=$(om daemon status -o json 2>/dev/null | jq -r ".cluster.node.\"${node_name}\".status.gen // empty" 2>/dev/null)
  
  if [ -z "$gen_data" ] || [ "$gen_data" = "null" ]; then
    o_log "Node ${node_name} not reachable (no heartbeat gen data)" "err"
    return 3
  fi
  
  # Count how many peer gen entries exist
  local gen_count
  gen_count=$(echo "$gen_data" | jq 'length' 2>/dev/null)
  
  if [ -z "$gen_count" ] || [ "$gen_count" -eq 0 ]; then
    o_log "Node ${node_name} not reachable (empty heartbeat gen data)" "err"
    return 3
  fi
  
  o_log "Node ${node_name} is reachable (${gen_count} heartbeat peers)" "debug"
  
  # Check 3: Node frozen state
  # Look for: cluster.node.<node>.status.frozen_at which indicates when node was frozen
  # If this field has a real timestamp (not zero value), node is frozen
  # Zero value timestamp is "0001-01-01T00:00:00Z" which means unfrozen
  local frozen_at
  frozen_at=$(om daemon status -o json 2>/dev/null | jq -r ".cluster.node.\"${node_name}\".status.frozen_at // empty" 2>/dev/null)
  
  if [ -n "$frozen_at" ] && [ "$frozen_at" != "null" ] && [ "$frozen_at" != "0001-01-01T00:00:00Z" ]; then
    o_log "Node ${node_name} is frozen (frozen_at: ${frozen_at})" "err"
    return 4
  fi
  
  o_log "Node ${node_name} is not frozen" "debug"
  
  # All checks passed
  o_log "Node ${node_name} validated successfully" "info"
  return 0
}


#===============================================================================
# o_vm_validate_node_quiet
# -------------------------
# Validate node without logging (for use in selection logic).
#
# Usage:
#   o_vm_validate_node_quiet <node_name>
#
# Parameters:
#   node_name - Node name to validate (required)
#
# Behavior:
#   Same validation as o_vm_validate_node but without logging.
#   Useful for filtering node lists or selection algorithms.
#
# Returns:
#   Same as o_vm_validate_node (0-4)
#
# Example usage:
#   for node in $(o_vm_get_nodes_by_tag "tch"); do
#     if o_vm_validate_node_quiet "$node"; then
#       available_nodes="${available_nodes} ${node}"
#     fi
#   done
#
#===============================================================================
o_vm_validate_node_quiet() {
  local node_name="$1"
  
  # Parameter validation
  if [ -z "$node_name" ]; then
    return 1
  fi
  
  # Check 1: Node exists in cluster
  if ! om node ls 2>/dev/null | grep -qx "${node_name}"; then
    return 2
  fi
  
  # Check 2: Node reachability using status.gen
  local gen_data
  gen_data=$(om daemon status -o json 2>/dev/null | jq -r ".cluster.node.\"${node_name}\".status.gen // empty" 2>/dev/null)
  
  if [ -z "$gen_data" ] || [ "$gen_data" = "null" ]; then
    return 3
  fi
  
  local gen_count
  gen_count=$(echo "$gen_data" | jq 'length' 2>/dev/null)
  
  if [ -z "$gen_count" ] || [ "$gen_count" -eq 0 ]; then
    return 3
  fi
  
  # Check 3: Node frozen state (ignore zero value timestamp)
  local frozen_at
  frozen_at=$(om daemon status -o json 2>/dev/null | jq -r ".cluster.node.\"${node_name}\".status.frozen_at // empty" 2>/dev/null)
  
  if [ -n "$frozen_at" ] && [ "$frozen_at" != "null" ] && [ "$frozen_at" != "0001-01-01T00:00:00Z" ]; then
    return 4
  fi
  
  return 0
}


#===============================================================================
# o_vm_get_healthy_nodes
# ----------------------
# Get list of healthy nodes from a given node list.
#
# Usage:
#   o_vm_get_healthy_nodes <node_list>
#
# Parameters:
#   node_list - Space-separated list of node names (required)
#
# Behavior:
#   - Validates each node using o_vm_validate_node_quiet
#   - Returns only nodes that pass all health checks
#   - Logs count of healthy vs total nodes
#
# Returns:
#   0: Success (outputs healthy nodes to stdout, even if empty)
#   1: Parameter validation failure
#
# Output:
#   Space-separated list of healthy node names to stdout
#
# Example usage:
#   all_nodes=$(o_vm_get_nodes_by_tag "tch")
#   healthy_nodes=$(o_vm_get_healthy_nodes "$all_nodes")
#   if [ -n "$healthy_nodes" ]; then
#     node=$(echo "$healthy_nodes" | awk '{print $1}')
#   fi
#
#===============================================================================
o_vm_get_healthy_nodes() {
  local node_list="$1"
  
  if [ -z "$node_list" ]; then
    o_log "o_vm_get_healthy_nodes: node_list is required" "err"
    return 1
  fi
  
  local healthy_nodes=""
  local total_count=0
  local healthy_count=0
  
  for node in $node_list; do
    [ -z "$node" ] && continue
    total_count=$((total_count + 1))
    
    if o_vm_validate_node_quiet "$node"; then
      healthy_nodes="${healthy_nodes} ${node}"
      healthy_count=$((healthy_count + 1))
    fi
  done
  
  # Trim leading space
  healthy_nodes=$(echo "$healthy_nodes" | xargs)
  
  o_log "Found ${healthy_count}/${total_count} healthy nodes" "info"
  
  # Output to stdout
  if [ -n "$healthy_nodes" ]; then
    echo "$healthy_nodes"
  fi
  
  return 0
}


