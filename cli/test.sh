#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"


set_active_cluster "${HPS_CLUSTER_CONFIG_DIR}/2.cluster"

get_active_cluster_filename
