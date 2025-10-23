


_set_ips_hostname () {
  IPS_HOSTNAME="ips.$(cluster_config get DNS_DOMAIN)"
  hostname "$IPS_HOSTNAME"
  echo "$IPS_HOSTNAME" > /etc/hostname
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
  local DHCP_ADDRESSES="$(get_path_cluster_services_dir)/dhcp_addresses"
  local DHCP_ADDRESSES_TMP="${DHCP_ADDRESSES}.tmp"
  
  hps_log "INFO" "Building DHCP addresses file: $DHCP_ADDRESSES"
  
  # Create services directory if it doesn't exist
  if [[ ! -d "$(get_path_cluster_services_dir)" ]]; then
    if ! mkdir -p "$(get_path_cluster_services_dir)"; then
      hps_log "ERROR" "Failed to create services directory: $(get_path_cluster_services_dir)"
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
    if [[ ${seen_macs[$mac_formatted]+isset} ]]; then
      hps_log "WARN" "Skipping host: duplicate MAC address $mac_formatted (already assigned to ${seen_macs[$mac_formatted]})"
      continue
    fi

    # Check for duplicate IP address - this is a fatal error
    if [[ ${seen_ips[$ip]+isset} ]]; then
      local previous_mac="${seen_ips[$ip]}"
      hps_log "ERROR" "Duplicate IP address detected: $ip is assigned to both MAC $mac ($hostname) and MAC $previous_mac"
      hps_log "ERROR" "Cannot build DHCP addresses file with duplicate IP addresses"
      rm -f "$DHCP_ADDRESSES_TMP"
      return 1
    fi


    
    # Write entry to temp file
    echo "${mac_formatted},${ip},${hostname}" >> "$DHCP_ADDRESSES_TMP"
    
    # Track this MAC and IP (store MAC for IP tracking)
    seen_macs[$mac_formatted]="$hostname"
    seen_ips[$ip]="$mac"
    
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
# init_dns_hosts_file
# -------------------
# Initialize DNS hosts file for dnsmasq if it doesn't exist.
#
# Behaviour:
#   - Checks if dns_hosts file already exists
#   - If not, creates it with IPS entry
#   - Gets DNS domain and IPS IP from cluster config
#   - Adds IPS with standard service aliases using dns_host_add
#   - Creates parent directory if needed
#
# Output File:
#   ${HPS_CLUSTER_CONFIG_DIR}/services/dns_hosts
#
# Format:
#   10.99.1.1 ips ips.cluster.local ntp syslog dhcp dns
#
# Note:
#   Uses expand-hosts directive in dnsmasq.conf to append domain.
#   IPS is added with both short and FQDN forms.
#
# Returns:
#   0 on success (file created or already exists)
#   1 on failure (invalid data, write error, missing dependencies)
#===============================================================================
init_dns_hosts_file() {
  local dns_hosts_file="$(get_path_cluster_services_dir)/dns_hosts"
  
  # If file already exists, nothing to do
  if [[ -f "$dns_hosts_file" ]]; then
    hps_log debug "DNS hosts file already exists: $dns_hosts_file"
    return 0
  fi
  
  hps_log info "Initializing DNS hosts file: $dns_hosts_file"
  
  # Create services directory if it doesn't exist
  local services_dir
  services_dir="$(get_path_cluster_services_dir)"
  if [[ ! -d "$services_dir" ]]; then
    if ! mkdir -p "$services_dir"; then
      hps_log error "Failed to create services directory: $services_dir"
      return 1
    fi
  fi
  
  # Create empty file
  if ! touch "$dns_hosts_file"; then
    hps_log error "Failed to create DNS hosts file: $dns_hosts_file"
    return 1
  fi
  
  # Get DNS domain from cluster config
  local dns_domain
  dns_domain=$(cluster_config get DNS_DOMAIN 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$dns_domain" ]]; then
    hps_log error "Failed to get DNS_DOMAIN from cluster config"
    return 1
  fi
  dns_domain=$(strip_quotes "$dns_domain")
  
  # Get IPS IP address (use DHCP_IP as IPS address)
  local ips_ip
  ips_ip=$(cluster_config get DHCP_IP 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$ips_ip" ]]; then
    hps_log error "Failed to get DHCP_IP from cluster config"
    return 1
  fi
  
  # Validate IPS IP
  if ! validate_ip_address "$ips_ip"; then
    hps_log error "Invalid DHCP_IP: $ips_ip"
    return 1
  fi
  
  # Add IPS entry with service aliases
  local ips_aliases=("ntp" "syslog" "dhcp" "dns")
  if ! dns_host_add "$ips_ip" "ips" "$dns_domain" "${ips_aliases[@]}"; then
    hps_log error "Failed to add IPS entry to DNS hosts file"
    return 1
  fi
  
  hps_log info "DNS hosts file initialized successfully"
  return 0
}

#===============================================================================
# dns_host_add
# ------------
# Add or update a host entry in the DNS hosts file.
#
# Usage: dns_host_add <ip> <hostname> [domain] [alias1] [alias2] ...
#
# Arguments:
#   $1 - IP address
#   $2 - hostname (short name)
#   $3 - domain (optional, for FQDN)
#   $4+ - aliases (optional)
#
# Behaviour:
#   - Validates IP address
#   - Validates hostname format
#   - If entry exists (by IP or hostname), updates it
#   - If new, appends to file
#   - Constructs entry: IP hostname [hostname.domain] [aliases...]
#   - Creates file if doesn't exist
#
# Format:
#   10.99.1.2 tch-001 tch-001.cluster.local
#   10.99.1.1 ips ips.cluster.local ntp syslog dhcp dns
#
# Returns:
#   0 on success
#   1 on failure (invalid input, write error)
#===============================================================================
dns_host_add() {
  local ip="$1"
  local hostname="$2"
  local domain="${3:-}"
  shift 3 || shift $#  # Remove first 3 args, or all if less than 3
  local aliases=("$@")
  
  local dns_hosts_file="$(get_path_cluster_services_dir)/dns_hosts"
  
  # Validate IP address
  if [[ -z "$ip" ]] || ! validate_ip_address "$ip"; then
    hps_log error "dns_host_add: Invalid IP address: $ip"
    return 1
  fi
  
  # Validate hostname
  if [[ -z "$hostname" ]] || ! validate_hostname "$hostname"; then
    hps_log error "dns_host_add: Invalid hostname: $hostname"
    return 1
  fi
  
  # Ensure file exists
  if [[ ! -f "$dns_hosts_file" ]]; then
    local services_dir
    services_dir="$(dirname "$dns_hosts_file")"
    mkdir -p "$services_dir" || return 1
    touch "$dns_hosts_file" || return 1
  fi
  
  # Build entry line
  local entry="$ip $hostname"
  
  # Add FQDN if domain provided
  if [[ -n "$domain" ]]; then
    entry="$entry ${hostname}.${domain}"
  fi
  
  # Add aliases
  if [[ ${#aliases[@]} -gt 0 ]]; then
    entry="$entry ${aliases[*]}"
  fi
  
  # Check if entry already exists (by IP or hostname)
  local temp_file="${dns_hosts_file}.tmp"
  local found=0
  
  if [[ -f "$dns_hosts_file" ]]; then
    while IFS= read -r line; do
      # Skip comments and empty lines
      [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]] && continue
      
      # Check if this line has our IP or hostname
      local line_ip line_hostname
      read -r line_ip line_hostname _ <<< "$line"
      
      if [[ "$line_ip" == "$ip" ]] || [[ "$line_hostname" == "$hostname" ]]; then
        # Replace this line with new entry
        echo "$entry" >> "$temp_file"
        found=1
        hps_log debug "dns_host_add: Updated entry for $hostname ($ip)"
      else
        # Keep existing line
        echo "$line" >> "$temp_file"
      fi
    done < "$dns_hosts_file"
  fi
  
  # If not found, append new entry
  if [[ $found -eq 0 ]]; then
    echo "$entry" >> "$temp_file"
    hps_log debug "dns_host_add: Added new entry for $hostname ($ip)"
  fi
  
  # Atomic move
  if ! mv "$temp_file" "$dns_hosts_file"; then
    hps_log error "dns_host_add: Failed to write DNS hosts file"
    rm -f "$temp_file"
    return 1
  fi
  
  hps_log info "dns_host_add: $hostname ($ip) added/updated"
  return 0
}

#===============================================================================
# dns_host_remove
# ---------------
# Remove a host entry from the DNS hosts file.
#
# Usage: dns_host_remove <hostname_or_ip>
#
# Arguments:
#   $1 - hostname or IP address to remove
#
# Behaviour:
#   - Searches for entries matching hostname or IP
#   - Removes matching entries
#   - Preserves comments and empty lines
#   - Does nothing if entry not found (not an error)
#
# Returns:
#   0 on success (entry removed or not found)
#   1 on failure (write error)
#===============================================================================
dns_host_remove() {
  local identifier="$1"
  local dns_hosts_file="$(get_path_cluster_services_dir)/dns_hosts"
  
  if [[ -z "$identifier" ]]; then
    hps_log error "dns_host_remove: No hostname or IP provided"
    return 1
  fi
  
  if [[ ! -f "$dns_hosts_file" ]]; then
    hps_log debug "dns_host_remove: DNS hosts file does not exist"
    return 0
  fi
  
  local temp_file="${dns_hosts_file}.tmp"
  local removed=0
  
  while IFS= read -r line; do
    # Keep comments and empty lines
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
      echo "$line" >> "$temp_file"
      continue
    fi
    
    # Check if this line contains our identifier
    local line_ip line_hostname
    read -r line_ip line_hostname _ <<< "$line"
    
    if [[ "$line_ip" == "$identifier" ]] || [[ "$line_hostname" == "$identifier" ]]; then
      # Skip this line (remove it)
      removed=1
      hps_log debug "dns_host_remove: Removed entry: $line"
    else
      # Keep this line
      echo "$line" >> "$temp_file"
    fi
  done < "$dns_hosts_file"
  
  # Atomic move
  if ! mv "$temp_file" "$dns_hosts_file"; then
    hps_log error "dns_host_remove: Failed to write DNS hosts file"
    rm -f "$temp_file"
    return 1
  fi
  
  if [[ $removed -eq 1 ]]; then
    hps_log info "dns_host_remove: $identifier removed"
  else
    hps_log debug "dns_host_remove: $identifier not found (no action taken)"
  fi
  
  return 0
}

#===============================================================================
# dns_host_get
# ------------
# Get DNS host entry by hostname or IP.
#
# Usage: dns_host_get <hostname_or_ip>
#
# Arguments:
#   $1 - hostname or IP address to look up
#
# Behaviour:
#   - Searches dns_hosts file for matching entry
#   - Returns entire line if found
#   - Can be used to check if entry exists
#
# Output:
#   Matching line from dns_hosts file, or empty if not found
#
# Returns:
#   0 if entry found (outputs line to stdout)
#   1 if entry not found or file doesn't exist
#===============================================================================
dns_host_get() {
  local identifier="$1"
  local dns_hosts_file="$(get_path_cluster_services_dir)/dns_hosts"
  
  if [[ -z "$identifier" ]]; then
    return 1
  fi
  
  if [[ ! -f "$dns_hosts_file" ]]; then
    return 1
  fi
  
  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]] && continue
    
    # Check if this line contains our identifier
    local line_ip line_hostname
    read -r line_ip line_hostname _ <<< "$line"
    
    if [[ "$line_ip" == "$identifier" ]] || [[ "$line_hostname" == "$identifier" ]]; then
      echo "$line"
      return 0
    fi
  done < "$dns_hosts_file"
  
  return 1
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
  
  # Initialise DNS hosts file
  if ! init_dns_hosts_file; then
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
