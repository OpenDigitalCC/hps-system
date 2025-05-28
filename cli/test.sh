#!/bin/bash
set -euo pipefail

# Optional override if running outside the container
HPS_CONFIG="${1:-}"

# Resolve script directory and source functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/functions.sh"

echo
echo "[*] Verifying key HPS paths:"
echo " - HPS_CONFIG:       $HPS_CONFIG"
echo " - HPS_HTTP_STATIC_DIR:  $HPS_HTTP_STATIC_DIR"
echo " - HPS_TFTP_DIR:         $HPS_TFTP_DIR"
echo " - HPS_HTTP_CGI_DIR:     $HPS_HTTP_CGI_DIR"
echo " - HPS_DISTROS_DIR:      $HPS_DISTROS_DIR"
echo " - HPS_CLUSTER_CONFIG_BASE_DIR: $HPS_CLUSTER_CONFIG_BASE_DIR"


hps_log debug "Running $0"


get_active_cluster_filename


#ipxe_show_info show_paths

