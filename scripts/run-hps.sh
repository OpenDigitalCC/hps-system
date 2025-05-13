#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HPS_CONFIG="${SCRIPT_DIR}/../../hps-config/hps.conf"

while [[ ! -r "$HPS_CONFIG" ]]; do
  echo "$0 Warning: File '$HPS_CONFIG' is not readable - Initialising config"
  "$SCRIPT_DIR/hps-initialise.sh"
  sleep 5
done

echo "[✓] File '$HPS_CONFIG' is available. Continuing..."


source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

configure_supervisor_core

echo "[✓] hps started and initialised."

if cluster_file=$(get_active_cluster_filename 2>/dev/null)
 then
  if [[ -f "$cluster_file" ]]
   then
    echo "[INFO] Active cluster found: $cluster_file, creating services"
    configure_supervisor_services
    configure_dnsmasq
    configure_nginx
    configure_ipxe
  fi
 else
  echo "[INFO] No active cluster configured — continuing without starting services"
  echo "[INFO] Services will be started once the cluster is configured."
  echo ""
  echo "[INFO] run /srv/hps-system/cli/cluster-configure.sh"
  echo "[INFO] or"
  echo "[INFO] sudo docker compose exec hps /srv/hps-system/cli/cluster-configure.sh"
fi

echo "[INFO] Handing over to supervisord"
# Start supervisord with the generated config
exec /usr/bin/supervisord -c "${SUPERVISORD_CONF}"
