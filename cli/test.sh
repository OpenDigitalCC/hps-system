#!/bin/bash
set -euo pipefail

# Optional override if running outside the container
HPS_CONFIG="${1:-}"

# Resolve script directory and source functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/functions.sh"

export

hps_log debug "Running $0"


get_active_cluster_filename

#host_initialise_config 52540061c123
#ipxe_show_info show_paths
#echo "---- ipxe ----"
#ipxe_init
# generate_ks 52540061c8c9 SCH


#  create_config_nginx
#  create_config_dnsmasq
  create_config_opensvc

