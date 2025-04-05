#!/bin/bash
set -euo pipefail
FUNCLIB=/srv/hps/lib/functions.sh
source $FUNCLIB

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi


read -rp "Enter descriptive name for this cluster: " desc
CLUSTER_VARS+=("NAME=\"$desc\"")
