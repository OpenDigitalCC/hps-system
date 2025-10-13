#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi


while true; do
    read -rp "How many storage subnets? [1-5]: " count
    if [[ "$count" =~ ^[1-5]$ ]]; then
        CLUSTER_VARS+=("STORAGE_SUBNET_Q=$count")
        break
    else
        echo "Enter a number between 1 and 5."
    fi
done



# Set MTU
# If swithces manage jumbo frames (MTU 9000) then set here, so interfaces are configured with jumbo
# for 10% storage improvement, lower latency, less processing
# otherwise all MTU is 1500


