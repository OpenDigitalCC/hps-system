#!/bin/bash
set -euo pipefail

HPS_ROOT="/srv"

HPS_SYSTEM_BASE="${HPS_ROOT}/hps-system"

HPS_SYSTEM_SCRIPTS="${HPS_SYSTEM_BASE}/scripts"
HPS_SYSTEM_TFTP="${HPS_SYSTEM_BASE}/tftp"

CONFIG_BASE="${HPS_ROOT}/hps-config"
CONFIG_HTTP="${CONFIG_BASE}/http"
CONFIG_HTTP_HOST="${CONFIG_HTTP}/hosts"
CONFIG_HTTP_MENU="${CONFIG_HTTP}/menu"
CONFIG_CLUSTER="${CONFIG_BASE}/cluster"
CONFIG_SERVICE="${CONFIG_BASE}/services"
HPS_CONF="${CONFIG_BASE}/hps.conf"

if [[ -f "$HPS_CONF" ]]; then
  echo "[✓] $0 Cluster already initialised. Using existing config at $HPS_CONF"
else
  echo "[*] $0 Initialising HPS configuration in $CONFIG_BASE..."

  mkdir -p "$CONFIG_CLUSTER" "$CONFIG_HTTP_HOST" "$CONFIG_SERVICE"

  cat > "$HPS_CONF" <<EOF
# Central HPS configuration paths
export HPS_BASE=${HPS_SYSTEM_BASE}
export HPS_SCRIPTS_BASE="${HPS_SYSTEM_SCRIPTS}"
export HPS_HTTP="${CONFIG_HTTP}"
export HPS_TFTP="${HPS_SYSTEM_TFTP}"
export HPS_CONFIG_BASE="${CONFIG_BASE}"
export HPS_CLUSTER_CONFIG_DIR="${CONFIG_CLUSTER}"
export HPS_MENU_CONFIG_DIR="${CONFIG_HTTP_MENU}"
export HPS_HOST_CONFIG_DIR="${CONFIG_HTTP_HOST}"
export HPS_SERVICE_CONFIG_DIR="${CONFIG_SERVICE}"

EOF

  echo "[✓] $0 Created hps.conf with path definitions."

# Create the configuration directory structure if not already present
if [[ ! -d "${CONFIG_BASE}/cluster" ]]; then
  echo "[*] Creating ${CONFIG_BASE}/cluster"
  mkdir -p ${CONFIG_BASE}/cluster
fi

if [[ ! -d "${CONFIG_HTTP_HOST}" ]]; then
  echo "[*] Creating ${CONFIG_HTTP_HOST}"
  mkdir -p ${CONFIG_HTTP_HOST}
fi

if [[ ! -d "${CONFIG_BASE}/services" ]]; then
  echo "[*] Creating ${CONFIG_BASE}/services"
  mkdir -p ${CONFIG_BASE}/services
fi


fi




