

#===============================================================================
# o_node_label_exists
# -------------------
# Check if a label exists on a node.
#
# Usage:
#   o_node_label_exists <node> <label_key> [label_value]
#
# Parameters:
#   node        - Node name (required)
#   label_key   - Label key to check (required)
#   label_value - Label value to match (optional, checks key exists if omitted)
#
# Behavior:
#   - Queries node config for labels section
#   - If label_value provided: checks key=value match
#   - If label_value omitted: checks if key exists (any value)
#   - Silent operation (no logs unless error)
#
# Returns:
#   0 if label exists (and matches value if provided)
#   1 if parameters invalid
#   2 if label doesn't exist or doesn't match
#
# Example usage:
#   if o_node_label_exists "tch-001" "role"; then
#     echo "Node has role label"
#   fi
#   if o_node_label_exists "tch-001" "role" "compute"; then
#     echo "Node is compute"
#   fi
#
#===============================================================================
o_node_label_exists() {
  local node="$1"
  local label_key="$2"
  local label_value="$3"
  
  # Validate parameters
  if [ -z "$node" ] || [ -z "$label_key" ]; then
    return 1
  fi
  
  # Query node labels
  local label_config
  label_config=$(om node config show --node "$node" --section labels 2>/dev/null)
  
  if [ -z "$label_config" ]; then
    return 2
  fi
  
  # Check if key exists
  local current_value
  current_value=$(echo "$label_config" | grep "^${label_key} = " | sed "s/^${label_key} = //")
  
  if [ -z "$current_value" ]; then
    return 2
  fi
  
  # If value specified, check it matches
  if [ -n "$label_value" ]; then
    if [ "$current_value" = "$label_value" ]; then
      return 0
    else
      return 2
    fi
  fi
  
  return 0
}


#===============================================================================
# o_node_label_add
# ----------------
# Add or update a label on one or more nodes.
#
# Usage:
#   o_node_label_add <nodes> <label_key> <label_value>
#
# Parameters:
#   nodes       - Node name(s), space-separated or "all" (required)
#   label_key   - Label key (required)
#   label_value - Label value (required)
#
# Behavior:
#   - Expands "all" to all cluster nodes via om node ls
#   - Uses om NODE config update --set for each node
#   - Logs operation for each node
#   - Continues on error (processes all nodes even if one fails)
#
# Returns:
#   0 if all nodes updated successfully
#   1 if parameters invalid
#   2 if one or more nodes failed to update
#
# Example usage:
#   o_node_label_add "tch-001" "role" "compute"
#   o_node_label_add "tch-001 tch-002" "az" "zone1"
#   o_node_label_add "all" "env" "production"
#
#===============================================================================
o_node_label_add() {
  local nodes="$1"
  local label_key="$2"
  local label_value="$3"
  
  # Validate parameters
  if [ -z "$nodes" ] || [ -z "$label_key" ] || [ -z "$label_value" ]; then
    o_log "o_node_label_add: nodes, label_key, and label_value are required" "err"
    return 1
  fi
  
  # Expand "all" to actual node list
  if [ "$nodes" = "all" ]; then
    nodes=$(om node ls 2>/dev/null)
    if [ -z "$nodes" ]; then
      o_log "o_node_label_add: failed to get node list" "err"
      return 1
    fi
  fi
  
  local failed=0
  local success_count=0
  local total_count=0
  
  # Process each node
  for node in $nodes; do
    [ -z "$node" ] && continue
    total_count=$((total_count + 1))
    
    o_log "Adding label ${label_key}=${label_value} to node $node" "info"
    
    if om node config update --node "$node" --set "labels.${label_key}=${label_value}" >/dev/null 2>&1; then
      o_log "Successfully added label to node $node" "info"
      success_count=$((success_count + 1))
    else
      o_log "Failed to add label to node $node" "err"
      failed=1
    fi
  done
  
  o_log "Label operation complete: $success_count/$total_count nodes updated" "info"
  
  if [ $failed -eq 1 ]; then
    return 2
  fi
  
  return 0
}


#===============================================================================
# o_node_label_remove
# -------------------
# Remove a label from one or more nodes.
#
# Usage:
#   o_node_label_remove <nodes> <label_key>
#
# Parameters:
#   nodes     - Node name(s), space-separated or "all" (required)
#   label_key - Label key to remove (required)
#
# Behavior:
#   - Expands "all" to all cluster nodes via om node ls
#   - Uses om NODE config update --unset for each node
#   - Logs operation for each node
#   - Continues on error (processes all nodes even if one fails)
#
# Returns:
#   0 if all nodes updated successfully
#   1 if parameters invalid
#   2 if one or more nodes failed to update
#
# Example usage:
#   o_node_label_remove "tch-001" "role"
#   o_node_label_remove "tch-001 tch-002" "az"
#   o_node_label_remove "all" "temp_label"
#
#===============================================================================
o_node_label_remove() {
  local nodes="$1"
  local label_key="$2"
  
  # Validate parameters
  if [ -z "$nodes" ] || [ -z "$label_key" ]; then
    o_log "o_node_label_remove: nodes and label_key are required" "err"
    return 1
  fi
  
  # Expand "all" to actual node list
  if [ "$nodes" = "all" ]; then
    nodes=$(om node ls 2>/dev/null)
    if [ -z "$nodes" ]; then
      o_log "o_node_label_remove: failed to get node list" "err"
      return 1
    fi
  fi
  
  local failed=0
  local success_count=0
  local total_count=0
  
  # Process each node
  for node in $nodes; do
    [ -z "$node" ] && continue
    total_count=$((total_count + 1))
    
    o_log "Removing label ${label_key} from node $node" "info"
    
    if om node config update --node "$node" --unset "labels.${label_key}" >/dev/null 2>&1; then
      o_log "Successfully removed label from node $node" "info"
      success_count=$((success_count + 1))
    else
      o_log "Failed to remove label from node $node" "err"
      failed=1
    fi
  done
  
  o_log "Label operation complete: $success_count/$total_count nodes updated" "info"
  
  if [ $failed -eq 1 ]; then
    return 2
  fi
  
  return 0
}


#===============================================================================
# o_node_label_list
# -----------------
# List nodes that match label expression(s).
#
# Usage:
#   o_node_label_list <label_expression> [logic] [quiet]
#
# Parameters:
#   label_expression - Label selector(s) in key=value format (required)
#                      Multiple labels separated by spaces
#   logic            - Combination logic: "or" or "and" (optional, default: or)
#   quiet            - Suppress logs: true/false (optional, default: false)
#
# Behavior:
#   - Validates label expression contains = (key=value format required)
#   - OR logic: Pass all labels to om node ls (OpenSVC native OR)
#   - AND logic: Query each label separately, find intersection
#   - Logs query and results unless quiet=true
#   - Outputs matching node names to stdout, one per line
#
# Returns:
#   0 on success (even if no nodes match)
#   1 if label expression invalid/empty or missing =
#   2 if OpenSVC query fails
#
# Example usage:
#   o_node_label_list "az=fr1"
#   o_node_label_list "az=fr1 az=fr2" "or"
#   o_node_label_list "az=fr1 role=storage" "and"
#   nodes=$(o_node_label_list "az=fr1" "or" true)
#
#===============================================================================
o_node_label_list() {
  local label_expression="$1"
  local logic="${2:-or}"
  local quiet="${3:-false}"
  
  # Validate parameters
  if [ -z "$label_expression" ]; then
    if [ "$quiet" != "true" ]; then
      o_log "o_node_label_list: label_expression is required" "err"
    fi
    return 1
  fi
  
  # Validate label expression contains =
  if ! echo "$label_expression" | grep -q "="; then
    if [ "$quiet" != "true" ]; then
      o_log "o_node_label_list: label_expression must contain = (key=value format)" "err"
    fi
    return 1
  fi
  
  # Validate logic parameter
  if [ "$logic" != "or" ] && [ "$logic" != "and" ]; then
    if [ "$quiet" != "true" ]; then
      o_log "o_node_label_list: logic must be 'or' or 'and', got: $logic" "err"
    fi
    return 1
  fi
  
  if [ "$quiet" != "true" ]; then
    o_log "Querying nodes with labels: $label_expression (logic: $logic)" "info"
  fi
  
  local nodes
  local exit_code
  
  if [ "$logic" = "or" ]; then
    # OR logic: OpenSVC native - pass all labels directly
    nodes=$(om node ls --node "$label_expression" 2>&1)
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
      if [ "$quiet" != "true" ]; then
        o_log "o_node_label_list: om node ls failed with exit code $exit_code" "err"
      fi
      return 2
    fi
  else
    # AND logic: Query each label, find intersection
    local all_nodes=""
    local first=true
    
    # Split label_expression into individual labels
    for label in $label_expression; do
      # Validate each label has =
      if ! echo "$label" | grep -q "="; then
        continue
      fi
      
      local label_nodes
      label_nodes=$(om node ls --node "$label" 2>&1)
      exit_code=$?
      
      if [ $exit_code -ne 0 ]; then
        if [ "$quiet" != "true" ]; then
          o_log "o_node_label_list: om node ls failed for label $label with exit code $exit_code" "err"
        fi
        return 2
      fi
      
      if [ "$first" = true ]; then
        # First label - initialize the set
        all_nodes="$label_nodes"
        first=false
      else
        # Subsequent labels - find intersection
        local temp_nodes=""
        while IFS= read -r node; do
          [ -z "$node" ] && continue
          if echo "$all_nodes" | grep -qx "$node"; then
            temp_nodes="${temp_nodes}${node}"$'\n'
          fi
        done <<< "$label_nodes"
        all_nodes="$temp_nodes"
      fi
    done
    
    nodes="$all_nodes"
  fi
  
  # Count and log results
  local node_count=0
  if [ -n "$nodes" ]; then
    node_count=$(echo "$nodes" | grep -c "^")
  fi
  
  if [ "$quiet" != "true" ]; then
    o_log "Found $node_count node(s) matching labels: $label_expression" "info"
  fi
  
  # Output nodes to stdout
  if [ -n "$nodes" ]; then
    echo "$nodes"
  fi
  
  return 0
}
