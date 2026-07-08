#!/bin/bash
#===============================================================================
# 020-set-dhcp-interface.sh
# -------------------------
# Configuration fragment to select DHCP listening interface
#
# Behaviour:
#   - Shows current DHCP configuration if exists
#   - Lists available network interfaces
#   - Requires selection of interface for DHCP/dnsmasq
#   - Calculates and stores network information
#   - Validates interface has IPv4 address
#
# Environment:
#   - Requires network functions (get_network_interfaces, etc)
#   - Appends to CLUSTER_CONFIG_PENDING array
#===============================================================================

cli_info "Configure DHCP interface"

# Get current DHCP configuration
current_enabled=$(config_get_value "network_dhcp_enabled" "true")
current_iface=$(config_get_value "network_dhcp_iface" "")
current_ip=$(config_get_value "network_dhcp_ip" "")
current_cidr=$(config_get_value "network_dhcp_cidr" "")
current_network=$(config_get_value "network_cidr" "")
current_rangesize=$(config_get_value "network_dhcp_rangesize" "100")

# Show current configuration if exists
if [[ -n "$current_iface" ]] && [[ "$current_enabled" == "true" ]]; then
  cli_info "Current DHCP configuration:"
  echo "  Interface: $current_iface"
  echo "  IP: $current_ip"
  echo "  Network: $current_network"
  echo "  DHCP Range Size: $current_rangesize"
  echo
  
  if [[ $(cli_prompt_yesno "Keep current DHCP configuration?" "y") == "y" ]]; then
    # Re-add current configuration to pending
    CLUSTER_CONFIG_PENDING+=("network_dhcp_enabled:$current_enabled")
    CLUSTER_CONFIG_PENDING+=("network_dhcp_iface:$current_iface")
    CLUSTER_CONFIG_PENDING+=("network_dhcp_ip:$current_ip")
    CLUSTER_CONFIG_PENDING+=("network_dhcp_cidr:$current_cidr")
    CLUSTER_CONFIG_PENDING+=("network_cidr:$current_network")
    CLUSTER_CONFIG_PENDING+=("network_dhcp_rangesize:$current_rangesize")
    return 0
  fi
fi

# Select interface
selected=$(select_network_interface "Select interface to listen on for boot requests")

if [[ -z "$selected" ]]; then
  hps_log "error" "No interface selected"
  return 1
fi

# Get detailed network info
network_info=$(get_interface_network_info "$selected")
if [[ $? -ne 0 ]]; then
  return 1
fi

# Parse network info
IFS='|' read -r iface ipaddr cidr ip_cidr network_cidr <<< "$network_info"

cli_info "Selected $iface with IP $ip_cidr (network $network_cidr)"

# Ask for DHCP range size
rangesize=$(cli_prompt "DHCP range size (number of IPs)" "$current_rangesize" "^[1-9][0-9]*$" \
  "Invalid range size: must be a positive number")

# Store configuration
CLUSTER_CONFIG_PENDING+=("network_dhcp_enabled:true")
CLUSTER_CONFIG_PENDING+=("network_dhcp_iface:$iface")
CLUSTER_CONFIG_PENDING+=("network_dhcp_ip:$ipaddr")
CLUSTER_CONFIG_PENDING+=("network_dhcp_cidr:$ip_cidr")
CLUSTER_CONFIG_PENDING+=("network_cidr:$network_cidr")
CLUSTER_CONFIG_PENDING+=("network_dhcp_rangesize:$rangesize")

cli_info "DHCP configuration complete"
