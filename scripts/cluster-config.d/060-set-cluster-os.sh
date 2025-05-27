#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"


[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && { echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2; exit 1; }
if [[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]]; then
  echo "[ERROR] hps.conf not loaded or missing required variables." >&2
  exit 1
fi



echo "Configure Cluster Hosts:"

echo "CPU type:"

select cpu in "x86_64"; do
    if [[ -n "$cpu" ]]; then
        CLUSTER_VARS+=("SCH_CPU=$cpu")
        CLUSTER_VARS+=("TCH_CPU=$cpu")
        CLUSTER_VARS+=("CCH_CPU=$cpu")
        CLUSTER_VARS+=("DRN_CPU=$cpu")
        break
    fi
done

echo "Manufacturer:"

select make in "linux"; do
    if [[ -n "$make" ]]; then
        CLUSTER_VARS+=("SCH_MFR=$make")
        CLUSTER_VARS+=("TCH_CPU=$make")
        CLUSTER_VARS+=("CCH_CPU=$make")
        CLUSTER_VARS+=("DRN_CPU=$make")

        break
    fi
done

echo "Operating system:"

select os in "rockylinux" "almalinux" "debian"; do
    if [[ -n "$os" ]]; then
        CLUSTER_VARS+=("SCH_OSNAME=$os")
        CLUSTER_VARS+=("SCH_OSVER=9.5")
        CLUSTER_VARS+=("TCH_OSNAME=$os")
        CLUSTER_VARS+=("TCH_OSVER=9.5")
        CLUSTER_VARS+=("CCH_OSNAME=$os")
        CLUSTER_VARS+=("CCH_OSVER=9.5")
        CLUSTER_VARS+=("DRH_OSNAME=$os")
        CLUSTER_VARS+=("DRH_OSVER=9.5")
        break
    fi
done



