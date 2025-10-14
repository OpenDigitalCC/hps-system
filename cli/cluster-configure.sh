#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"



#===============================================================================
# cluster_manager
# ---------------
# Main cluster management script for creating, selecting, and reconfiguring clusters
#
# Behaviour:
#   - Detects existing clusters and provides appropriate options
#   - Runs configuration scripts from cluster-config.d directory
#   - Only sets active cluster when explicitly requested by user
#   - Saves configuration through cluster_config function calls
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================



#===============================================================================
# run_cluster_configuration
# -------------------------
# Execute all configuration scripts for the selected cluster
#
# Parameters:
#   $1 - Cluster name to configure
#
# Behaviour:
#   - Sets CLUSTER_NAME environment variable
#   - Sources all executable scripts in cluster-config.d
#   - Each script can use cluster_config to save settings
#
# Returns:
#   0 on success
#   1 if any script fails
#===============================================================================
run_cluster_configuration() {
    local cluster="$1"
    
    # Export cluster name for use by configuration scripts
    export CLUSTER_NAME="$cluster"
    
    # Initialize pending configuration array
    export CLUSTER_CONFIG_PENDING=()
    
    # Define the cluster configuration directory
    local script_dir="${HPS_SCRIPTS_DIR}/cluster-config.d"
    
    cli_info "Running configuration scripts from: $script_dir" "Cluster Configuration: $CLUSTER_NAME"
    
    # Check if directory exists
    if [[ ! -d "$script_dir" ]]; then
        hps_log "error" "Configuration directory not found: $script_dir"
        return 1
    fi
    
    # Run each configuration script
    local script
    for script in "$script_dir"/*.sh; do
        # Skip if no scripts found
        [[ ! -e "$script" ]] && continue
        
        local script_name=$(basename "$script")
        cli_info "Running: $script_name"
          
        # Source the script to maintain environment
        if ! source "$script"; then
            hps_log "error" "Failed to execute: $script_name"
            return 1
        fi
    done
    
    cli_info "Configuration scripts completed"
    return 0
}


#===============================================================================
# create_new_cluster
# ------------------
# Create a new cluster with the given name
#
# Parameters:
#   $1 - Cluster name (optional, will prompt if not provided)
#
# Returns:
#   0 on success
#   1 on error
#===============================================================================
create_new_cluster() {
  local cluster_name="${1:-}"  # Use empty string if $1 is not provided
  
  cli_info "Create new cluster"
  
  # Note about DNS compliance
  cli_note "Cluster name must be DNS RFC compliant: start with letter, contain only letters/numbers/hyphens, max 63 chars"
  
  # DNS RFC compliant regex:
  # - Must start with a letter
  # - Can contain letters, numbers, and hyphens
  # - Must end with a letter or number
  # - Max 63 characters
  # - No consecutive hyphens
  local dns_regex="^[a-zA-Z]([a-zA-Z0-9-]?[a-zA-Z0-9])*$"
  
  # Prompt for name if not provided
  while [[ -z "$cluster_name" ]]; do
    cluster_name=$(cli_prompt "Enter new cluster name" "" "$dns_regex" \
      "Invalid name: must start with letter, contain only letters/numbers/hyphens, end with letter/number")
    
    [[ -z "$cluster_name" ]] && return 1
    
    # Check length
    if [[ ${#cluster_name} -gt 63 ]]; then
      hps_log "error" "Name too long: ${#cluster_name} characters (max 63)"
      cluster_name=""
      continue
    fi
    
    # Check for consecutive hyphens
    if [[ "$cluster_name" =~ -- ]]; then
      hps_log "error" "Invalid name: cannot contain consecutive hyphens"
      cluster_name=""
      continue
    fi
    
    # Valid name
    break
  done
  
  cli_info "Creating cluster: $cluster_name"
  
  # Export for use by configuration scripts
  export CLUSTER_NAME="$cluster_name"
  
  initialise_cluster "$cluster_name"
  return 0
}


#===============================================================================
# main
# ----
# Main entry point for cluster management
#===============================================================================
main() {
    local clusters=()
    local active_cluster=""
    local cluster_name
    local choice
    
    # Get raw cluster list
    local raw_list=$(list_clusters)
    
    # Parse clusters, handling "(Active)" marker
    local current_cluster=""
    for word in $raw_list; do
        if [[ "$word" == "(Active)" ]]; then
            # Previous cluster is the active one
            active_cluster="$current_cluster"
            clusters+=("$current_cluster")
        else
            # If we had a previous cluster, add it
            [[ -n "$current_cluster" ]] && [[ "$current_cluster" != "$active_cluster" ]] && clusters+=("$current_cluster")
            current_cluster="$word"
        fi
    done
    # Add the last cluster if not already added
    [[ -n "$current_cluster" ]] && [[ "$current_cluster" != "$active_cluster" ]] && clusters+=("$current_cluster")
    
    cli_info "" "Cluster Configuration"
    
    # Display menu
    echo "Select cluster to configure:"
    local i
    for i in "${!clusters[@]}"; do
        local cluster="${clusters[$i]}"
        local num=$((i + 1))
        if [[ "$cluster" == "$active_cluster" ]]; then
            echo "$num) $cluster (active)"
        else
            echo "$num) $cluster"
        fi
    done
    echo "N) Create New cluster"
    echo "A) Set Active cluster"
    echo
    
    # Get selection
    read -p "Choice: " choice
    
    # Handle selection
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        # Create new cluster
        create_new_cluster || return 1
        cluster_name="$CLUSTER_NAME"
        
        # Run configuration
        run_cluster_configuration "$cluster_name"
        
        # Ask about committing changes
        if [[ $(cli_prompt_yesno "Commit changes now?" "y") == "y" ]]; then
            if commit_changes; then
                cli_info "Changes successfully committed"
            else
                hps_log "error" "Failed to commit changes"
                return 1
            fi
        else
            cli_note "Configuration saved but not committed"
        fi
    elif [[ "$choice" =~ ^[Aa]$ ]]; then
        # Set active cluster
        if [[ ${#clusters[@]} -eq 0 ]]; then
            cli_info "No clusters available"
            return 1
        fi
        
        # Show cluster selection
        echo "Select cluster to set as active:"
        for i in "${!clusters[@]}"; do
            local cluster="${clusters[$i]}"
            local num=$((i + 1))
            if [[ "$cluster" == "$active_cluster" ]]; then
                echo "$num) $cluster (currently active)"
            else
                echo "$num) $cluster"
            fi
        done
        echo "X) Exit menu without making changes"
        echo
        
        read -p "Choice: " cluster_choice
        
        if [[ "$cluster_choice" =~ ^[Xx]$ ]]; then
            # User chose to exit
            cli_note "No changes made"
            return 0
        elif [[ "$cluster_choice" =~ ^[0-9]+$ ]] && [[ "$cluster_choice" -ge 1 ]] && [[ "$cluster_choice" -le "${#clusters[@]}" ]]; then
            cluster_name="${clusters[$((cluster_choice - 1))]}"
            hps_log info "Updating active cluster to $cluster_name"
            cli_set_active_cluster "$cluster_name"
            update_dns_dhcp_files
        else
            hps_log "error" "Invalid selection"
            return 1
        fi
        

    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#clusters[@]}" ]]; then
        # Valid cluster selection for configuration
        cluster_name="${clusters[$((choice - 1))]}"
        
        # Run configuration
        run_cluster_configuration "$cluster_name"
        
        # Ask about committing changes
        if [[ $(cli_prompt_yesno "Commit changes now?" "y") == "y" ]]; then
            if commit_changes; then
                cli_info "Changes successfully committed"
            else
                hps_log "error" "Failed to commit changes"
                return 1
            fi
        else
            cli_note "Configuration saved but not committed"
        fi
        
    else
        hps_log "error" "Invalid selection"
        return 1
    fi
    
    return 0
}

# Run main function
main "$@"


