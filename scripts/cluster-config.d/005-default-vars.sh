# Set clusteer variables

# ${HPS_CLUSTER_CONFIG_DIR}

# where to store services data
CLUSTER_VARS+=("CLUSTER_SERVICES_DIR=${HPS_CLUSTER_CONFIG_DIR}/services")

echo "Setting syslog address to $ipaddr"
CLUSTER_VARS+=("SYSLOG_SERVER=$ipaddr")


echo "Setting NAME_SERVER address to $ipaddr"
CLUSTER_VARS+=("NAME_SERVER=$ipaddr")


echo "Setting TIME_SERVER address to $ipaddr"
CLUSTER_VARS+=("TIME_SERVER=$ipaddr")

