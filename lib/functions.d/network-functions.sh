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


#===============================================================================
# normalise_mac
# -------------
# Normalize MAC address to 12-character lowercase hex string without delimiters.
#
# Parameters:
#   $1 - MAC address in any common format (with :, -, ., or spaces)
#
# Output:
#   Normalized MAC address (12 hex chars, lowercase, no delimiters)
#   Error message to stderr if invalid
#
# Returns:
#   0 on success
#   1 if MAC address format is invalid
#
# Example:
#   normalise_mac "52:54:00:12:34:56"  # outputs: 525400123456
#   normalise_mac "52-54-00-12-34-56"  # outputs: 525400123456
#===============================================================================
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

#===============================================================================
# format_mac_colons
# -----------------
# Format a normalized MAC address with colon delimiters.
#
# Parameters:
#   $1 - MAC address (12 hex chars, no delimiters)
#
# Output:
#   MAC address in format: xx:xx:xx:xx:xx:xx
#   Error message to stderr if invalid
#
# Returns:
#   0 on success
#   1 if MAC address format is invalid
#
# Example:
#   format_mac_colons "525400123456"  # outputs: 52:54:00:12:34:56
#===============================================================================
format_mac_colons() {
  local mac="$1"
  
  # Validate: must be exactly 12 hex characters
  if [[ ! "$mac" =~ ^[0-9a-fA-F]{12}$ ]]; then
    echo "[x] Invalid MAC address format: $1" >&2
    return 1
  fi
  
  # Convert to lowercase and insert colons
  mac="${mac,,}"
  echo "${mac:0:2}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"
}

#===============================================================================
# strip_quotes
# ------------
# Remove surrounding quotes from a string.
#
# Parameters:
#   $1 - String potentially with quotes
#
# Output:
#   String without surrounding quotes
#
# Returns:
#   0 always (even if no quotes present)
#
# Example:
#   strip_quotes '"test1.home"'  # outputs: test1.home
#   strip_quotes "'test1.home'"  # outputs: test1.home
#   strip_quotes 'test1.home'    # outputs: test1.home
#===============================================================================
strip_quotes() {
  local str="$1"
  
  # Remove leading quote (single or double)
  str="${str#\"}"
  str="${str#\'}"
  
  # Remove trailing quote (single or double)
  str="${str%\"}"
  str="${str%\'}"
  
  echo "$str"
}

#===============================================================================
# validate_ip_address
# -------------------
# Validate IPv4 address format.
#
# Parameters:
#   $1 - IP address string to validate
#
# Returns:
#   0 if valid IPv4 format
#   1 if invalid format
#
# Note:
#   Only validates format, not reachability or subnet validity.
#   Checks each octet is 0-255.
#
# Example:
#   validate_ip_address "10.99.1.1"    # returns 0
#   validate_ip_address "192.168.1.256" # returns 1
#===============================================================================
validate_ip_address() {
  local ip="$1"
  local octet_regex='^([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$'
  
  # Check basic format: four octets separated by dots
  if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    return 1
  fi
  
  # Split into octets and validate each
  IFS='.' read -r -a octets <<< "$ip"
  
  for octet in "${octets[@]}"; do
    if [[ ! "$octet" =~ $octet_regex ]]; then
      return 1
    fi
  done
  
  return 0
}

#===============================================================================
# validate_hostname
# -----------------
# Validate hostname format (DNS-compliant).
#
# Parameters:
#   $1 - Hostname string to validate
#
# Returns:
#   0 if valid hostname format
#   1 if invalid format
#
# Note:
#   Validates according to RFC 1123:
#   - Max 253 characters total
#   - Labels max 63 characters
#   - Alphanumeric and hyphens only
#   - Cannot start or end with hyphen
#   - Case insensitive
#
# Example:
#   validate_hostname "TCH-001"       # returns 0
#   validate_hostname "host.domain"   # returns 0
#   validate_hostname "-invalid"      # returns 1
#===============================================================================
validate_hostname() {
  local hostname="$1"
  
  # Check total length
  if [[ ${#hostname} -gt 253 ]]; then
    return 1
  fi
  
  # Check if empty
  if [[ -z "$hostname" ]]; then
    return 1
  fi
  
  # Split by dots and validate each label
  IFS='.' read -r -a labels <<< "$hostname"
  
  for label in "${labels[@]}"; do
    # Check label length
    if [[ ${#label} -gt 63 ]] || [[ ${#label} -eq 0 ]]; then
      return 1
    fi
    
    # Check label format: alphanumeric and hyphens, cannot start/end with hyphen
    if [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
      return 1
    fi
  done
  
  return 0
}
