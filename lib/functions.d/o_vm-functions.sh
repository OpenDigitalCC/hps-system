#===============================================================================
# o_vm_get_nodes_by_tag
# ---------------------
# Retrieve list of nodes matching a specific tag.
#
# Usage:
#   o_vm_get_nodes_by_tag <tag>
#
# Parameters:
#   tag - Node tag to filter by (e.g., "tch", "hypervisor=kvm") (required)
#
# Behavior:
#   - Validates parameter count (must be exactly 1)
#   - Logs placeholder warning indicating hardcoded implementation
#   - Returns hardcoded node list for v1: "tch-001 tch-002"
#   - Future versions will query OpenSVC node labels/tags
#   - Function designed for easy replacement without changing callers
#
# Returns:
#   0 on success
#   1 on invalid parameters
#
# Output:
#   Stdout: Space-separated node names (e.g., "tch-001 tch-002")
#
# Example usage:
#   nodes=$(o_vm_get_nodes_by_tag "tch")
#   if [ $? -eq 0 ]; then
#     echo "Available nodes: $nodes"
#   fi
#
#===============================================================================
o_vm_get_nodes_by_tag() {
  local tag="$1"

  # Validate parameter count
  if [ $# -ne 1 ]; then
    o_log "Missing tag parameter" "err"
    return 1
  fi

  # Log placeholder warning
  o_log "o_vm_get_nodes_by_tag: Using hardcoded list for tag ${tag}" "warning"

  # Return hardcoded node list (v1 implementation)
  echo "tch-001 tch-002"
  return 0
}

#===============================================================================
# o_vm_select_node
# ----------------
# Select the most suitable TCH node for VM placement.
#
# Usage:
#   o_vm_select_node <cpu_count> <ram_mb>
#
# Parameters:
#   cpu_count - Required CPU cores (required, reserved for future capacity checking)
#   ram_mb - Required RAM in MB (required, reserved for future capacity checking)
#
# Behavior:
#   - Validates parameter count (must be exactly 2)
#   - Calls o_vm_get_nodes_by_tag to retrieve available TCH nodes
#   - Returns first available node from list
#   - Logs node selection with VM requirements
#   - Future versions will implement capacity-aware selection
#   - Selection algorithm is pluggable for future enhancement
#
# Returns:
#   0 on success
#   1 on invalid parameters or no nodes available
#
# Output:
#   Stdout: Selected node name (e.g., "tch-001")
#
# Example usage:
#   node=$(o_vm_select_node 4 8192)
#   if [ $? -eq 0 ]; then
#     echo "Will deploy to: $node"
#     o_vm_create "abc-123-def" "$node"
#   fi
#
#===============================================================================
o_vm_select_node() {
  local cpu_count="$1"
  local ram_mb="$2"

  # Validate parameter count
  if [ $# -ne 2 ]; then
    o_log "Usage: o_vm_select_node <cpu_count> <ram_mb>" "err"
    return 1
  fi

  # Get available TCH nodes
  local nodes
  nodes=$(o_vm_get_nodes_by_tag "tch")
  
  # Check if nodes list is empty
  if [ -z "$nodes" ]; then
    o_log "No TCH nodes available" "err"
    return 1
  fi

  # Extract first node
  local node
  node=$(echo "$nodes" | awk '{print $1}')

  # Log selection
  o_log "Selected node ${node} for VM (${cpu_count} CPUs, ${ram_mb}MB RAM)" "info"

  # Output selected node
  echo "$node"
  return 0
}

