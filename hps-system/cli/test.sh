#!/bin/bash
set -euo pipefail

# Source the necessary configurations
FUNCLIB=/srv/hps/lib/functions.sh
source $FUNCLIB


set_active_cluster "${HPS_CLUSTER_CONFIG_DIR}/2.cluster"

get_active_cluster_filename
