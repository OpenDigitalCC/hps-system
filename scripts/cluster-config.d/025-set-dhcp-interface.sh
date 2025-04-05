#!/bin/bash
set -euo pipefail

FUNCLIB=/srv/hps/lib/functions.sh
source "$FUNCLIB"

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && {
  echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2
  exit 1
}

echo "Select interface to listen on for boot requests:"
interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

select iface in "${interfaces[@]}" "None (do not enable dnsmasq)"; do
  if [[ "$REPLY" == "${#interfaces[@]}+1" ]]; then
    echo "DHCP interface not selected. dnsmasq will not be enabled."
    break
  elif [[ -n "$iface" ]]; then
    ip_cidr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}')
    ipaddr=$(echo "$ip_cidr" | cut -d/ -f1)
    cidr=$(echo "$ip_cidr" | cut -d/ -f2)

    if [[ -n "$ipaddr" && -n "$cidr" ]]; then
      # Use ipcalc to get network base
      if ! command -v ipcalc &>/dev/null; then
        echo "[ERROR] ipcalc is required but not installed." >&2
        exit 1
      fi

      network=$(ipcalc "$ipaddr/$cidr" | awk '/^Network:/ {print $2}')
      echo "Selected $iface with IP $ipaddr/$cidr (network $network)"

      CLUSTER_VARS+=("DHCP_IFACE=$iface")
      CLUSTER_VARS+=("DHCP_IP=$ipaddr")
      CLUSTER_VARS+=("DHCP_CIDR=$ipaddr/$cidr")
      CLUSTER_VARS+=("NETWORK_CIDR=$network")
      break
    else
      echo "Interface $iface has no IPv4 address."
    fi
  fi
done

