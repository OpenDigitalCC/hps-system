#!/bin/bash
set -euo pipefail

# Root directory (adjust if needed)
ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The replacement line
REPLACEMENT='source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"'

# Find all .sh files and apply fix
find "$ROOT_DIR" -type f -name "*.sh" | while read -r file; do
  if grep -q 'FUNCLIB=/srv/hps/lib/functions.sh' "$file"; then
    echo "[✓] Updating $file"
    # Replace the two-line block exactly
    sed -i '/^FUNCLIB=\/srv\/hps\/lib\/functions.sh$/{
      N
      /^FUNCLIB=\/srv\/hps\/lib\/functions.sh\nsource \$FUNCLIB$/ {
        s|^FUNCLIB=.*\nsource \$FUNCLIB$|'"$REPLACEMENT"'|
      }
    }' "$file"
  fi
done
