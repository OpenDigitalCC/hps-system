#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi


echo "Auto-subnet numbering is enabled by default."
CLUSTER_VARS+=("NET_AUTONUMBER=true")
