#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"


CLUSTER_FILE=$(get_active_cluster_file) || exit 1
source "$CLUSTER_FILE"
echo "Content-type: text/plain"
echo ""
source /srv/hps-config/hps.conf
source "$HPS_CLUSTER_CONF"
CLUSTER_HEADER="${CLUSTER_NAME:-Unknown} - ${NAME:-Unnamed Cluster}"
echo ""

mac=$(echo "$QUERY_STRING" | sed -n 's/.*mac=\([^&]*\).*/\1/p')
hosttype=$(echo "$QUERY_STRING" | sed -n 's/.*hosttype=\([^&]*\).*/\1/p')

case "$hosttype" in
  TSH)
    echo "#!ipxe"
echo "menu ${CLUSTER_HEADER}"
echo "menu Thin Server Host (TSH)"
    echo "item new Install new TSH"
    echo "item replace Replace existing TSH"
    echo "item back Main menu"
    echo "choose action && goto \${action}"
    echo ":new"
    echo "chain http://${PXE_SERVER_IP}/cgi-bin/create-config.sh?mac=\${mac}&type=TSH"
    echo ":replace"
    echo "chain http://${PXE_SERVER_IP}/cgi-bin/replace-config.sh?mac=\${mac}&type=TSH"
    echo ":back"
    echo "chain http://${PXE_SERVER_IP}/boot.ipxe"
    ;;
  SCH|DRH|CCH)
    echo "#!ipxe"
echo "menu ${CLUSTER_HEADER}"
    echo "menu ${hosttype} Menu"
    echo "item new Install new ${hosttype}"
    echo "item replace Replace existing ${hosttype}"
    echo "item back Main menu"
    echo "choose action && goto \${action}"
    echo ":new"
    echo "chain http://${PXE_SERVER_IP}/cgi-bin/create-config.sh?mac=\${mac}&type=${hosttype}"
    echo ":replace"
    echo "chain http://${PXE_SERVER_IP}/cgi-bin/replace-config.sh?mac=\${mac}&type=${hosttype}"
    echo ":back"
    echo "chain http://${PXE_SERVER_IP}/boot.ipxe"
    ;;
  *)
    echo "#!ipxe"
    echo "echo Invalid host type"
    echo "sleep 3"
    echo "chain http://${PXE_SERVER_IP}/boot.ipxe"
    ;;
esac
