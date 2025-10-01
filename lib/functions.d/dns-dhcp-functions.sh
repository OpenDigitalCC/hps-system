#===============================================================================
# list_cluster_hosts
# ------------------
# List all MAC addresses from host configuration files in the active cluster.
#
# Behaviour:
#   - Reads all *.conf files from ${HPS_HOST_CONFIG_DIR}
#   - Extracts MAC addresses from filenames (without .conf extension)
#   - Normalizes MAC addresses to 12 hex chars without delimiters
#   - Returns space-separated list of MAC addresses
#
# Output:
#   Space-separated MAC addresses (12 hex chars, no delimiters)
#
# Returns:
#   0 on success (even if no hosts found)
#   1 if host config directory doesn't exist or is not readable
#
# Example:
#   list_cluster_hosts  # outputs: 525400123456 5254002345ee 52540061c123
#===============================================================================
list_cluster_hosts() {
  if [[ ! -d "$HPS_HOST_CONFIG_DIR" ]]; then
    hps_log "ERROR" "Host config directory not found: $HPS_HOST_CONFIG_DIR"
    return 1
  fi
  
  if [[ ! -r "$HPS_HOST_CONFIG_DIR" ]]; then
    hps_log "ERROR" "Host config directory not readable: $HPS_HOST_CONFIG_DIR"
    return 1
  fi
  
  local mac_list=""
  local conf_file
  local mac
  local mac_normalized
  
  # Find all .conf files and extract MAC addresses
  for conf_file in "$HPS_HOST_CONFIG_DIR"/*.conf; do
    # Skip if no files match (glob didn't expand)
    [[ -e "$conf_file" ]] || continue
    
    # Extract MAC from filename (remove path and .conf extension)
    mac=$(basename "$conf_file" .conf)
    
    # Normalize MAC address
    mac_normalized=$(normalise_mac "$mac" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
      hps_log "WARN" "Skipping invalid MAC in filename: $mac"
      continue
    fi
    
    # Add to list
    if [[ -n "$mac_list" ]]; then
      mac_list="$mac_list $mac_normalized"
    else
      mac_list="$mac_normalized"
    fi
  done
  
  echo "$mac_list"
  return 0
}

#===============================================================================
# build_dhcp_addresses_file
# -------------------------
# Build DHCP reservations file for dnsmasq from cluster host configurations.
#
# Behaviour:
#   - Iterates through all cluster hosts using list_cluster_hosts
#   - Extracts hostname and IP from each host config
#   - Formats MAC addresses with colons
#   - Detects and prevents duplicate MAC addresses and IP addresses
#   - Writes dhcp-hostsfile format: MAC,IP,hostname
#   - Creates parent directory if needed
#   - Validates data before writing
#
# Output File:
#   ${HPS_CLUSTER_CONFIG_DIR}/services/dhcp_addresses
#
# Format:
#   52:54:00:12:34:56,10.99.1.2,TCH-001
#
# Returns:
#   0 on success
#   1 on failure (invalid data, write error, missing dependencies)
#===============================================================================
build_dhcp_addresses_file() {
  local CLUSTER_SERVICES_DIR="${HPS_CLUSTER_CONFIG_DIR}/services"
  local DHCP_ADDRESSES="${CLUSTER_SERVICES_DIR}/dhcp_addresses"
  local DHCP_ADDRESSES_TMP="${DHCP_ADDRESSES}.tmp"
  
  hps_log "INFO" "Building DHCP addresses file: $DHCP_ADDRESSES"
  
  # Create services directory if it doesn't exist
  if [[ ! -d "$CLUSTER_SERVICES_DIR" ]]; then
    if ! mkdir -p "$CLUSTER_SERVICES_DIR"; then
      hps_log "ERROR" "Failed to create services directory: $CLUSTER_SERVICES_DIR"
      return 1
    fi
  fi
  
  # Get list of all hosts
  local hosts
  hosts=$(list_cluster_hosts)
  if [[ $? -ne 0 ]]; then
    hps_log "ERROR" "Failed to list cluster hosts"
    return 1
  fi
  
  # Start with empty temp file
  > "$DHCP_ADDRESSES_TMP"
  
  local mac
  local hostname
  local ip
  local mac_formatted
  local entry_count=0
  
  # Arrays to track seen MACs and IPs for duplicate detection
  declare -A seen_macs
  declare -A seen_ips
  
  # Process each host
  for mac in $hosts; do
    # Get hostname
    hostname=$(host_config "$mac" get HOSTNAME 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$hostname" ]]; then
      hps_log "WARN" "Skipping host $mac: could not get HOSTNAME from MAC address"
      continue
    fi
    
    # Get IP address
    ip=$(host_config "$mac" get IP 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$ip" ]]; then
      hps_log "WARN" "Skipping host $mac: could not get IP from MAC address"
      continue
    fi
    
    # Validate IP address
    if ! validate_ip_address "$ip"; then
      hps_log "WARN" "Skipping host $mac: invalid IP address format: $ip"
      continue
    fi
    
    # Validate hostname
    if ! validate_hostname "$hostname"; then
      hps_log "WARN" "Skipping host $mac: invalid hostname format: $hostname"
      continue
    fi
    
    # Format MAC with colons
    mac_formatted=$(format_mac_colons "$mac")
    if [[ $? -ne 0 ]] || [[ -z "$mac_formatted" ]]; then
      hps_log "WARN" "Skipping host $mac: could not format MAC address"
      continue
    fi
    
    # Check for duplicate MAC address
    if [[ -n "${seen_macs[$mac_formatted]}" ]]; then
      hps_log "WARN" "Skipping host $mac: duplicate MAC address $mac_formatted (already assigned to ${seen_macs[$mac_formatted]})"
      continue
    fi
    
    # Check for duplicate IP address
    if [[ -n "${seen_ips[$ip]}" ]]; then
      hps_log "WARN" "Skipping host $mac: duplicate IP address $ip (already assigned to ${seen_ips[$ip]})"
      continue
    fi
    
    # Write entry to temp file
    echo "${mac_formatted},${ip},${hostname}" >> "$DHCP_ADDRESSES_TMP"
    
    # Track this MAC and IP
    seen_macs[$mac_formatted]="$hostname"
    seen_ips[$ip]="$hostname"
    
    entry_count=$((entry_count + 1))
  done
  
  # Move temp file to final location
  if ! mv "$DHCP_ADDRESSES_TMP" "$DHCP_ADDRESSES"; then
    hps_log "ERROR" "Failed to write DHCP addresses file: $DHCP_ADDRESSES"
    rm -f "$DHCP_ADDRESSES_TMP"
    return 1
  fi
  
  hps_log "INFO" "DHCP addresses file created with $entry_count entries"
  return 0
}

#===============================================================================
# build_dns_hosts_file
# --------------------
# Build DNS hosts file for dnsmasq from cluster configuration.
#
# Behaviour:
#   - Gets DNS domain from cluster config
#   - Gets IPS IP address from cluster config
#   - Creates DNS entry for IPS with service aliases
#   - Writes addn-hosts format: IP FQDN hostname [aliases...]
#   - Creates parent directory if needed
#   - Validates all data before writing
#
# Output File:
#   ${HPS_CLUSTER_CONFIG_DIR}/services/dns_hosts
#
# Format:
#   10.99.1.1 ips ntp syslog dhcp dns
#
# Note:
#   Uses short hostnames only. The expand-hosts directive in dnsmasq.conf
#   will automatically append the domain to create FQDNs.
#   Cluster hosts are NOT included in this file to avoid duplication with
#   DHCP-assigned hostnames. Only the IPS provisioning node is included.
#
# Returns:
#   0 on success
#   1 on failure (invalid data, write error, missing dependencies)
#===============================================================================
build_dns_hosts_file() {
  local CLUSTER_SERVICES_DIR="${HPS_CLUSTER_CONFIG_DIR}/services"
  local DNS_HOSTS="${CLUSTER_SERVICES_DIR}/dns_hosts"
  local DNS_HOSTS_TMP="${DNS_HOSTS}.tmp"
  
  hps_log "INFO" "Building DNS hosts file: $DNS_HOSTS"
  
  # Create services directory if it doesn't exist
  if [[ ! -d "$CLUSTER_SERVICES_DIR" ]]; then
    if ! mkdir -p "$CLUSTER_SERVICES_DIR"; then
      hps_log "ERROR" "Failed to create services directory: $CLUSTER_SERVICES_DIR"
      return 1
    fi
  fi
  
  # Get DNS domain from cluster config
  local dns_domain
  dns_domain=$(cluster_config get DNS_DOMAIN)
  if [[ $? -ne 0 ]] || [[ -z "$dns_domain" ]]; then
    hps_log "ERROR" "Failed to get DNS_DOMAIN from cluster config"
    return 1
  fi
  
  # Strip quotes from domain
  dns_domain=$(strip_quotes "$dns_domain")
  
  # Get IPS IP address
  local ips_ip
  ips_ip=$(cluster_config get DHCP_IP)
  if [[ $? -ne 0 ]] || [[ -z "$ips_ip" ]]; then
    hps_log "ERROR" "Failed to get DHCP_IP from cluster config"
    return 1
  fi
  
  # Validate IPS IP
  if ! validate_ip_address "$ips_ip"; then
    hps_log "ERROR" "Invalid DHCP_IP: $ips_ip"
    return 1
  fi
  
  # Define IPS service aliases
  local ips_aliases=("ntp" "syslog" "dhcp" "dns")
  local aliases_string="${ips_aliases[*]}"
  
  # Start with empty temp file
  > "$DNS_HOSTS_TMP"
  
  local entry_count=0
  
  # Add IPS entry with service aliases
  # Format: IP hostname [aliases...]
  # Note: expand-hosts in dnsmasq will automatically add domain to create FQDN
  echo "${ips_ip} ips ${aliases_string}" >> "$DNS_HOSTS_TMP"
  entry_count=$((entry_count + 1))
  hps_log "DEBUG" "Added IPS entry: ${ips_ip} ips ${aliases_string}"
  
  # Move temp file to final location
  if ! mv "$DNS_HOSTS_TMP" "$DNS_HOSTS"; then
    hps_log "ERROR" "Failed to write DNS hosts file: $DNS_HOSTS"
    rm -f "$DNS_HOSTS_TMP"
    return 1
  fi
  
  hps_log "INFO" "DNS hosts file created with $entry_count entries"
  return 0
}

#===============================================================================
# update_dns_dhcp_files
# ---------------------
# Orchestrator function to rebuild both DNS and DHCP configuration files.
#
# Behaviour:
#   - Calls build_dhcp_addresses_file to create DHCP reservations
#   - Calls build_dns_hosts_file to create DNS hosts file
#   - Both files are written atomically (temp file then move)
#   - Logs all operations
#
# Returns:
#   0 if both files created successfully
#   1 if either file creation fails
#
# Note:
#   After calling this function, dnsmasq should be reloaded to pick up
#   the new configuration files.
#===============================================================================
update_dns_dhcp_files() {
  hps_log "INFO" "Updating DNS and DHCP configuration files"
  
  local dhcp_result=0
  local dns_result=0
  
  # Build DHCP addresses file
  if ! build_dhcp_addresses_file; then
    hps_log "ERROR" "Failed to build DHCP addresses file"
    dhcp_result=1
  fi
  
  # Build DNS hosts file
  if ! build_dns_hosts_file; then
    hps_log "ERROR" "Failed to build DNS hosts file"
    dns_result=1
  fi
  
  # Return failure if either failed
  if [[ $dhcp_result -ne 0 ]] || [[ $dns_result -ne 0 ]]; then
    hps_log "ERROR" "DNS/DHCP file update completed with errors"
    return 1
  fi
  
  # Reload dnsmasq to pick up new configuration
  reload_supervisor_services dnsmasq
  
  hps_log "INFO" "DNS/DHCP file update completed successfully"
  return 0
}
