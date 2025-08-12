#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi


echo "Setting default OpenSVC parameters"


CLUSTER_VARS+=(OSVC_LOG_LEVEL="info")
CLUSTER_VARS+=(OSVC_LISTENER_PORT="7024")
CLUSTER_VARS+=(OSVC_WEB_UI="yes")
CLUSTER_VARS+=(OSVC_WEB_PORT="7023")
CLUSTER_VARS+=(OSVC_HB_INTERVAL="5")
CLUSTER_VARS+=(OSVC_HB_TIMEOUT="15")
CLUSTER_VARS+=(OSVC_TEMPLATES_URL="")
CLUSTER_VARS+=(OSVC_PACKAGES_URL="")


