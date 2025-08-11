__guard_source || return


generate_dhcp_range_simple() {
    local network_cidr="$1"   # e.g. 192.168.50.0/24
    local gateway_ip="$2"     # e.g. 192.168.50.1
    local count="${3:-20}"

    # Extract network and broadcast using ipcalc
    local network broadcast
    while read -r key value; do
        case "$key" in
            Network:)   network="${value%%/*}" ;;
            Broadcast:) broadcast="$value" ;;
        esac
    done < <(ipcalc -n -b "$network_cidr")

    # Convert IPs to ints
    ip_to_int() {
        IFS=. read -r o1 o2 o3 o4 <<< "$1"
        echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    }

    int_to_ip() {
        local ip=$1
        echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))"
    }

    local net_int=$(ip_to_int "$network")
    local bc_int=$(ip_to_int "$broadcast")
    local gw_int=$(ip_to_int "$gateway_ip")

    # Usable range: net+1 .. bc-1
    local usable_start=$((net_int + 1))
    local usable_end=$((bc_int - 1))

    # Try range just after the gateway
    local range_start=$((gw_int + 1))
    local range_end=$((range_start + count - 1))

    # Clamp to usable range
    if (( range_end > usable_end )); then
        range_end=$usable_end
        range_start=$((range_end - count + 1))
        if (( range_start < usable_start )); then
            range_start=$((usable_start + 1))
        fi
    fi

    echo "$(int_to_ip "$range_start"),$(int_to_ip "$range_end"),1h"
}


normalise_mac() {
  local mac="$1"

  # Remove all common delimiters
  mac="${mac//:/}"
  mac="${mac//-/}"
  mac="${mac//./}"
  mac="${mac// /}"

  # Convert to lowercase
  mac="${mac,,}"

  # Validate: must be exactly 12 hex characters
  if [[ ! "$mac" =~ ^[0-9a-f]{12}$ ]]; then
    echo "[x] Invalid MAC address format: $1" >&2
    return 1
  fi

  echo "$mac"
}


get_client_mac() {
  local ip="$1"
  local mac=""

  # Ensure IP is valid
  [[ -z "$ip" ]] && return 1
  # Trigger ARP update
  ping -c1 -W1 "$ip" > /dev/null 2>&1

  # Use regex to extract MAC from matching line
  mac="$(ip neigh | awk -v ip="$ip" '
    $1 == ip {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) {
          print $i
          exit
        }
      }
    }
  ')"

  # Fallback to arp
  if [[ -z "$mac" ]]; then
    mac="$(arp -n | awk -v ip="$ip" '
      $1 == ip {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) {
            print $i
            exit
          }
        }
      }
    ')"
  fi
  echo $(normalise_mac "$mac")
}




