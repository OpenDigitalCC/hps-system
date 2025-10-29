


#===============================================================================
# o_vm_create
# -----------
# Create and start a VM on specified TCH node using transient OpenSVC service.
#
# Usage:
#   o_vm_create <vm_identifier> <target_node>
#
# Parameters:
#   vm_identifier - Unique VM identifier/GUID (required)
#   target_node   - TCH node name (e.g., "tch-001") (required)
#
# Behavior:
#   Step 1: Validate parameters (vm_identifier and target_node not empty)
#   Step 2: Validate target node is healthy and ready
#   Step 3: Log operation start
#   Step 4: Create transient OpenSVC service named "vm-ops-create-${vm_identifier}"
#           Service nodes: "ips ${target_node}" (IPS for management only)
#   Step 5: Add task that executes "n_vm_create ${vm_identifier}" on target_node
#   Step 6: Wait for service instance to be available on target node (max 30s)
#   Step 7: Execute the task via o_task_run on target_node
#   Step 8: Delete the transient service (cleanup)
#   Step 9: Return appropriate exit code based on results
#
# Notes:
#   - IPS is included in service nodes for management/cleanup only
#   - Task always runs on target_node, never on IPS
#   - 30-second timeout for instance availability
#   - Node validation ensures OpenSVC daemon is running and healthy
#
# Dependencies:
#   - o_vm_validate_node: Validate node health and availability
#   - o_task_create: Create OpenSVC service with task
#   - o_task_run: Execute task on target node
#   - o_task_delete: Delete OpenSVC service
#   - o_log: System logging
#   - n_vm_create: Node-side VM creation function (called by task)
#
# Returns:
#   0: Complete success (VM created, service cleaned)
#   1: Parameter validation failure
#   2: Target node validation failure (not in cluster)
#   3: Target node not healthy (daemon not running)
#   4: Target node frozen or in error state
#   5: Task service creation failure
#   6: Instance availability timeout (service created but not ready on target node)
#   7: Task execution failure (VM not created, service cleaned)
#   8: Task succeeded but cleanup failed (VM created, orphaned service - EXCEPTIONAL)
#   9: Task failed AND cleanup failed (VM not created, orphaned service - EXCEPTIONAL)
#
# Exceptional States (codes 8, 9):
#   - Indicate inconsistent system state
#   - Require manual investigation
#   - Orphaned service may need manual deletion: om vm-ops-create-<vm_id> purge
#   - Check OpenSVC daemon logs for cleanup failure reason
#
# Example usage:
#   # Basic usage with validation
#   if o_vm_create "abc-123-def" "tch-001"; then
#     echo "VM created successfully"
#   else
#     exit_code=$?
#     case $exit_code in
#       2|3|4) echo "Target node not healthy" ;;
#       5) echo "Failed to create service" ;;
#       6) echo "Timeout waiting for service" ;;
#       7) echo "VM creation failed" ;;
#       8|9) echo "CRITICAL: Orphaned service requires manual cleanup" ;;
#     esac
#   fi
#
#   # With node selection
#   vm_id="abc-123-def"
#   node=$(o_vm_select_node 4 8192)
#   if [ $? -eq 0 ]; then
#     o_vm_create "$vm_id" "$node"
#   fi
#
#===============================================================================
o_vm_create() {
  local vm_identifier="$1"
  local target_node="$2"
  
  # Step 1: Parameter Validation
  if [ $# -ne 2 ]; then
    o_log "o_vm_create: Usage: o_vm_create <vm_identifier> <target_node>" "err"
    return 1
  fi
  
  if [ -z "$vm_identifier" ]; then
    o_log "o_vm_create: vm_identifier cannot be empty" "err"
    return 1
  fi
  
  if [ -z "$target_node" ]; then
    o_log "o_vm_create: target_node cannot be empty" "err"
    return 1
  fi
  
  # Step 2: Validate Target Node
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
  
  # Step 3: Log Operation Start
  o_log "Creating VM ${vm_identifier} on node ${target_node}" "info"
  
  # Step 4: Define Service Name
  local service_name="vm-ops-create-${vm_identifier}"
  
  # Step 5: Create OpenSVC Service with Task
  # Include IPS in nodes for management, but task will only run on target_node
  o_log "Creating task service ${service_name} (nodes: ips ${target_node})" "info"
  
  o_task_create "${service_name}" "create" "n_vm_create ${vm_identifier}" "ips ${target_node}"
  local create_result=$?
  
  if [ $create_result -ne 0 ]; then
    o_log "Failed to create task service for VM ${vm_identifier}" "err"
    return 5
  fi
  
  # Step 6: Wait for Instance Availability on Target Node
  o_log "Waiting for service instance on ${target_node} (max 30s)" "info"
  
  local max_wait=30
  local waited=0
  local instance_ready=false
  
  while [ $waited -lt $max_wait ]; do
    if om "$service_name" instance ls 2>/dev/null | grep -q "${target_node}"; then
      instance_ready=true
      o_log "Service instance available on ${target_node} (${waited}s)" "info"
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  
  if [ "$instance_ready" = false ]; then
    o_log "Timeout waiting for service instance on ${target_node}" "err"
    o_log "Service may not have propagated to target node" "err"
    
    # Attempt cleanup even after timeout
    o_task_delete "${service_name}"
    return 6
  fi
  
  # Step 7: Execute the Task
  o_log "Executing VM creation task for ${vm_identifier} on ${target_node}" "info"
  
  o_task_run "${service_name}" "create" "${target_node}"
  local run_result=$?
  
  if [ $run_result -ne 0 ]; then
    o_log "Failed to execute VM creation for ${vm_identifier}" "err"
    # Continue to cleanup step
  fi
  
  # Step 8: Delete the Service
  o_log "Cleaning up task service ${service_name}" "info"
  
  o_task_delete "${service_name}"
  local delete_result=$?
  
  if [ $delete_result -ne 0 ]; then
    o_log "Failed to cleanup service ${service_name}" "warning"
  fi
  
  # Step 9: Determine Return Code
  if [ $run_result -ne 0 ] && [ $delete_result -ne 0 ]; then
    # Both task execution and cleanup failed
    o_log "VM creation failed AND service cleanup failed (exceptional state)" "err"
    o_log "Manual cleanup required: om ${service_name} purge" "err"
    return 9
  elif [ $run_result -ne 0 ] && [ $delete_result -eq 0 ]; then
    # Task failed but cleanup succeeded
    o_log "VM creation failed (service cleaned up)" "err"
    return 7
  elif [ $run_result -eq 0 ] && [ $delete_result -ne 0 ]; then
    # Task succeeded but cleanup failed
    o_log "VM created successfully but service cleanup failed (exceptional state)" "warning"
    o_log "Manual cleanup required: om ${service_name} purge" "warning"
    return 8
  else
    # Both succeeded
    o_log "Successfully created VM ${vm_identifier} on ${target_node}" "info"
    return 0
  fi
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


