#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

while true; do
  read -rp "Enter technical name for this cluster [alphanumeric, underscore, hyphen only]: " CLUSTER_NAME

  if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "[!] Invalid name. Use only alphanumeric, underscore, or hyphen."
    continue
  fi

  base_dir="${HPS_CLUSTER_CONFIG_BASE_DIR:-/srv/hps-config/clusters}"
  cluster_dir="${base_dir}/${CLUSTER_NAME}"
  cluster_file="${cluster_dir}/cluster.conf"

  if [[ -d "$cluster_dir" ]]; then
    echo "[!] Cluster '$CLUSTER_NAME' already exists at: $cluster_dir"
    read -rp "Do you want to reconfigure this cluster? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      export_dynamic_paths "$CLUSTER_NAME"
      echo "[✓] Ready to reconfigure existing cluster '$CLUSTER_NAME'"
      break
    else
      echo "[*] Please choose a different cluster name."
      continue
    fi
  else
    initialise_cluster "$CLUSTER_NAME"
    break
  fi
done

CLUSTER_VARS+=("CLUSTER_NAME=${CLUSTER_NAME}")

