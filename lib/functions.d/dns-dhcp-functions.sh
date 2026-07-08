#!/bin/bash

#===============================================================================
# update_dns_dhcp_files
# ---------------------
# Orchestrator function to rebuild both DNS and DHCP configuration files.
#
# Usage:
#   update_dns_dhcp_files [cluster_name] [reload_services]
#
# Parameters:
#   cluster_name     - Optional. Cluster to update (default: active cluster)
#   reload_services  - Optional. "true" to reload services (default: "true")
#
# Behaviour:
#   - Calls build_dhcp_addresses_file to create DHCP reservations
#   - Calls init_dns_hosts_file to create DNS hosts file
#   - Optionally updates resolv.conf
#   - Optionally reloads dnsmasq service
#   - Both files are written atomically (temp file then move)
#   - Logs all operations
#
# Returns:
#   0 if both files created successfully
#   1 if either file creation fails
#
# Example usage:
#   update_dns_dhcp_files                    # Active cluster, reload services
#   update_dns_dhcp_files "cluster-1"        # Specific cluster, reload services
#   update_dns_dhcp_files "cluster-1" "false" # Specific cluster, no reload
#
#===============================================================================
update_dns_dhcp_files() {
  local cluster="${1:-}"
  local reload_services="${2:-true}"
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  hps_log info "Updating DNS and DHCP configuration files for cluster: $cluster"
  
  local dhcp_result=0
  local dns_result=0
  
  # Build DHCP addresses file
  if ! build_dhcp_addresses_file "$cluster"; then
    hps_log error "Failed to build DHCP addresses file"
    dhcp_result=1
  fi
  
  # Initialize DNS hosts file
  if ! init_dns_hosts_file "$cluster" "$reload_services"; then
    hps_log error "Failed to build DNS hosts file"
    dns_result=1
  fi
  
  # Return failure if either failed
  if [[ $dhcp_result -ne 0 ]] || [[ $dns_result -ne 0 ]]; then
    hps_log error "DNS/DHCP file update completed with errors"
    return 1
  fi

  # Update local resolv.conf only if this is the active cluster
  local active_cluster
  active_cluster=$(hps_get_config active_cluster 2>/dev/null) || active_cluster=""
  
  if [[ "$cluster" == "$active_cluster" ]]; then
    _ips_resolv_conf_update "$cluster"
  fi

  hps_log info "DNS/DHCP file update completed successfully"
  return 0
}

#===============================================================================
# build_dhcp_addresses_file
# -------------------------
# Build DHCP reservations file for dnsmasq from cluster host configurations.
#
# Usage:
#   build_dhcp_addresses_file [cluster_name]
#
# Parameters:
#   cluster_name - Optional. Cluster to build file for (default: active cluster)
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
#   /srv/hps-config/clusters/<cluster>/services/dhcp_addresses
#
# Format:
#   52:54:00:12:34:56,10.99.1.2,TCH-001
#
# Returns:
#   0 on success
#   1 on failure (invalid data, write error, missing dependencies)
#
# Example usage:
#   build_dhcp_addresses_file                # Active cluster
#   build_dhcp_addresses_file "cluster-1"    # Specific cluster
#
#===============================================================================
build_dhcp_addresses_file() {
  local cluster="${1:-}"
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  # Build explicit path
  local config_base
  config_base=$(hps_get_config config_base) || return 1
  local services_dir="${config_base}/clusters/${cluster}/services"
  local dhcp_addresses="${services_dir}/dhcp_addresses"
  local dhcp_addresses_tmp="${dhcp_addresses}.tmp"
  
  hps_log info "Building DHCP addresses file: $dhcp_addresses"
  
  # Create services directory if it doesn't exist
  if [[ ! -d "$services_dir" ]]; then
    if ! mkdir -p "$services_dir"; then
      hps_log error "Failed to create services directory: $services_dir"
      return 1
    fi
  fi
  
  # Get list of all hosts for this cluster
  local hosts
  hosts=$(list_cluster_hosts "$cluster")
  if [[ $? -ne 0 ]]; then
    hps_log error "Failed to list cluster hosts for $cluster"
    return 1
  fi
  
  # Start with empty temp file
  > "$dhcp_addresses_tmp"
  
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
    hostname=$(host_registry "$mac" get HOSTNAME 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$hostname" ]]; then
      hps_log warn "Skipping host $mac: could not get HOSTNAME"
      continue
    fi
    
    # Get IP address
    ip=$(host_registry "$mac" get IP 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$ip" ]]; then
      hps_log warn "Skipping host $mac: could not get IP"
      continue
    fi
    
    # Validate IP address
    if ! validate_ip_address "$ip"; then
      hps_log warn "Skipping host $mac: invalid IP address format: $ip"
      continue
    fi
    
    # Validate hostname
    if ! validate_hostname "$hostname"; then
      hps_log warn "Skipping host $mac: invalid hostname format: $hostname"
      continue
    fi
    
    # Format MAC with colons
    mac_formatted=$(format_mac_colons "$mac")
    if [[ $? -ne 0 ]] || [[ -z "$mac_formatted" ]]; then
      hps_log warn "Skipping host $mac: could not format MAC address"
      continue
    fi

    # Check for duplicate MAC address
    if [[ ${seen_macs[$mac_formatted]+isset} ]]; then
      hps_log warn "Skipping host: duplicate MAC address $mac_formatted (already assigned to ${seen_macs[$mac_formatted]})"
      continue
    fi

    # Check for duplicate IP address - this is a fatal error
    if [[ ${seen_ips[$ip]+isset} ]]; then
      local previous_mac="${seen_ips[$ip]}"
      hps_log error "Duplicate IP address detected: $ip is assigned to both MAC $mac ($hostname) and MAC $previous_mac"
      hps_log error "Cannot build DHCP addresses file with duplicate IP addresses"
      rm -f "$dhcp_addresses_tmp"
      return 1
    fi
    
    # Write entry to temp file
    echo "${mac_formatted},${ip},${hostname}" >> "$dhcp_addresses_tmp"
    
    # Track this MAC and IP
    seen_macs[$mac_formatted]="$hostname"
    seen_ips[$ip]="$mac"
    
    entry_count=$((entry_count + 1))
  done
  
  # Move temp file to final location
  if ! mv "$dhcp_addresses_tmp" "$dhcp_addresses"; then
    hps_log error "Failed to write DHCP addresses file: $dhcp_addresses"
    rm -f "$dhcp_addresses_tmp"
    return 1
  fi
  
  hps_log info "DHCP addresses file created with $entry_count entries"
  return 0
}

#===============================================================================
# init_dns_hosts_file
# -------------------
# Initialize DNS hosts file for dnsmasq.
#
# Usage:
#   init_dns_hosts_file [cluster_name] [reload_service]
#
# Parameters:
#   cluster_name   - Optional. Cluster to initialize (default: active cluster)
#   reload_service - Optional. "true" to reload dnsmasq (default: "true")
#
# Behaviour:
#   - Creates DNS hosts file with IPS entry
#   - Gets DNS domain and IPS IP from cluster config
#   - Adds IPS with standard service aliases using dns_host_add
#   - Creates parent directory if needed
#   - Optionally reloads dnsmasq service
#
# Output File:
#   /srv/hps-config/clusters/<cluster>/services/dns_hosts
#
# Format:
#   10.99.1.1 ips ips.cluster.local ntp syslog dhcp dns
#
# Returns:
#   0 on success (file created)
#   1 on failure (invalid data, write error, missing dependencies)
#
# Example usage:
#   init_dns_hosts_file                      # Active cluster, reload
#   init_dns_hosts_file "cluster-1"          # Specific cluster, reload
#   init_dns_hosts_file "cluster-1" "false"  # Specific cluster, no reload
#
#===============================================================================
init_dns_hosts_file() {
  local cluster="${1:-}"
  local reload_service="${2:-true}"
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  # Build explicit path
  local config_base
  config_base=$(hps_get_config config_base) || return 1
  local services_dir="${config_base}/clusters/${cluster}/services"
  local dns_hosts_file="${services_dir}/dns_hosts"
  
  hps_log info "Initializing DNS hosts file: $dns_hosts_file"
  
  # Create services directory if it doesn't exist
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
  dns_domain=$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$dns_domain" ]]; then
    hps_log error "Failed to get network_dns_domain from cluster $cluster"
    return 1
  fi
  dns_domain=$(strip_quotes "$dns_domain")
  
  # Get IPS IP address (use network_dhcp_ip as IPS address)
  local ips_ip
  ips_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null)
  if [[ $? -ne 0 ]] || [[ -z "$ips_ip" ]]; then
    hps_log error "Failed to get network_dhcp_ip from cluster $cluster"
    return 1
  fi
  
  # Validate IPS IP
  if ! validate_ip_address "$ips_ip"; then
    hps_log error "Invalid network_dhcp_ip: $ips_ip"
    return 1
  fi
  
  # Add IPS entry with service aliases
  local ips_aliases=("ntp" "syslog" "dhcp" "dns")
  if ! dns_host_add "$ips_ip" "ips" "$dns_domain" "$cluster" "$reload_service" "${ips_aliases[@]}"; then
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
# Usage:
#   dns_host_add <ip> <hostname> <domain> [cluster] [reload_service] [alias1] [alias2] ...
#
# Parameters:
#   ip             - IP address (required)
#   hostname       - Short hostname (required)
#   domain         - DNS domain for FQDN (required)
#   cluster        - Cluster name (optional, default: active cluster)
#   reload_service - "true"/"false" to reload dnsmasq (optional, default: "true")
#   aliases        - Additional aliases (optional)
#
# Behaviour:
#   - Validates IP address
#   - Validates hostname format
#   - If entry exists (by IP or hostname), updates it
#   - If new, appends to file
#   - Constructs entry: IP hostname [hostname.domain] [aliases...]
#   - Creates file if doesn't exist
#   - Optionally reloads dnsmasq service
#
# Format:
#   10.99.1.2 tch-001 tch-001.cluster.local
#   10.99.1.1 ips ips.cluster.local ntp syslog dhcp dns
#
# Returns:
#   0 on success
#   1 on failure (invalid input, write error)
#
# Example usage:
#   dns_host_add "10.99.1.2" "tch-001" "home"
#   dns_host_add "10.99.1.2" "tch-001" "home" "cluster-1" "false"
#   dns_host_add "10.99.1.1" "ips" "home" "" "true" "ntp" "syslog"
#
#===============================================================================
dns_host_add() {
  local ip="$1"
  local hostname="$2"
  local domain="$3"
  local cluster="${4:-}"
  local reload_service="${5:-true}"
  shift 5 || shift $#  # Remove first 5 args, or all if less than 5
  local aliases=("$@")
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster 2>/dev/null) || cluster=""
  fi
  
  # Build explicit path
  local dns_hosts_file
  if [[ -n "$cluster" ]]; then
    local config_base
    config_base=$(hps_get_config config_base) || return 1
    dns_hosts_file="${config_base}/clusters/${cluster}/services/dns_hosts"
  else
    hps_log error "No cluster specified and no active cluster configured"
    return 1
  fi
  
  # Validate IP address
  if [[ -z "$ip" ]] || ! validate_ip_address "$ip"; then
    hps_log error "Invalid IP address: $ip"
    return 1
  fi
  
  # Validate hostname
  if [[ -z "$hostname" ]] || ! validate_hostname "$hostname"; then
    hps_log error "Invalid hostname: $hostname"
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
        hps_log debug "Updated entry for $hostname ($ip)"
      else
        # Keep existing line
        echo "$line" >> "$temp_file"
      fi
    done < "$dns_hosts_file"
  fi
  
  # If not found, append new entry
  if [[ $found -eq 0 ]]; then
    echo "$entry" >> "$temp_file"
    hps_log debug "Added new entry for $hostname ($ip)"
  fi
  
  # Atomic move
  if ! mv "$temp_file" "$dns_hosts_file"; then
    hps_log error "Failed to write DNS hosts file"
    rm -f "$temp_file"
    return 1
  fi
  
  # Reload dnsmasq if requested and this is the active cluster
  if [[ "$reload_service" == "true" ]]; then
    local active_cluster
    active_cluster=$(hps_get_config active_cluster 2>/dev/null) || active_cluster=""
    
    if [[ "$cluster" == "$active_cluster" ]]; then
      supervisor_reload_services dnsmasq
    fi
  fi
  
  hps_log info "$hostname ($ip) added/updated"
  return 0
}

#===============================================================================
# _ips_resolv_conf_update
# -----------------------
# Update /etc/resolv.conf with IPS nameserver and DNS domain.
#
# Usage:
#   _ips_resolv_conf_update [cluster_name]
#
# Parameters:
#   cluster_name - Optional. Cluster to use (default: active cluster)
#
# Behaviour:
#   - Gets IPS IP address from cluster config
#   - Gets DNS domain from cluster config
#   - Writes /etc/resolv.conf with nameserver and search domain
#
# Returns:
#   0 on success
#   1 on failure
#
# Example usage:
#   _ips_resolv_conf_update              # Use active cluster
#   _ips_resolv_conf_update "cluster-1"  # Use specific cluster
#
#===============================================================================
_ips_resolv_conf_update() {
  local cluster="${1:-}"
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  local ips_ip dns_domain
  
  ips_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null) || {
    hps_log error "Failed to get network_dhcp_ip from cluster $cluster"
    return 1
  }
  
  dns_domain=$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null) || {
    hps_log error "Failed to get network_dns_domain from cluster $cluster"
    return 1
  }
  
  cat > /etc/resolv.conf <<EOF
nameserver ${ips_ip}
search ${dns_domain}
EOF
  
  hps_log info "Created /etc/resolv.conf with nameserver ${ips_ip} and search ${dns_domain}"
  return 0
}
