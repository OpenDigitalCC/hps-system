#!/bin/bash
#===============================================================================
# 040-storage-networks.sh
# -----------------------
# Configuration fragment to set up storage network VLANs
#
# Behaviour:
#   - Shows existing storage network configuration if present
#   - Configures storage network VLAN range and subnets
#   - Sets up DNS subdomain mapping for each storage network
#   - Supports jumbo frames configuration
#
# Environment:
#   - Requires DNS_DOMAIN to be set
#   - Appends to CLUSTER_CONFIG_PENDING array
#===============================================================================

cli_info "Configure storage networks" "Storage Network Setup"

# Get DNS domain (required)
dns_domain=$(config_get_value "DNS_DOMAIN" "")
if [[ -z "$dns_domain" ]]; then
  hps_log "error" "DNS domain not configured yet"
  return 1
fi

# Get current storage network configuration
current_count=$(config_get_value "network_storage_count" "0")
current_mtu=$(config_get_value "network_storage_mtu" "1500")
current_base_vlan=$(config_get_value "network_storage_base_vlan" "31")
current_subnet_base=$(config_get_value "network_storage_subnet_base" "10.31")
current_subnet_cidr=$(config_get_value "network_storage_subnet_cidr" "24")

# Check if storage networks are already configured
if [[ "$current_count" -gt 0 ]]; then
  cli_info "Current storage network configuration:"
  echo "  Number of networks: $current_count"
  echo "  Base VLAN: $current_base_vlan"
  echo "  Subnet base: $current_subnet_base"
  echo "  Subnet CIDR: /$current_subnet_cidr"
  echo "  MTU: $current_mtu"
  
  # Show configured VLANs
  echo "  Configured VLANs:"
  for ((i=0; i<current_count; i++)); do
    local vlan=$((current_base_vlan + i))
    local subnet=$(config_get_value "network_storage_vlan${vlan}_subnet" "")
    local domain=$(config_get_value "network_storage_vlan${vlan}_domain" "")
    echo "    - VLAN $vlan: $subnet (${domain})"
  done
  echo
  
  if [[ $(cli_prompt_yesno "Keep current storage network configuration?" "y") == "y" ]]; then
    # Re-add all storage configuration to pending
    CLUSTER_CONFIG_PENDING+=("network_storage_count:$current_count")
    CLUSTER_CONFIG_PENDING+=("network_storage_mtu:$current_mtu")
    CLUSTER_CONFIG_PENDING+=("network_storage_base_vlan:$current_base_vlan")
    CLUSTER_CONFIG_PENDING+=("network_storage_subnet_base:$current_subnet_base")
    CLUSTER_CONFIG_PENDING+=("network_storage_subnet_cidr:$current_subnet_cidr")
    
    # Re-add each VLAN configuration
    for ((i=0; i<current_count; i++)); do
      local vlan=$((current_base_vlan + i))
      local subnet=$(config_get_value "network_storage_vlan${vlan}_subnet" "")
      local gateway=$(config_get_value "network_storage_vlan${vlan}_gateway" "")
      local netmask=$(config_get_value "network_storage_vlan${vlan}_netmask" "")
      local domain=$(config_get_value "network_storage_vlan${vlan}_domain" "")
      local allocated=$(config_get_value "network_storage_vlan${vlan}_allocated" "false")
      
      CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_subnet:$subnet")
      CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_gateway:$gateway")
      CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_netmask:$netmask")
      CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_domain:$domain")
      CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_allocated:$allocated")
    done
    
    return 0
  fi
fi

# Check if user wants to configure storage networks
if [[ "$current_count" -eq 0 ]] && [[ $(cli_prompt_yesno "Configure storage networks?" "y") == "n" ]]; then
  cli_info "Skipping storage network configuration"
  CLUSTER_CONFIG_PENDING+=("network_storage_count:0")
  return 0
fi

# Get defaults based on current or standard values
default_count=$([[ "$current_count" -gt 0 ]] && echo "$current_count" || echo "2")
default_vlan=$([[ "$current_count" -gt 0 ]] && echo "$current_base_vlan" || echo "31")
default_subnet_base=$([[ "$current_count" -gt 0 ]] && echo "$current_subnet_base" || echo "10.${default_vlan}")
default_cidr=$([[ "$current_count" -gt 0 ]] && echo "$current_subnet_cidr" || echo "24")
default_mtu=$([[ "$current_mtu" == "9000" ]] && echo "y" || echo "n")

# Number of storage networks
cli_note "Storage networks provide dedicated VLANs for iSCSI traffic"
cli_note "Each network requires it's own network interface on each host, and switch / vlan configured"
num_storage_networks=$(cli_prompt "Number of storage networks to configure (1-10)" "$default_count" "^([1-9]|10)$" \
  "Invalid number: must be between 1 and 10")

# Base VLAN ID
cli_note "Storage VLANs will start from this base ID (e.g., 31, 32, 33...)"
storage_base_vlan=$(cli_prompt "Storage network base VLAN ID (31-99)" "$default_vlan" "^[3-9][0-9]$" \
  "Invalid VLAN ID: must be between 31 and 99")

# Additional validation for VLAN range
if [[ "$storage_base_vlan" -lt 31 ]]; then
  hps_log "error" "Base VLAN must be 31 or higher"
  return 1
fi

# Calculate max VLAN to ensure we don't exceed 99
max_vlan=$((storage_base_vlan + num_storage_networks - 1))
if [[ $max_vlan -gt 99 ]]; then
  hps_log "error" "VLAN range would exceed 99 (max would be $max_vlan)"
  return 1
fi

# Subnet base
cli_note "Base for storage subnets (e.g., 10.31 creates 10.31.0.0/24, 10.31.1.0/24, etc.)"
default_subnet_base="10.${storage_base_vlan}"
storage_subnet_base=$(cli_prompt "Storage subnet base" "$default_subnet_base" \
  "^([0-9]{1,3}\.){1}[0-9]{1,3}$" \
  "Invalid subnet base: must be in format X.Y (e.g., 10.31)")

# CIDR mask
storage_subnet_cidr=$(cli_prompt "Storage subnet CIDR mask (16-28)" "$default_cidr" \
  "^(1[6-9]|2[0-8])$" \
  "Invalid CIDR: must be between 16 and 28")

# Jumbo frames
cli_note "Jumbo frames require switch support with MTU 9000+ on all storage ports"
enable_jumbo=$(cli_prompt_yesno "Enable jumbo frames (9000 MTU) on storage networks?" "$default_mtu")

local mtu=1500
[[ "$enable_jumbo" == "y" ]] && mtu=9000

# Store base configuration
CLUSTER_CONFIG_PENDING+=("network_storage_count:$num_storage_networks")
CLUSTER_CONFIG_PENDING+=("network_storage_mtu:$mtu")
CLUSTER_CONFIG_PENDING+=("network_storage_base_vlan:$storage_base_vlan")
CLUSTER_CONFIG_PENDING+=("network_storage_subnet_base:$storage_subnet_base")
CLUSTER_CONFIG_PENDING+=("network_storage_subnet_cidr:$storage_subnet_cidr")

# Configure each storage network
cli_info "Generating storage network configuration..."
for ((i=0; i<num_storage_networks; i++)); do
  local vlan=$((storage_base_vlan + i))
  
  # Calculate subnet using the shared function
  local subnet=$(network_calculate_subnet "$storage_subnet_base" "$i" "$storage_subnet_cidr")
  if [[ $? -ne 0 ]]; then
    hps_log "error" "Failed to calculate subnet for storage network $((i+1))"
    return 1
  fi
  
  # Extract network portion for gateway
  local network_addr="${subnet%/*}"
  local gateway="${network_addr%.*}.1"
  local netmask=$(cidr_to_netmask "${storage_subnet_cidr}")
  local domain="storage$((i+1)).${dns_domain}"
  
  # Store each VLAN configuration
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_subnet:$subnet")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_gateway:$gateway")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_netmask:$netmask")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_domain:$domain")
  CLUSTER_CONFIG_PENDING+=("network_storage_vlan${vlan}_allocated:false")
  
  echo "  - Storage network $((i+1)): VLAN $vlan, subnet $subnet, domain $domain"
done

cli_info "Storage network configuration complete"
