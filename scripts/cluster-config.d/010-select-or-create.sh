#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

shopt -s nullglob
configs=("${HPS_CLUSTER_CONFIG_DIR}"/*.cluster)
shopt -u nullglob


#TODO: This doesn't work well, reselecting the same config should reload, also needs a delete config. plus choosing a diffent configndoesnt work

if ((${#configs[@]}))
 then
  active_cluster=$(get_active_cluster_filename)
  echo "[*] Found ${#configs[@]} existing cluster(s) - Active cluster: $(basename ${active_cluster})"
  select opt in "${configs[@]}" "Create new cluster"
   do
    if [[ "$REPLY" -gt 0 && "$REPLY" -le ${#configs[@]} ]]
     then
      CLUSTER_CHOICE=${configs[$((REPLY-1))]}
      echo "[✓] Re-using existing cluster: $(basename "${CLUSTER_CHOICE}")"
#      set_active_cluster "${CLUSTER_CHOICE}"
      source "${CLUSTER_CHOICE}"
      if [[ -v CLUSTER_NAME && -n "$CLUSTER_NAME" ]]
       then
        exit 0
       else
        echo "[ERROR] Cluster configuration not saved"
        exit 1
      fi
    elif [[ "$REPLY" -eq $(( ${#configs[@]} + 1 )) ]]; then
      break
    else
      echo "[!] Invalid selection."
    fi
  done
else
  echo "[*] No existing cluster configurations found, proceeding to create a new cluster."
fi
