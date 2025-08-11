#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi


echo "What is the DNS domain name or subdomain name for this cluster?"
echo "For example hosts will be known as <hostname>.<dnsdomain>"

read -rp "Enter DNS name name for this cluster: " dnsdomain
CLUSTER_VARS+=("DNS_DOMAIN=\"$dnsdomain\"")
