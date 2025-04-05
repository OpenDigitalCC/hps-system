#!/bin/bash
set -euo pipefail
source /srv/hps-config/hps.conf
echo "Content-type: text/plain"
echo ""

mac=$(echo "$QUERY_STRING" | sed -n 's/.*mac=\([^&]*\).*/\1/p')
type=$(echo "$QUERY_STRING" | sed -n 's/.*type=\([^&]*\).*/\1/p')
hostname="${type,,}-$(date +%s)"

echo "hosttype=$type" > ${HPS_HOST_CONFIG_DIR}/${mac}.conf
echo "hostname=$hostname" >> ${HPS_HOST_CONFIG_DIR}/${mac}.conf

echo "#!ipxe"
echo "echo Created config for $mac as $hostname ($type)"
echo "sleep 2"
echo "chain http://${PXE_SERVER_IP}/boot.ipxe"