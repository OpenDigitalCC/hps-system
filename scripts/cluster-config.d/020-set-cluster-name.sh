#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

read -rp "Enter technical name for this cluster [alphanumeric, underscore, hyphen only]: " CLUSTER_NAME

if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "[!] Invalid name. Use only alphanumeric, underscore, hyphen."
  exit 1
fi

CLUSTER_VARS+=("CLUSTER_NAME=${CLUSTER_NAME}")
if [[ -f "${HPS_CLUSTER_CONFIG_DIR}/${CLUSTER_NAME}.cluster" ]]; then
  echo "[!] Cluster name already exists: ${CLUSTER_NAME}.cluster"
  read -rp "Do you want to overwrite it? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "[!] Aborting cluster creation. Please start again."
    exit 1
  fi
fi
