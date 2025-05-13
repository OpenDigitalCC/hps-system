#!/bin/bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

count=$(count_clusters)

if [[ "$count" -eq 0 ]]; then
  echo "[*] No clusters found. Proceeding to create a new one..."
elif [[ "$count" -eq 1 ]]; then
  echo "[*] One cluster found."
  cluster_name=$(list_clusters | head -n1)

  echo ""
  echo "[?] What would you like to do?"
  select action in "Reconfigure '${cluster_name}'" "Add new cluster"; do
    case "$REPLY" in
      1)
        set_active_cluster "$cluster_name"
        export_dynamic_paths
        # Your cluster reconfiguration logic goes here
        break
        ;;
      2)
        # Proceed to new cluster creation
        break
        ;;
      *)
        echo "[!] Invalid selection."
        ;;
    esac
  done
else
  echo "[*] Multiple clusters found:"
  list_clusters
  echo ""

  echo "[?] What would you like to do?"
  select action in "Select active cluster" "Reconfigure a cluster" "Add new cluster"; do
    case "$REPLY" in
      1)
        selected=$(select_cluster)
        set_active_cluster "$(basename "$selected")"
        export_dynamic_paths
        break
        ;;
      2)
        selected=$(select_cluster)
        set_active_cluster "$(basename "$selected")"
        export_dynamic_paths
        # Cluster reconfiguration logic here
        break
        ;;
      3)
        # Proceed to new cluster creation
        break
        ;;
      *)
        echo "[!] Invalid selection."
        ;;
    esac
  done
fi

