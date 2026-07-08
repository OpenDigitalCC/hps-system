#===============================================================================
# create_config_dnsmasq
# ---------------------
# Generate dnsmasq configuration file for DHCP/DNS/TFTP services.
#
# Behaviour:
#   - Gets all configuration from cluster registry
#   - Creates dnsmasq.conf in cluster services directory
#   - Initializes dns_hosts and dhcp_addresses files
#   - Configures DHCP, DNS, and TFTP services
#
# Returns:
#   0 on success
#   1 if required configuration missing
#
# Example usage:
#   create_config_dnsmasq
#
#===============================================================================
create_config_dnsmasq() {
  # Get service paths
  local services_dir
  services_dir=$(hps_get_config cluster_services) || {
    hps_log error "Cannot determine cluster services directory"
    return 1
  }

  # Get active cluster once (if function needs it)
  local cluster
  cluster=$(hps_get_config active_cluster) || {
    hps_log error "No active cluster configured"
    return 1
  }
  
  
  local dnsmasq_conf="${services_dir}/dnsmasq.conf"
  local dns_hosts="${services_dir}/dns_hosts"
  local dhcp_addresses="${services_dir}/dhcp_addresses"
  
  # Get TFTP directory
  local tftp_dir
  tftp_dir=$(hps_get_config system_base) || {
    hps_log error "Cannot determine system base directory"
    return 1
  }
  tftp_dir="${tftp_dir}/../hps-config/tftp"
  
  # Get cluster network configuration from registry
  local dhcp_ip
  dhcp_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null)
  if [[ -z "$dhcp_ip" ]]; then
    hps_log error "No DHCP IP configured in cluster registry (network_dhcp_ip)"
    return 1
  fi
  
  local dhcp_iface
  dhcp_iface=$(cluster_registry "$cluster" get network_dhcp_iface 2>/dev/null)
  dhcp_iface=${dhcp_iface:-eth0}
  
  local network_cidr
  network_cidr=$(cluster_registry "$cluster" get network_cidr 2>/dev/null)
  if [[ -z "$network_cidr" ]]; then
    hps_log error "No network CIDR configured in cluster registry (network_cidr)"
    return 1
  fi
  
  local dhcp_rangesize
  dhcp_rangesize=$(cluster_registry "$cluster" get network_dhcp_rangesize 2>/dev/null)
  dhcp_rangesize=${dhcp_rangesize:-50}
  
  local dns_domain
  dns_domain=$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null)
  dns_domain=${dns_domain:-local}
  
  hps_log info "Configuring dnsmasq on ${dhcp_ip}..."
  
  # Generate dnsmasq configuration
  cat > "${dnsmasq_conf}" <<EOF
# dnsmasq base configuration for PXE/TFTP/DHCP
# ---------------------------
# System config
# ---------------------------
# Bind only to this IP (set dynamically from cluster config)
listen-address=${dhcp_ip}
# Interface to bind to within the container
interface=${dhcp_iface}

# ---------------------------
# DHCP configuration
# ---------------------------
# Enable DHCP
dhcp-range=$(generate_dhcp_range_simple "${network_cidr}" "${dhcp_ip}" "${dhcp_rangesize}")
# Optional: Log DHCP requests
log-dhcp
# DHCP reservations file
dhcp-hostsfile=${dhcp_addresses}
dhcp-authoritative

# ---------------------------
# DNS configuration
# ---------------------------
port=53
domain=${dns_domain}
dhcp-option=option:domain-search,"${dns_domain}"
# Additional host names
addn-hosts=${dns_hosts}
# Do not use /etc/hosts or /etc/resolv.conf
no-hosts
no-resolv
# For debugging
log-queries
# Option 1: Completely disable IPv6 DNS
filter-AAAA
expand-hosts 
local=/${dns_domain}/

# ---------------------------
# TFTP
# ---------------------------
# Enable TFTP
enable-tftp
tftp-root=${tftp_dir}

# ---------------------------
# PXE config
# ---------------------------
# PXE boot filename (BIOS)
dhcp-boot=undionly.kpxe
# Match iPXE clients by option 175
dhcp-match=set:ipxe,175
# For iPXE clients
dhcp-boot=tag:ipxe,http://${dhcp_ip}/cgi-bin/boot_manager.sh?cmd=init
EOF

  # Ensure required files exist
  touch "${dhcp_addresses}" || {
    hps_log error "Failed to create ${dhcp_addresses}"
    return 1
  }
  
  touch "${dns_hosts}" || {
    hps_log error "Failed to create ${dns_hosts}"
    return 1
  }
  
  hps_log info "dnsmasq config generated at: ${dnsmasq_conf}"
  return 0
}
