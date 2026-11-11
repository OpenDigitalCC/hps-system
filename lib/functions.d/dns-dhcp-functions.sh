#!/bin/bash

#===============================================================================
# dns_regenerate
# --------------
# THE entry point that makes dnsmasq's name data match the registry. Call it
# after any change to a host's IP or HOSTNAME, after a host is added or removed
# from the registry (hps-onboard forget), and after a cluster DNS domain change.
#
# Usage:
#   dns_regenerate [cluster_name] [reload_services]
#
# Parameters:
#   cluster_name     - Optional. Cluster to update (default: active cluster)
#   reload_services  - Optional. "true" (default) sends dnsmasq a SIGHUP once,
#                      at the end, and only for the active cluster. "false"
#                      writes the files only (service start, before dnsmasq runs).
#
# Behaviour:
#   - build_dhcp_addresses_file: MAC,IP,label reservations (dhcp_addresses)
#   - build_dns_hosts_file: dns_hosts, from the registry, whether the host is
#     powered on or not (a host with a reserved address always resolves)
#   - rewrites the IPS's own /etc/resolv.conf (active cluster only)
#   - one dnsmasq reload (supervisor_reload_services dnsmasq); a failed reload
#     is logged and is not an error: the files are right and the next start
#     reads them
#   - both files are written atomically (temp file then move)
#
# Returns:
#   0 if both files were written
#   1 if either file failed (nothing is reloaded)
#
# Example usage:
#   dns_regenerate                  # Active cluster, reload
#   dns_regenerate "lab" "false"    # Specific cluster, no reload
#
#===============================================================================
dns_regenerate() {
  local cluster="${1:-}"
  local reload_services="${2:-true}"
  
  # Get cluster name (provided or active)
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  hps_log info "Regenerating DNS and DHCP files for cluster: $cluster"
  
  local dhcp_result=0
  local dns_result=0
  
  if ! build_dhcp_addresses_file "$cluster"; then
    hps_log error "Failed to build DHCP addresses file"
    dhcp_result=1
  fi
  
  if ! build_dns_hosts_file "$cluster"; then
    hps_log error "Failed to build DNS hosts file"
    dns_result=1
  fi
  
  if [[ $dhcp_result -ne 0 ]] || [[ $dns_result -ne 0 ]]; then
    hps_log error "DNS/DHCP regeneration completed with errors"
    return 1
  fi

  local active_cluster
  active_cluster=$(hps_get_config active_cluster 2>/dev/null) || active_cluster=""
  
  if [[ "$cluster" == "$active_cluster" ]]; then
    _ips_resolv_conf_update "$cluster" || hps_log warn "resolv.conf not updated"
    if [[ "$reload_services" == "true" ]]; then
      supervisor_reload_services dnsmasq || hps_log warn "dnsmasq reload failed; the files are written and are read at the next dnsmasq start"
    fi
  fi

  hps_log info "DNS/DHCP regeneration completed successfully"
  return 0
}

#===============================================================================
# update_dns_dhcp_files
# ---------------------
# Older name of dns_regenerate; same arguments, same behaviour. Kept because
# host_post_config_hooks, commit_changes and service start call it by this name.
#===============================================================================
update_dns_dhcp_files() {
  dns_regenerate "$@"
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
#   - One line per host with all its MACs (host key first, then the audit NICs)
#   - Detects and prevents duplicate MAC addresses and IP addresses
#   - Writes dhcp-hostsfile format: MAC[,MAC...],IP,hostname
#   - Creates parent directory if needed
#   - Validates data before writing
#
# Output File:
#   /srv/hps-config/clusters/<cluster>/services/dhcp_addresses
#
# Format:
#   52:54:00:12:34:56,10.99.1.2,TCH-001
#   30:e1:71:53:c7:48,30:e1:71:53:c7:49,10.99.1.3,sch-001   (a host with two ports)
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
  : > "$dhcp_addresses_tmp"
  
  local mac
  local hostname
  local ip
  local mac_formatted
  local m macs_out entry_count=0
  
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
    
    # Every MAC of the host (the key first, then its recorded NIC MACs) goes on
    # the one line, so dnsmasq hands the host's address to whichever port asks.
    # A MAC already given to an earlier host is left off this line, not moved.
    macs_out=""
    for m in $(host_macs_of "$mac"); do
      mac_formatted=$(format_mac_colons "$m") || mac_formatted=""
      [[ -n "$mac_formatted" ]] || continue
      if [[ ${seen_macs[$mac_formatted]+isset} ]]; then
        hps_log warn "Skipping MAC $mac_formatted of $hostname: already assigned to ${seen_macs[$mac_formatted]}"
        continue
      fi
      macs_out+="${mac_formatted},"
      seen_macs[$mac_formatted]="$hostname"
    done
    if [[ -z "$macs_out" ]]; then
      hps_log warn "Skipping host $mac: no usable MAC address"
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
    # dnsmasq takes the bare label here; the domain is added from domain=
    echo "${macs_out}${ip},${hostname%%.*}" >> "$dhcp_addresses_tmp"
    
    # Track this IP (the MACs are tracked above)
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
# build_dns_hosts_file
# --------------------
# Write the dnsmasq addn-hosts file from the registry.
#
# Usage:
#   build_dns_hosts_file [cluster_name]
#
# Behaviour:
#   - first line: the IPS (network_dhcp_ip) with its service aliases
#   - one line per registry host that has both IP and HOSTNAME, powered on or
#     off: "<ip> <fqdn> <label>". The FQDN is first so the reverse answer is
#     the FQDN; the label gives the short forward name. HOSTNAME that already
#     holds a dot is taken as the FQDN, otherwise <HOSTNAME>.<network_dns_domain>.
#   - one line per recorded storage address: "<ip> <label>-storageN <fqdn>"
#   - a host whose name or address repeats an earlier line is skipped, logged
#   - names are lower case; the file is written atomically
#
# Output File:
#   /srv/hps-config/clusters/<cluster>/services/dns_hosts
#
# Format:
#   10.99.1.1 ips.cluster.local ips ntp syslog dhcp dns
#   10.99.1.10 tch-001.cluster.local tch-001
#
# Returns:
#   0 on success, 1 on failure (missing domain/IPS address, write error)
#===============================================================================
build_dns_hosts_file() {
  local cluster="${1:-}"
  
  if [[ -z "$cluster" ]]; then
    cluster=$(hps_get_config active_cluster) || {
      hps_log error "No cluster specified and no active cluster configured"
      return 1
    }
  fi
  
  local config_base
  config_base=$(hps_get_config config_base) || return 1
  local services_dir="${config_base}/clusters/${cluster}/services"
  local dns_hosts_file="${services_dir}/dns_hosts"
  local tmp_file="${dns_hosts_file}.tmp"
  
  if ! mkdir -p "$services_dir"; then
    hps_log error "Failed to create services directory: $services_dir"
    return 1
  fi
  
  local dns_domain
  dns_domain=$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null) || dns_domain=""
  dns_domain=$(strip_quotes "$dns_domain")
  if [[ -z "$dns_domain" ]]; then
    hps_log error "Failed to get network_dns_domain from cluster $cluster"
    return 1
  fi
  dns_domain="${dns_domain,,}"
  
  local ips_ip
  ips_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null) || ips_ip=""
  if [[ -z "$ips_ip" ]] || ! validate_ip_address "$ips_ip"; then
    hps_log error "Missing or invalid network_dhcp_ip for cluster $cluster: $ips_ip"
    return 1
  fi
  
  hps_log info "Building DNS hosts file: $dns_hosts_file"
  
  declare -A seen_names=()
  declare -A seen_ips=()
  
  if ! echo "$ips_ip ips.${dns_domain} ips ntp syslog dhcp dns" > "$tmp_file"; then
    hps_log error "Failed to write $tmp_file"
    return 1
  fi
  seen_names["ips"]=1
  seen_names["ips.${dns_domain}"]=1
  seen_ips["$ips_ip"]=1
  
  local hosts mac
  hosts=$(list_cluster_hosts "$cluster") || {
    hps_log error "Failed to list cluster hosts for $cluster"
    rm -f "$tmp_file"
    return 1
  }
  
  local hostname ip label fqdn i s_ip s_label s_fqdn count=0
  for mac in $hosts; do
    hostname=$(host_registry "$mac" get HOSTNAME 2>/dev/null) || hostname=""
    ip=$(host_registry "$mac" get IP 2>/dev/null) || ip=""
    if [[ -z "$hostname" ]] || [[ -z "$ip" ]]; then
      continue
    fi
    if ! validate_ip_address "$ip" || ! validate_hostname "$hostname"; then
      hps_log warn "dns_hosts: skipping $mac: invalid IP or HOSTNAME ($ip, $hostname)"
      continue
    fi
    hostname="${hostname,,}"
    label="${hostname%%.*}"
    if [[ "$hostname" == *.* ]]; then
      fqdn="$hostname"
    else
      fqdn="${hostname}.${dns_domain}"
    fi
    if [[ -n "${seen_names[$fqdn]:-}" ]] || [[ -n "${seen_names[$label]:-}" ]] || [[ -n "${seen_ips[$ip]:-}" ]]; then
      hps_log warn "dns_hosts: skipping $mac: $fqdn / $ip repeats an earlier entry"
      continue
    fi
    echo "$ip $fqdn $label" >> "$tmp_file"
    seen_names["$fqdn"]=1
    seen_names["$label"]=1
    seen_ips["$ip"]=1
    count=$((count + 1))
    
    # Storage-network addresses recorded for this host
    for i in 0 1 2 3 4 5 6 7; do
      s_ip=$(host_registry "$mac" get "storage${i}_ip" 2>/dev/null) || s_ip=""
      [[ -n "$s_ip" ]] || continue
      validate_ip_address "$s_ip" || continue
      s_label="${label}-storage$((i + 1))"
      s_fqdn="${s_label}.${fqdn#*.}"
      if [[ -n "${seen_names[$s_fqdn]:-}" ]] || [[ -n "${seen_ips[$s_ip]:-}" ]]; then
        continue
      fi
      echo "$s_ip $s_fqdn $s_label" >> "$tmp_file"
      seen_names["$s_fqdn"]=1
      seen_names["$s_label"]=1
      seen_ips["$s_ip"]=1
    done
  done
  
  if ! mv "$tmp_file" "$dns_hosts_file"; then
    hps_log error "Failed to write DNS hosts file: $dns_hosts_file"
    rm -f "$tmp_file"
    return 1
  fi
  
  hps_log info "DNS hosts file written with $count registry hosts"
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
#   - Writes /etc/resolv.conf with the nameserver and NO search line: glibc
#     appends the search domain to a dotted name after an NXDOMAIN whatever
#     ndots says, which produced <fqdn>.<domain> lookups. Every name the IPS
#     uses is an FQDN or a label dns_hosts carries.
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
  
  local ips_ip
  
  ips_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null) || {
    hps_log error "Failed to get network_dhcp_ip from cluster $cluster"
    return 1
  }
  
  # HPS_RESOLV_CONF redirects the write (tests, bootstrap on a non-IPS host)
  local resolv_conf="${HPS_RESOLV_CONF:-/etc/resolv.conf}"
  cat > "$resolv_conf" <<EOF
nameserver ${ips_ip}
options ndots:1
EOF
  
  hps_log info "Created $resolv_conf with nameserver ${ips_ip} (no search domain)"
  return 0
}
