#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

trap cleanup EXIT


cleanup() {
  if [[ $? -eq 0 ]]
   then
    echo "[✓] Reconfiguring..."

  # Check for CLUSTER_NAME and write the config
    if [[ -v CLUSTER_NAME && -n "$CLUSTER_NAME" ]]
     then
      write_cluster_config "${HPS_CLUSTER_CONFIG_DIR}/cluster.conf" "${CLUSTER_VARS[@]}"
      set_active_cluster "$CLUSTER_NAME"
      configure_supervisor_services
      configure_dnsmasq
      configure_nginx
      configure_ipxe
      hps_services_restart  # Restart all services
     else
      echo "[ERROR] No cluster name, not reloading"
    fi
   else
    echo "[ERROR] $0 Trapped non-zero exit at clean-up ($?)."
  fi
}


# Define the cluster configuration directory
SCRIPT_DIR="${HPS_SCRIPTS_DIR}/cluster-config.d"

# Running the config fragments
export CLUSTER_VARS=()
for script in "$SCRIPT_DIR"/*.sh; do
    if [[ -x "$script" ]]; then
        source "$script"  # Ensure it sources the scripts, not executes them
    else
        echo "[!] Skipping non-executable: $script"
    fi
done

echo "[✓] Finished configuration."


