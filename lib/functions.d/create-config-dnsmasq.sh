# shellcheck shell=bash
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
  
  # Get TFTP directory (populated at pre-start from the system tftp/ tree)
  local tftp_dir
  tftp_dir=$(hps_get_config tftp) || {
    hps_log error "Cannot determine TFTP directory"
    return 1
  }
  
  # Get cluster network configuration from registry
  local dhcp_ip
  dhcp_ip=$(cluster_registry "$cluster" get network_dhcp_ip 2>/dev/null)
  if [[ -z "$dhcp_ip" ]]; then
    hps_log error "No DHCP IP configured in cluster registry (network_dhcp_ip)"
    return 1
  fi
  
  local dhcp_iface
  dhcp_iface=$(cluster_registry "$cluster" get network_dhcp_iface 2>/dev/null)
  if [[ -z "$dhcp_iface" ]]; then
    hps_log error "No DHCP interface configured in cluster registry (network_dhcp_iface)"
    return 1
  fi
  
  local network_cidr
  network_cidr=$(cluster_registry "$cluster" get network_cidr 2>/dev/null)
  if [[ -z "$network_cidr" ]]; then
    hps_log error "No network CIDR configured in cluster registry (network_cidr)"
    return 1
  fi
  
  local dhcp_rangesize
  dhcp_rangesize=$(cluster_registry "$cluster" get network_dhcp_rangesize 2>/dev/null)
  dhcp_rangesize=${dhcp_rangesize:-50}
  
  # Explicit range (set by cluster-bootstrap.sh) wins over the computed one.
  local dhcp_range_start dhcp_range_end dhcp_range
  dhcp_range_start=$(cluster_registry "$cluster" get network_dhcp_range_start 2>/dev/null) || dhcp_range_start=""
  dhcp_range_end=$(cluster_registry "$cluster" get network_dhcp_range_end 2>/dev/null) || dhcp_range_end=""
  if [[ -n "$dhcp_range_start" && -n "$dhcp_range_end" ]]; then
    dhcp_range="${dhcp_range_start},${dhcp_range_end},1h"
  else
    dhcp_range=$(generate_dhcp_range_simple "${network_cidr}" "${dhcp_ip}" "${dhcp_rangesize}")
  fi

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
# Log to syslog (daemon facility); rsyslog files it per service
log-facility=DAEMON
# Bind only to this IP (set dynamically from cluster config)
listen-address=${dhcp_ip}
# Answer on this interface only (the IPS is host-networked)
interface=${dhcp_iface}
bind-interfaces

# ---------------------------
# DHCP configuration
# ---------------------------
# Enable DHCP
dhcp-range=${dhcp_range}
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
# Match iPXE clients by option 175
dhcp-match=set:ipxe,175
# Match UEFI x86-64 clients by architecture (7 = EFI BC, 9 = EFI x86-64)
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
# UEFI clients not yet running iPXE: SNP-only iPXE
dhcp-boot=tag:efi64,tag:!ipxe,snponly.efi
# BIOS clients not yet running iPXE
dhcp-boot=tag:!efi64,tag:!ipxe,undionly.kpxe
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
