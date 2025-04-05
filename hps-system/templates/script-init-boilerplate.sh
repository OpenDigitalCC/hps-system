#!/bin/bash
set -euo pipefail

# Resolve this script's directory
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Default locations relative to script
FUNCLIB="${SCRIPT_DIR}/../lib/functions.sh"

# Load function library
if [[ ! -f "$FUNCLIB" ]]; then
  echo "[✗] Missing function library: $FUNCLIB" >&2
  exit 1
fi
source "$FUNCLIB"


