#===============================================================================
# Cluster Helper Functions
#===============================================================================
# Common registry operations for cluster management.
#===============================================================================

#===============================================================================
# get_active_cluster_name
# -----------------------
# Get the name of the currently active cluster.
#
# Usage:
#   get_active_cluster_name
#
# Returns:
#   0 on success (cluster name via stdout)
#   1 if no active cluster set
#
# Example usage:
#   cluster=$(get_active_cluster_name) || echo "No active cluster"
#
#===============================================================================
get_active_cluster_name() {
  system_registry get ACTIVE_CLUSTER 2>/dev/null
}

#===============================================================================
# set_active_cluster
# ------------------
# Set the active cluster in system registry.
#
# Usage:
#   set_active_cluster <cluster_name>
#
# Behaviour:
#   - Updates ACTIVE_CLUSTER in system registry
#   - Does NOT validate cluster exists (to avoid circular dependencies)
#   - Use cluster_exists() separately if validation needed
#
# Parameters:
#   cluster_name - Name of cluster to set as active
#
# Returns:
#   0 on success
#   1 if cluster name not provided
#   2 if system registry update fails
#
# Example usage:
#   set_active_cluster "production"
#
#===============================================================================
set_active_cluster() {
  local cluster_name="${1:?Usage: set_active_cluster <cluster_name>}"
  
  # Update system registry (no validation to avoid circular dependency)
  if ! system_registry set ACTIVE_CLUSTER "$cluster_name"; then
    hps_log error "Failed to update system registry"
    return 2
  fi
  
  return 0
}

#===============================================================================
# cluster_exists
# --------------
# Check if a cluster exists in the registry.
#
# Usage:
#   cluster_exists <cluster_name>
#
# Parameters:
#   cluster_name - Name of cluster to check
#
# Returns:
#   0 if cluster exists
#   1 if cluster does not exist
#
# Example usage:
#   if cluster_exists "production"; then
#     echo "Cluster exists"
#   fi
#
#===============================================================================
cluster_exists() {
  local cluster_name="${1:?Usage: cluster_exists <cluster_name>}"
  
  # Use cluster_registry's built-in exists command
  cluster_registry exists "$cluster_name"
}
