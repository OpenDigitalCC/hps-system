#!/bin/bash
#===============================================================================
# 010-cluster-description.sh
# --------------------------
# Configuration fragment to set cluster description
#
# Behaviour:
#   - Prompts for descriptive name/description for the cluster
#   - Shows existing description if reconfiguring
#   - Allows empty description
#
# Environment:
#   - Appends to CLUSTER_CONFIG_PENDING array
#===============================================================================

cli_info "Configure cluster description"

# Get current description
current_desc=$(config_get_value "DESCRIPTION" "")

# Show current if exists
if [[ -n "$current_desc" ]]; then
  cli_note "Current description: $current_desc"
fi

# Prompt for description
# With validation to require non-empty description
desc=$(cli_prompt "Enter descriptive name for this cluster" "$current_desc" ".+" "Description cannot be empty")

# Store configuration
CLUSTER_CONFIG_PENDING+=("DESCRIPTION:$desc")

if [[ -n "$desc" ]]; then
  cli_info "Cluster description set to: $desc"
else
  cli_info "No cluster description set"
fi


