
## Interactive functions


#!/bin/bash

#===============================================================================
# commit_changes
# --------------
# Commit all pending cluster configuration changes
#
# Behaviour:
#   - Processes all settings from CLUSTER_CONFIG_PENDING array
#   - Applies changes using cluster_registry with explicit cluster name
#   - Handles JSON types correctly (booleans, numbers, strings)
#   - Generates DNS/DHCP files without reloading services
#   - Clears the pending array
#
# Environment:
#   CLUSTER_NAME         - Name of cluster to commit to (required)
#   CLUSTER_CONFIG_PENDING - Array of key:value pairs to commit
#
# Returns:
#   0 on success
#   1 on error
#
# Example usage:
#   export CLUSTER_NAME="cluster-1"
#   CLUSTER_CONFIG_PENDING+=("network_dhcp_ip:10.99.1.1")
#   CLUSTER_CONFIG_PENDING+=("network_storage_count:2")
#   CLUSTER_CONFIG_PENDING+=("network_storage_vlan31_allocated:false")
#   commit_changes
#
#===============================================================================
commit_changes() {
  local cluster="${CLUSTER_NAME:-}"
  
  if [[ -z "$cluster" ]]; then
    hps_log error "No cluster name available for commit"
    return 1
  fi
  
  # Check if array exists and has elements
  if [[ ! -v CLUSTER_CONFIG_PENDING ]] || [[ ${#CLUSTER_CONFIG_PENDING[@]} -eq 0 ]]; then
    cli_note "No configuration changes to commit"
    return 0
  fi
  
  cli_info "Committing configuration changes for cluster: $cluster"
  
  # Process all pending configuration
  local config_item
  for config_item in "${CLUSTER_CONFIG_PENDING[@]}"; do
    local key="${config_item%%:*}"
    local value="${config_item#*:}"
    
    # Determine if value is already valid JSON (boolean, number, null, object, array)
    local json_value
    if [[ "$value" =~ ^(true|false|null)$ ]] || \
       [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] || \
       [[ "$value" =~ ^\{.*\}$ ]] || \
       [[ "$value" =~ ^\[.*\]$ ]]; then
      # Already valid JSON - use as-is
      json_value="$value"
    else
      # String value - wrap in quotes
      json_value="\"$value\""
    fi
    
    if ! cluster_registry "$cluster" set "$key" "$json_value"; then
      hps_log error "Failed to set: $key=$value"
      return 1
    fi
    
    hps_log info "Set: $key=$value"
  done
  
  # Generate DNS/DHCP files without reloading services
  if ! update_dns_dhcp_files "$cluster" "false"; then
    hps_log warn "Failed to update DNS/DHCP files (non-fatal)"
  fi
  
  # Clear pending array
  CLUSTER_CONFIG_PENDING=()
  
  hps_log info "Configuration changes committed for cluster: $cluster"
  return 0
}





#===============================================================================
# cli_set_active_cluster
# ----------------------
# Prompt to set a cluster as active and apply changes
#
# Parameters:
#   $1 - Cluster name to potentially set as active
#
# Behaviour:
#   - Checks if cluster is already active (skips if so)
#   - Prompts user to set as active and apply changes
#   - Sets active cluster, exports paths, and commits changes if confirmed
#
# Returns:
#   0 on success or if already active
#   1 on error
#   2 if user declines
#===============================================================================
cli_set_active_cluster() {
    local cluster_name="$1"
    
    if [[ -z "$cluster_name" ]]; then
        hps_log "error" "No cluster name provided"
        return 1
    fi
    
    # Get current active cluster
    local current_active=$(get_active_cluster_name 2>/dev/null || echo "")
    
    # Skip if this cluster is already active
    if [[ "$cluster_name" == "$current_active" ]]; then
        cli_note "Cluster '$cluster_name' is already active"
        return 0
    fi
    
    # Ask if user wants to set as active
    if [[ $(cli_prompt_yesno "Set $cluster_name as active cluster and apply changes?" "n") == "y" ]]; then
        cli_info "Setting $cluster_name as active cluster..."
        
        # Set as active
        if set_active_cluster "$cluster_name"; then
            
            # Commit changes
            if commit_changes; then
                cli_info "Cluster $cluster_name is now active and changes are applied"
                return 0
            else
                hps_log "error" "Failed to commit changes"
                return 1
            fi
        else
            hps_log "error" "Failed to set active cluster"
            return 1
        fi
    else
        # User declined
        return 2
    fi
}

#===============================================================================
# select_network_interface
# ------------------------
# Present menu to select a network interface
#
# Parameters:
#   $1 - Prompt text (optional, default: "Select network interface")
#   $2 - Include "None" option (optional, "true"/"false", default: "false")
#   $3 - None option text (optional, default: "None")
#
# Behaviour:
#   - Shows numbered list of interfaces with IP/gateway info
#   - Returns selected interface name via echo
#   - Returns "NONE" if None option selected
#
# Returns:
#   0 on valid selection
#   1 on cancel/error
#===============================================================================
select_network_interface() {
  local prompt="${1:-Select network interface}"
  local include_none="${2:-false}"
  local none_text="${3:-None}"
  
  local interfaces=()
  local labels=()
  local iface ip_cidr gateway
  
  # Build interface list
  while IFS='|' read -r iface ip_cidr gateway; do
    local label="$iface"
    [[ -n "$ip_cidr" ]] && label+=" - $ip_cidr"
    [[ -n "$gateway" ]] && label+=" (gateway: $gateway)"
    
    interfaces+=("$iface")
    labels+=("$label")
  done < <(get_network_interfaces)
  
  # Add None option if requested
  [[ "$include_none" == "true" ]] && labels+=("$none_text")
  
  # Show selection menu - send prompt to stderr so it's not captured
  echo "$prompt:" >&2
  local PS3="#? "  # Set the prompt for select
  select label in "${labels[@]}"; do
    if [[ -z "$label" ]]; then
      hps_log "error" "Invalid selection"
      continue
    fi
    
    # Check if None was selected
    if [[ "$include_none" == "true" ]] && [[ "$REPLY" == "${#labels[@]}" ]]; then
      echo "NONE"
      return 0
    fi
    
    # Return the selected interface NAME, not the label
    local index=$((REPLY - 1))
    if [[ $index -ge 0 ]] && [[ $index -lt ${#interfaces[@]} ]]; then
      echo "${interfaces[$index]}"
      return 0
    fi
    
    break
  done
  
  return 1
}

#===============================================================================
# config_get_value
# ----------------
# Get configuration value with precedence: pending > existing > default
#
# Parameters:
#   $1 - Configuration key
#   $2 - Default value (optional)
#   $3 - Cluster name (optional, defaults to $CLUSTER_NAME)
#
# Behaviour:
#   - First checks CLUSTER_CONFIG_PENDING array
#   - Then checks existing cluster config for specified cluster
#   - Finally uses provided default (or empty string)
#   - Uses $CLUSTER_NAME if no cluster specified
#
# Returns:
#   Echoes the found value
#   Exit code 0 always
#===============================================================================
config_get_value() {
  local key="$1"
  local default="${2:-}"
  local cluster="${3:-$CLUSTER_NAME}"
  local value=""
  
  # Check pending config first
  local config_item
  for config_item in "${CLUSTER_CONFIG_PENDING[@]:-}"; do
    if [[ "$config_item" =~ ^${key}:(.*)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  
  # Check existing config for the specified cluster
  if [[ -n "$cluster" ]]; then
    value=$(cluster_registry "$cluster" "get" "$key" "" "$cluster" 2>/dev/null || echo "")
    if [[ -n "$value" ]]; then
      echo "$value"
      return 0
    fi
  fi
  
  # Use default
  echo "$default"
  return 0
}


#===============================================================================
# select_cluster
# --------------
# Interactive selector for clusters.
#
# Usage:
#   select_cluster [--return=name]
#
# Behaviour:
#   - Lists cluster names using cluster_registry list_all
#   - Appends " (Active)" to the current active cluster
#   - Returns selected cluster name to stdout
#   - Non-interactive (no TTY): auto-selects active if available, else first
#
# Parameters:
#   --return=name - (optional) Always returns name (default behavior now)
#
# Returns:
#   0 on success (cluster name via stdout)
#   1 if no clusters found or selection cancelled
#
# Example usage:
#   cluster=$(select_cluster)
#   cluster=$(select_cluster --return=name)  # Same as above
#
#===============================================================================
select_cluster() {
  # Legacy compatibility - ignore --return=name (we always return name now)
  if [[ "$1" == "--return=name" ]]; then
    shift
  fi
  
  # Get all clusters using registry
  local clusters
  clusters=$(cluster_registry list_all 2>/dev/null)
  
  if [[ -z "$clusters" ]]; then
    echo "[!] No clusters found" >&2
    return 1
  fi
  
  # Convert to arrays
  local names=() display=()
  local active_name
  active_name=$(get_active_cluster_name 2>/dev/null) || true
  
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    names+=("$name")
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      display+=("${name} (Active)")
    else
      display+=("$name")
    fi
  done <<< "$clusters"
  
  if (( ${#names[@]} == 0 )); then
    echo "[!] No clusters found" >&2
    return 1
  fi
  
  # Non-interactive: prefer active; else first
  if [[ ! -t 0 ]]; then
    local pick_idx=0
    if [[ -n "$active_name" ]]; then
      local i
      for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == "$active_name" ]]; then
          pick_idx="$i"
          break
        fi
      done
    fi
    echo "${names[$pick_idx]}"
    return 0
  fi
  
  # Interactive select
  local PS3="[?] Select a cluster: "
  local choice
  select choice in "${display[@]}"; do
    # $REPLY is the raw user input (number); validate it
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#display[@]} )); then
      local idx=$((REPLY - 1))
      echo "${names[$idx]}"
      return 0
    else
      echo "[!] Invalid selection. Enter a number 1..${#display[@]}." >&2
    fi
  done
  
  # If we get here, selection was cancelled
  return 1
}



#===============================================================================
# cluster_storage_init_network
# ----------------------------
# Initialize storage network configuration in cluster_config
#
# Behaviour:
#   - Prompts admin for storage network preferences
#   - Sets up storage VLAN range and configuration
#   - Creates DNS subdomain mapping for each storage network
#   - Stores configuration in cluster_config
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
cluster_storage_init_network() {
  local num_storage_networks
  local enable_jumbo_frames
  local storage_base_vlan
  local storage_subnet_base
  local storage_subnet_cidr
  local cluster_domain
  
  # Get cluster domain
  cluster_domain=$(cluster_registry "$cluster" "get" "network_dns_domain")
  if [[ -z "$cluster_domain" ]]; then
    hps_log "error" "Cluster domain not set"
    return 1
  fi
  
  # Get number of storage networks
  num_storage_networks=$(cli_prompt \
    "Number of storage networks to configure (1-10)" \
    "2" \
    "^[1-9]$|^10$" \
    "Please enter a number between 1 and 10")
  
  # Get base VLAN ID
  storage_base_vlan=$(cli_prompt \
    "Storage network base VLAN ID (31-99)" \
    "31" \
    "^(3[1-9]|[4-9][0-9])$" \
    "VLAN ID must be between 31 and 99")
  
  # Get subnet base
  storage_subnet_base=$(cli_prompt \
    "Storage subnet base (e.g., 10.31 for 10.31.x.0/24)" \
    "10.${storage_base_vlan}" \
    "^[0-9]{1,3}\.[0-9]{1,3}$" \
    "Please enter subnet base as X.Y format (e.g., 10.31)")
  
  # Validate subnet base octets
  local octet1 octet2
  IFS='.' read -r octet1 octet2 <<< "$storage_subnet_base"
  if [[ "$octet1" -gt 255 ]] || [[ "$octet2" -gt 255 ]]; then
    hps_log "error" "Invalid subnet base: octets must be 0-255"
    return 1
  fi
  
  # Get CIDR
  storage_subnet_cidr=$(cli_prompt \
    "Storage subnet CIDR mask (16-28)" \
    "24" \
    "^(1[6-9]|2[0-8])$" \
    "CIDR must be between 16 and 28")
  
  # Ask about jumbo frames
  echo "Note: Jumbo frames require switch support with MTU 9000+ on all storage ports"
  enable_jumbo_frames=$(cli_prompt \
    "Enable jumbo frames (9000 MTU) on storage networks? [y/n]" \
    "y" \
    "^[yn]$" \
    "Please enter 'y' for yes or 'n' for no")
  
  local mtu=1500
  [[ "$enable_jumbo_frames" == "y" ]] && mtu=9000
  
  # Store base configuration
  cluster_registry "set" "network_storage_count" "$num_storage_networks"
  cluster_registry "set" "network_storage_mtu" "$mtu"
  cluster_registry "set" "network_storage_base_vlan" "$storage_base_vlan"
  cluster_registry "set" "network_storage_subnet_base" "$storage_subnet_base"
  cluster_registry "set" "network_storage_subnet_cidr" "$storage_subnet_cidr"
  
  # Configure each storage network
  local i
  for ((i=0; i<num_storage_networks; i++)); do
    local vlan=$((storage_base_vlan + i))
    
    # Calculate subnet using the shared function
    local subnet=$(network_calculate_subnet "$storage_subnet_base" "$i" "$storage_subnet_cidr")
    if [[ $? -ne 0 ]]; then
      hps_log "error" "Failed to calculate subnet for storage network $((i+1))"
      return 1
    fi
    
    # Extract network portion for gateway
    local network_addr="${subnet%/*}"
    local gateway="${network_addr%.*}.1"
    local netmask=$(cidr_to_netmask "${storage_subnet_cidr}")
    local domain="storage$((i+1)).${cluster_domain}"
    
    cluster_registry "set" "network_storage_vlan${vlan}_subnet" "$subnet"
    cluster_registry "set" "network_storage_vlan${vlan}_gateway" "$gateway"
    cluster_registry "set" "network_storage_vlan${vlan}_netmask" "$netmask"
    cluster_registry "set" "network_storage_vlan${vlan}_domain" "$domain"
    cluster_registry "set" "network_storage_vlan${vlan}_allocated" "false"
    
    hps_log "info" "Configured storage network $((i+1)): VLAN $vlan, subnet $subnet, domain $domain"
  done
  
  return 0
}
