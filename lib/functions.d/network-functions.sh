__guard_source || return

#===============================================================================
# cidr_to_netmask
# ---------------
# Convert CIDR prefix length to netmask
#
# Usage: cidr_to_netmask <prefix_length>
# Example: cidr_to_netmask 24  # Returns 255.255.255.0
#
# Returns:
#   Netmask string
#===============================================================================
cidr_to_netmask() {
  local prefix=$1
  local mask=""
  local full_octets=$((prefix / 8))
  local partial_octet=$((prefix % 8))

  # Full octets (255)
  for ((i=0; i<full_octets; i++)); do
    mask+="${mask:+.}255"
  done

  # Partial octet (if any)
  if (( partial_octet > 0 )); then
    mask+="${mask:+.}$((256 - 2**(8-partial_octet)))"
  fi

  # Fill remaining octets with 0
  while (( $(echo "$mask" | tr -cd '.' | wc -c) < 3 )); do
    mask+="${mask:+.}0"
  done

  echo "$mask"
}



# detect_client_type
# ------------------
# Detects the type of caller for this CGI script based on CGI environment vars.
#
# Returns (via stdout):
#   ipxe    - iPXE boot client
#   cli     - curl or wget (host scripts)
#   browser - human browser (Mozilla/Chrome/Safari/etc)
#   script  - non-interactive/scripted caller (e.g. no UA, not ipxe/cli/browser)
#   unknown - fallback
#
# Usage:
#   client_type="$(detect_client_type)"
#   echo "Client is: ${client_type}"
detect_client_type() {
  # Guard against unset QUERY_STRING under `set -u`
  local qs="${QUERY_STRING-}"

  # Query string override first
  case ":${qs}:" in
    *":via=ipxe:"*|*":client=ipxe:"*)    echo "ipxe";    return 0 ;;
    *":via=cli:"*|*":client=cli:"*)      echo "cli";     return 0 ;;
    *":via=browser:"*|*":client=browser:"*) echo "browser"; return 0 ;;
    *":via=script:"*|*":client=script:"*) echo "script"; return 0 ;;
  esac

  # User-Agent detection (safe if unset)
  local ua="${HTTP_USER_AGENT-}"
  case "$ua" in
    *iPXE*|*ipxe*)         echo "ipxe";    return 0 ;;
    curl/*|Wget/*)         echo "cli";     return 0 ;;
    *Mozilla*|*Chrom*|*Safari*) echo "browser"; return 0 ;;
    "")                    echo "script";  return 0 ;;  # No UA → assume script
  esac

  # Default
  echo "unknown"
  return 0
}

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




