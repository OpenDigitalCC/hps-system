#!/bin/bash
#===============================================================================
# 070-system-services.sh
# ----------------------
# Configuration fragment to set system service addresses
#===============================================================================

cli_info "Configure system services" "System Services"

# Get DHCP IP as default for services
dhcp_ip=$(config_get_value "DHCP_IP" "")

if [[ -z "$dhcp_ip" ]]; then
  hps_log "error" "DHCP IP not found in configuration"
  return 1
fi

# Get current values with DHCP IP as fallback default
current_syslog=$(config_get_value "SYSLOG_SERVER" "$dhcp_ip")
current_dns=$(config_get_value "NAME_SERVER" "$dhcp_ip")
current_ntp=$(config_get_value "TIME_SERVER" "$dhcp_ip")

cli_note "The DHCP server IP ($dhcp_ip) can provide syslog, DNS, and NTP services"

# Show current configuration
echo "Current configuration:"
echo "  - Syslog server: $current_syslog"
echo "  - DNS server:    $current_dns"
echo "  - NTP server:    $current_ntp"
echo

# Ask if keeping current configuration
if [[ $(cli_prompt_yesno "Keep current system service configuration?" "y") == "y" ]]; then
  # Keep current values
  CLUSTER_CONFIG_PENDING+=("SYSLOG_SERVER:$current_syslog")
  CLUSTER_CONFIG_PENDING+=("NAME_SERVER:$current_dns")
  CLUSTER_CONFIG_PENDING+=("TIME_SERVER:$current_ntp")
else
  # Customize each service
  cli_info "Customize system service addresses"
  
  # IP address validation regex
  ip_regex="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"
  
  # Syslog server
  syslog_server=$(cli_prompt "Syslog server IP address" "$current_syslog" "$ip_regex" \
    "Invalid IP address format")
  CLUSTER_CONFIG_PENDING+=("SYSLOG_SERVER:$syslog_server")
  
  # DNS server
  dns_server=$(cli_prompt "DNS server IP address" "$current_dns" "$ip_regex" \
    "Invalid IP address format")
  CLUSTER_CONFIG_PENDING+=("NAME_SERVER:$dns_server")
  
  # NTP server
  cli_note "NTP server can be an IP address or hostname (e.g., pool.ntp.org)"
  ntp_server=$(cli_prompt "NTP server address" "$current_ntp" "" "")
  if [[ -n "$ntp_server" ]]; then
    # Validate if it's an IP
    if [[ "$ntp_server" =~ ^[0-9.]+$ ]] && ! [[ "$ntp_server" =~ $ip_regex ]]; then
      hps_log "error" "Invalid IP address format"
      return 1
    fi
  fi
  CLUSTER_CONFIG_PENDING+=("TIME_SERVER:$ntp_server")
  
  cli_info "System services configured:"
  echo "  - Syslog server: $syslog_server"
  echo "  - DNS server:    $dns_server"
  echo "  - NTP server:    $ntp_server"
fi
