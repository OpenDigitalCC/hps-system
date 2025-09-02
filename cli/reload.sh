#!/bin/bash
set -euo pipefail

# Source the necessary configurations
source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

echo "Reloading $(get_active_cluster_filename)"

configure_supervisor_services
hps_services_restart  # Restart all services
      
