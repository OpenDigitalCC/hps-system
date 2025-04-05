#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi



echo "Select OS for Storage Cluster Hosts:"
select os in "Rocky" "Alma" "RedHat"; do
    if [[ -n "$os" ]]; then
        CLUSTER_VARS+=("STORAGE_OS=$os")
        break
    fi
done
