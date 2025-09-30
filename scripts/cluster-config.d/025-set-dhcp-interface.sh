#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

[[ -z "${HPS_CLUSTER_CONFIG_DIR:-}" ]] && {
  echo "[ERROR] hps.conf not loaded properly or missing required variables." >&2
  exit 1
}

# Collect list of interfaces with IP and gateway info
echo "Select interface to listen on for boot requests:"

interfaces=()
labels=()

while IFS= read -r line; do
  iface=$(echo "$line" | awk -F': ' '{print $2}')
  [[ "$iface" == "lo" ]] && continue

  ip_cidr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -n1)
  ipaddr=$(echo "$ip_cidr" | cut -d/ -f1)
  cidr=$(echo "$ip_cidr" | cut -d/ -f2)
  gw=$(ip route | awk "/^default/ && /dev $iface/ {print \$3}" | head -n1)

  label="$iface"
  [[ -n "$ip_cidr" ]] && label+=" - $ip_cidr"
  [[ -n "$gw" ]] && label+=" (gateway: $gw)"

  interfaces+=("$iface")
  labels+=("$label")
done < <(ip -o link show)

select label in "${labels[@]}" "None (do not enable dnsmasq)"; do
  index=$((REPLY - 1))
  if [[ "$REPLY" == "$(( ${#labels[@]} + 1 ))" ]]; then
    echo "DHCP interface not selected. dnsmasq will not be enabled."
    break
  elif [[ -n "${interfaces[$index]:-}" ]]; then
    iface="${interfaces[$index]}"
    ip_cidr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | head -n1)
    ipaddr=$(echo "$ip_cidr" | cut -d/ -f1)
    cidr=$(echo "$ip_cidr" | cut -d/ -f2)

    if [[ -n "$ipaddr" && -n "$cidr" ]]; then
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
      CLUSTER_VARS+=("DHCP_RANGESIZE=100")
      break
    else
      echo "Interface $iface has no IPv4 address."
    fi
  fi
done

