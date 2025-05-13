#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


mac=$(get_param "mac")
[[ -z "$mac" ]] && { cgi_fail "Missing MAC"; exit 1; }

type=$(get_param "type")
[[ -z "$type" ]] && { cgi_fail "Missing type"; exit 1; }


cgi_header_plain
generate_ks "$mac" "$type"

