#!/bin/bash
set -euo pipefail

# Mapping of old → new variable names
declare -A VAR_MAP=(
  [HPS_TFTP]=HPS_TFTP_DIR
  [HPS_HTTP]=HPS_HTTP_DIR
  [HPS_SCRIPTS_BASE]=HPS_SCRIPTS_DIR
  [CONFIG_BASE]=HPS_CONFIG_BASE
  [CONFIG_HTTP_HOST]=HPS_HOST_CONFIG_DIR
  [CONFIG_HTTP_MENU]=HPS_MENU_CONFIG_DIR
  [CONFIG_CLUSTER]=HPS_CLUSTER_CONFIG_DIR
  [CONFIG_SERVICE]=HPS_SERVICE_CONFIG_DIR)

# Search paths
SEARCH_PATHS=(./scripts ./http/cgi-bin ./lib)

# Find and process all .sh files
find "${SEARCH_PATHS[@]}" -type f -name "*.sh" | while read -r file; do
  updated=0
  for old in "${!VAR_MAP[@]}"; do
    new="${VAR_MAP[$old]}"
    # Skip file if new var already in use
    if grep -q "\${$new}\|\$$new" "$file"; then
      continue
    fi
    # Apply replacements if old var is found
    if grep -q "\${$old}\|\$$old" "$file"; then
      echo "[~] Updating $file: $old → $new"
      sed -i \
        -e "s|\${${old}}|\${${new}}|g" \
        -e "s|\"\$${old}\"|\"\$${new}\"|g" \
        -e "s|'\$${old}'|'\$${new}'|g" \
        -e "s|\$${old}|\$${new}|g" \
        "$file"
      updated=1
    fi
  done

  [[ $updated -eq 0 ]] && echo "[✓] Skipped $file (already updated or no match)"
done
