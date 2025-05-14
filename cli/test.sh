#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

hps_log debug "Running $0"


get_active_cluster_filename
