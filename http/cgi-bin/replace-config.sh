#!/bin/bash
set -euo pipefail
source /srv/hps-config/hps.conf
echo "Content-type: text/plain"
echo ""

mac=$(echo "$QUERY_STRING" | sed -n 's/.*mac=\([^&]*\).*/\1/p')
type=$(echo "$QUERY_STRING" | sed -n 's/.*type=\([^&]*\).*/\1/p')

config_dir="${HPS_HOST_CONFIG_DIR}"
match=$(grep -l "hosttype=$type" $config_dir/*.conf | head -n 1)

if [ -n "$match" ]; then
    mv "$match" "$config_dir/${mac}.conf"
    echo "#!ipxe"
    echo "echo Reassigned config to $mac"
    echo "sleep 2"
else
    echo "#!ipxe"
    echo "echo No existing config found to reassign"
    echo "sleep 3"
fi
echo "chain http://${PXE_SERVER_IP}/boot.ipxe"