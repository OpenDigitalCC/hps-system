
#===============================================================================
# cluster_config
# --------------
# Alias to cluster_registry for backward compatibility
#===============================================================================
cluster_config() {
  cluster_registry "$@"
}

#!/bin/bash

#===============================================================================
# initialise_cluster
# ------------------
# Initialize a new cluster with directory structure and registry.
#
# Behaviour:
#   - Validates cluster name format
#   - Checks if cluster already exists
#   - Creates cluster directory structure
#   - Initializes cluster registry with metadata
#   - Does NOT set cluster as active (operator decides later)
#
# Parameters:
#   $1 - Cluster name (alphanumeric, dash, underscore only)
#
# Directory Structure Created:
#   /srv/hps-config/clusters/<cluster_name>/
#   /srv/hps-config/clusters/<cluster_name>/hosts/
#   /srv/hps-config/clusters/<cluster_name>/services/
#
# Registry Initialization:
#   CLUSTER_NAME - Name of the cluster
#   CREATED      - ISO timestamp of creation
#   STATUS       - Set to "initialized"
#
# Returns:
#   0 on success
#   1 on validation error
#   2 if cluster already exists
#
# Example usage:
#   initialise_cluster "prod-cluster"
#   # Later: set_active_cluster "prod-cluster"
#
#===============================================================================
initialise_cluster() {
  local cluster_name="${1:?Usage: initialise_cluster <cluster_name>}"
  
  # Validate cluster name format
  if [[ ! "$cluster_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    hps_log error "Invalid cluster name: $cluster_name (use only alphanumeric, dash, underscore)"
    return 1
  fi
  
  # Check if cluster already exists
  if cluster_registry exists "$cluster_name" 2>/dev/null; then
    hps_log error "Cluster already exists: $cluster_name"
    return 2
  fi
  
  # Get config base directory
  local config_base
  config_base=$(hps_get_config config_base) || {
    hps_log error "Cannot determine config base directory"
    return 1
  }
  
  # Create cluster directory structure
  local cluster_dir="${config_base}/clusters/${cluster_name}"
  
  if ! mkdir -p "${cluster_dir}/hosts" "${cluster_dir}/services"; then
    hps_log error "Failed to create cluster directory structure: $cluster_dir"
    return 1
  fi
  
  # Initialize cluster registry with metadata
  if ! cluster_registry "$cluster_name" set CLUSTER_NAME "$cluster_name"; then
    hps_log error "Failed to set cluster name in registry"
    return 1
  fi
  
  if ! cluster_registry "$cluster_name" set CREATED "$(date -Iseconds)"; then
    hps_log error "Failed to set cluster creation timestamp"
    return 1
  fi
  
  if ! cluster_registry "$cluster_name" set STATUS "initialized"; then
    hps_log error "Failed to set cluster status"
    return 1
  fi
  
  hps_log info "Cluster '$cluster_name' initialized successfully"
  hps_log info "Use 'set_active_cluster $cluster_name' to make it active"
  
  return 0
}


#===============================================================================
# get_active_cluster_info
# -----------------------
# Print human-readable information about the current cluster context.
#
# Behaviour:
#   - If an active cluster is set, print its name and metadata
#   - Else, if exactly one cluster exists, print it as "(Only; not Active)"
#   - Else, print that no active cluster is set and list available clusters
#
# Metadata fields (queried via cluster_registry):
#   DESCRIPTION, network_cidr, network_dns_domain
#
# Returns:
#   0 on success
#   1 if no clusters exist or error
#
# Example usage:
#   get_active_cluster_info
#
#===============================================================================
get_active_cluster_info() {
  # Get list of all clusters using registry
  local clusters
  clusters=$(cluster_registry list_all 2>/dev/null)
  
  # Convert to array
  local cluster_array=()
  while IFS= read -r cluster; do
    [[ -n "$cluster" ]] && cluster_array+=("$cluster")
  done <<< "$clusters"
  
  if (( ${#cluster_array[@]} == 0 )); then
    echo "[!] No clusters found" >&2
    return 1
  fi
  
  # Helper: print a key via cluster_registry "$cluster" get (skip silently if empty)
  _print_meta() {
    local key="$1" label="$2" val=""
    if val=$(cluster_registry "$cluster" get "$key" 2>/dev/null); then
      [[ -n "$val" ]] && echo "${label}: ${val}"
    fi
  }
  
  # Case 1: Active cluster exists
  local active_name
  if active_name=$(get_active_cluster_name 2>/dev/null); then
    echo "Cluster: ${active_name} (Active)"
    _print_meta "DESCRIPTION"   "Description"
    _print_meta "network_cidr"  "Network CIDR"
    _print_meta "network_dns_domain"    "DNS Domain"
    return 0
  fi
  
  # Case 2: No active; if exactly one cluster, show it
  if (( ${#cluster_array[@]} == 1 )); then
    local only_name="${cluster_array[0]}"
    echo "Cluster: ${only_name} (Only; not Active)"
    echo "Description: (unknown; no active cluster)"
    echo "Network CIDR: (unknown; no active cluster)"
    echo "DNS Domain: (unknown; no active cluster)"
    return 0
  fi
  
  # Case 3: Multiple clusters, none active
  echo "[!] No active cluster set."
  echo "Available clusters:"
  for cluster in "${cluster_array[@]}"; do
    echo "  - ${cluster}"
  done
  
  return 0
}



#===============================================================================
# count_clusters
# --------------
# Count the number of configured clusters using cluster registry.
#
# Behaviour:
#   - Uses registry count command to find all cluster.db directories
#   - Pure registry operation - no manual file scanning
#
# Returns:
#   0 on success
#   Integer count via stdout
#
# Example usage:
#   cluster_count=$(count_clusters)
#
#===============================================================================
count_clusters() {
  local config_base
  config_base=$(hps_get_config config_base) || {
    echo "[!] Cannot determine config base directory" >&2
    echo 0
    return 0
  }
  
  local clusters_dir="${config_base}/clusters"
  
  # Check if clusters directory exists
  if [[ ! -d "$clusters_dir" ]]; then
    echo 0
    return 0
  fi
  
  # Count cluster.db directories
  local count
  count=$(find "$clusters_dir" -mindepth 2 -maxdepth 2 -type d -name "cluster.db" 2>/dev/null | wc -l)
  
  echo "$count"
  return 0
}

#===============================================================================
# list_clusters
# -------------
# List all cluster names, marking the active one.
#
# Behaviour:
#   - Uses cluster_registry list_all to get all clusters
#   - Appends " (Active)" to the active cluster
#
# Returns:
#   0 on success
#   Cluster names via stdout, one per line
#
# Example usage:
#   list_clusters
#
#===============================================================================
list_clusters() {
  local active_name
  active_name=$(get_active_cluster_name) || true
  
  cluster_registry list_all 2>/dev/null | while IFS= read -r name; do
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      echo "${name} (Active)"
    else
      echo "${name}"
    fi
  done
}

#===============================================================================
# list_cluster_hosts
# ------------------
# List all host MAC addresses in a cluster.
#
# Usage:
#   list_cluster_hosts [cluster_name]
#
# Behaviour:
#   - Uses host_registry list_all for active cluster
#   - Temporarily switches to specified cluster if provided
#   - Returns MAC addresses, one per line
#
# Parameters:
#   cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#
# Returns:
#   0 on success (outputs MAC addresses to stdout, one per line)
#   1 if cluster cannot be determined or doesn't exist
#
# Example usage:
#   list_cluster_hosts              # List hosts in active cluster
#   list_cluster_hosts "production" # List hosts in production cluster
#
#===============================================================================
list_cluster_hosts() {
  local cluster_name="${1:-}"
  
  # If no cluster specified, use active cluster
  if [[ -z "$cluster_name" ]]; then
    host_registry list_all
    return $?
  fi
  
  # Cluster specified - temporarily switch to it
  local original_active
  original_active=$(get_active_cluster_name) || true
  
  # Set target cluster as active
  set_active_cluster "$cluster_name" || {
    hps_log error "Cannot set cluster: $cluster_name"
    return 1
  }
  
  # List hosts in target cluster
  host_registry list_all
  local result=$?
  
  # Restore original active cluster
  [[ -n "$original_active" ]] && set_active_cluster "$original_active" 2>/dev/null
  
  return $result
}


#===============================================================================
# get_cluster_host_ips
# --------------------
# Get IP addresses of all hosts in a cluster.
#
# Usage:
#   get_cluster_host_ips [cluster_name]
#
# Behaviour:
#   - Uses list_cluster_hosts to get all MACs
#   - Queries IP from each host's registry
#   - Outputs only hosts that have IP addresses
#
# Parameters:
#   cluster_name - (optional) Name of the cluster. If empty, uses active cluster.
#
# Returns:
#   0 on success (outputs IP addresses to stdout, one per line)
#   1 if cluster cannot be determined
#
# Example usage:
#   get_cluster_host_ips              # IPs in active cluster
#   get_cluster_host_ips "production" # IPs in production cluster
#
#===============================================================================
get_cluster_host_ips() {
  local cluster_name="${1:-}"
  local mac ip
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    ip=$(host_registry "$mac" get IP 2>/dev/null)
    if [[ -n "$ip" ]]; then
      echo "$ip"
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}

#===============================================================================
# get_cluster_host_hostnames
# --------------------------
# Get hostnames of all hosts in a cluster.
#
# Usage:
#   get_cluster_host_hostnames [cluster_name] [hosttype_filter]
#
# Behaviour:
#   - Uses list_cluster_hosts to get all MACs
#   - Queries HOSTNAME from each host's registry
#   - Optionally filters by TYPE
#   - Outputs only hosts that have hostnames
#
# Parameters:
#   cluster_name     - (optional) Name of the cluster. If empty, uses active cluster.
#   hosttype_filter  - (optional) Filter by host type (e.g., TCH, SCH)
#
# Returns:
#   0 on success (outputs hostnames to stdout, one per line)
#   1 if cluster cannot be determined
#
# Example usage:
#   get_cluster_host_hostnames              # All hostnames in active cluster
#   get_cluster_host_hostnames "production" # All hostnames in production
#   get_cluster_host_hostnames "" "SCH"     # Only SCH hosts in active cluster
#
#===============================================================================
get_cluster_host_hostnames() {
  local cluster_name="${1:-}"
  local hosttype_filter="${2:-}"
  local mac hostname hosttype
  
  # Convert filter to lowercase for comparison
  if [[ -n "$hosttype_filter" ]]; then
    hosttype_filter=$(echo "$hosttype_filter" | tr '[:upper:]' '[:lower:]')
  fi
  
  # Get list of all MACs in cluster
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    # Apply type filter if specified
    if [[ -n "$hosttype_filter" ]]; then
      hosttype=$(host_registry "$mac" get TYPE 2>/dev/null | tr '[:upper:]' '[:lower:]')
      [[ "$hosttype" != "$hosttype_filter" ]] && continue
    fi
    
    # Get hostname
    hostname=$(host_registry "$mac" get HOSTNAME 2>/dev/null)
    
    if [[ -n "$hostname" ]]; then
      echo "$hostname"
    fi
  done < <(list_cluster_hosts "$cluster_name")
  
  return 0
}


#===============================================================================
# print_cluster_variables
# -----------------------
# Print all cluster configuration variables in key=value format.
#
# Usage:
#   print_cluster_variables
#
# Behaviour:
#   - Uses cluster_registry "$cluster" view to get all variables as JSON
#   - Converts to key=value format for easy parsing
#   - Outputs to stdout
#
# Returns:
#   0 on success
#   1 if cluster registry cannot be read
#
# Example usage:
#   print_cluster_variables
#   # Output:
#   # CLUSTER_NAME=production
#   # CREATED=2024-01-01T00:00:00Z
#   # network_dns_domain=example.com
#
#===============================================================================
print_cluster_variables() {
  local cluster="${1:-}"
  
  # If no cluster specified, use active
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No active cluster configured and no cluster specified"
      return 1
    }
  fi
  
  local view_output
  view_output=$(cluster_registry "$cluster" view 2>/dev/null) || {
    hps_log error "Cannot read cluster registry for: $cluster"
    return 1
  }
  
  echo "$view_output" | jq -r 'to_entries[] | "\(.key)=\(.value)"'
  return 0
}

#===============================================================================
# cluster_has_installed_sch
# -------------------------
# Check if cluster has any SCH hosts with STATE=INSTALLED.
#
# Usage:
#   cluster_has_installed_sch
#
# Behaviour:
#   - Searches for hosts with TYPE=SCH using registry_search
#   - Checks each SCH host for STATE=INSTALLED
#   - Returns success on first match
#
# Returns:
#   0 if at least one installed SCH host exists
#   1 if no installed SCH hosts found
#
# Example usage:
#   if cluster_has_installed_sch; then
#     echo "Cluster has installed storage hosts"
#   fi
#
#===============================================================================
cluster_has_installed_sch() {
  # Search for hosts with TYPE=SCH
  local sch_hosts
  sch_hosts=$(registry_search host TYPE SCH 2>/dev/null)
  
  if [[ -z "$sch_hosts" ]]; then
    return 1
  fi
  
  # Check if any have STATE=INSTALLED
  local mac state
  while IFS= read -r mac; do
    [[ -z "$mac" ]] && continue
    
    state=$(host_registry "$mac" get STATE 2>/dev/null)
    if [[ "$state" == "INSTALLED" ]]; then
      return 0
    fi
  done <<< "$sch_hosts"
  
  return 1
}

