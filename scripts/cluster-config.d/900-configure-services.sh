#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

## source the cluster file. if it's there

CLUSTER_FILE=$(get_active_cluster_file)
if [[ -f ${CLUSTER_FILE} ]]
 then
  echo "Reading ${CLUSTER_FILE}"
  source "${CLUSTER_FILE}"
  configure_nginx
  configure_dnsmasq
 else
  echo "[WARNING] No active cluster file, not configuring services" 
fi






