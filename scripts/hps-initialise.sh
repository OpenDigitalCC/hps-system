#!/bin/bash
set -euo pipefail

HPS_ROOT="/srv"
HPS_SYSTEM_BASE="${HPS_ROOT}/hps-system"
HPS_CONFIG_BASE="${HPS_ROOT}/hps-config"
HPS_RESOURCES="${HPS_ROOT}/hps-resources"


# Path variables (flat map)
# NOTE: only refer to the above variables, as the mapped variables won't exist until all are defined
declare -A HPS_PATHS=(
  [HPS_LOG_DIR]="${HPS_ROOT}/log"
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
)

HPS_CONF="${HPS_CONFIG_BASE}/hps.conf"


# If already initialized, exit
if [[ -f "$HPS_CONF" ]]; then
  echo "[✓] $0 Cluster already initialised. Using existing config at $HPS_CONF"
  exit 0
fi

echo "[*] $0 Initialising HPS configuration in $HPS_CONFIG_BASE..."

# Export variables and create directories for all *DIR
mkdir -p "$(dirname "$HPS_CONF")"
{
  echo "# HPS configuration"
  for key in "${!HPS_PATHS[@]}"; do
    val="${HPS_PATHS[$key]}"
    echo "export ${key}=\"${val}\""
    if [[ "$key" == *DIR ]]; then
      mkdir -p "$val"
    fi
  done
} > "$HPS_CONF"

echo "[✓] $0 Created $HPS_CONF with exported path definitions."





