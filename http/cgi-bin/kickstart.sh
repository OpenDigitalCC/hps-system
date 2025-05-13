#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


mac=$(get_param "mac")
[[ -z "$mac" ]] && { cgi_fail "Missing MAC"; exit 1; }

# Optionally normalize
mac=$(normalise_mac "$mac") || { cgi_fail "Invalid MAC"; exit 1; }

cgi_header_plain
generate_ks_tch "$mac"

