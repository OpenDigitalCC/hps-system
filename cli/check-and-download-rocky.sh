#!/bin/bash
set -euo pipefail

# Source the necessary configurations
source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"



# Call the function (it includes the check internally)
check_and_download_latest_rocky

