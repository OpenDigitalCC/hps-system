#!/bin/bash
#===============================================================================
# hps_initialise_config
# ---------------------
# Initialize HPS configuration file with all required path variables.
#
# Behaviour:
#   - Creates base directory structure under /srv
#   - Generates hps.conf with all HPS path exports
#   - Creates all directories for variables ending in *DIR
#   - Exits early if configuration already exists
#
# Returns:
#   0 on success or if already initialized
#   1 on failure (directory creation, file write errors)
#===============================================================================

set -euo pipefail

# Base path constants
readonly HPS_ROOT="/srv"
readonly HPS_SYSTEM_BASE="${HPS_ROOT}/hps-system"
readonly HPS_CONFIG_BASE="${HPS_ROOT}/hps-config"
readonly HPS_RESOURCES="${HPS_ROOT}/hps-resources"

# Base paths that should be exported (these are the foundation paths)
declare -A HPS_BASE_PATHS=(
  [HPS_ROOT]="${HPS_ROOT}"
  [HPS_SYSTEM_BASE]="${HPS_SYSTEM_BASE}"
  [HPS_CONFIG_BASE]="${HPS_CONFIG_BASE}"
  [HPS_RESOURCES]="${HPS_RESOURCES}"
)

# Derived path variables (flat map)
# NOTE: only refer to the base variables, as the mapped variables won't exist until all are defined
declare -A HPS_DERIVED_PATHS=(
  [HPS_LOG_DIR]="${HPS_SYSTEM_BASE}/log"
  [HPS_SCRIPTS_DIR]="${HPS_SYSTEM_BASE}/scripts"
  [HPS_HTTP_STATIC_DIR]="${HPS_SYSTEM_BASE}/http"
  [HPS_TFTP_DIR]="${HPS_CONFIG_BASE}/tftp"
  [HPS_CLUSTER_CONFIG_BASE_DIR]="${HPS_CONFIG_BASE}/clusters"
  [HPS_SERVICE_CONFIG_DIR]="${HPS_CONFIG_BASE}/services"
  [HPS_HTTP_CONFIG_DIR]="${HPS_SYSTEM_BASE}/http"
  [HPS_HTTP_CGI_DIR]="${HPS_SYSTEM_BASE}/http/cgi-bin"
  [HPS_MENU_CONFIG_DIR]="${HPS_SYSTEM_BASE}/http/menu"
  [HPS_DISTROS_DIR]="${HPS_RESOURCES}/distros"
  [HPS_PACKAGES_DIR]="${HPS_RESOURCES}/packages"
  [HPS_OS_BUILDS_DIR]="${HPS_RESOURCES}/builds"
)

readonly HPS_CONF="${HPS_CONFIG_BASE}/hps.conf"

# Function to log with timestamp and script name
log_message() {
  local level="$1"
  local message="$2"
  echo "[$level] $(basename "$0"): $message" >&2
}

# If already initialised, exit
if [[ -f "$HPS_CONF" ]]; then
  log_message "✓" "Cluster already initialised. Using existing config at $HPS_CONF"
  exit 0
fi

log_message "*" "Initialising HPS configuration in $HPS_CONFIG_BASE..."

# Create config directory
if ! mkdir -p "$(dirname "$HPS_CONF")"; then
  log_message "✗" "Failed to create config directory: $(dirname "$HPS_CONF")"
  exit 1
fi

# Write configuration file
{
  echo "# HPS configuration"
  echo "# Generated on $(date -Iseconds) by $(basename "$0")"
  echo ""
  echo "# Base path constants"
  
  # Export base paths first
  for key in "${!HPS_BASE_PATHS[@]}"; do
    val="${HPS_BASE_PATHS[$key]}"
    echo "export ${key}=\"${val}\""
  done
  
  echo ""
  echo "# Derived paths"
  
  # Export derived paths and create directories for *DIR variables
  for key in "${!HPS_DERIVED_PATHS[@]}"; do
    val="${HPS_DERIVED_PATHS[$key]}"
    echo "export ${key}=\"${val}\""
    
    # Create directory if variable name ends with DIR
    if [[ "$key" == *DIR ]]; then
      if ! mkdir -p "$val"; then
        log_message "✗" "Failed to create directory: $val"
        exit 1
      fi
    fi
  done
  
  echo ""
  echo "# Configuration loaded marker"
  echo "export __HPS_CONF_LOADED=\"1\""
  
} > "$HPS_CONF"

if [[ $? -eq 0 ]]; then
  log_message "✓" "Created $HPS_CONF with exported path definitions"
  log_message "✓" "HPS initialisation complete"
else
  log_message "✗" "Failed to write configuration file: $HPS_CONF"
  exit 1
fi





