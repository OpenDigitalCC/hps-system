# /srv/hps/functions.d/common.sh

## NODE Functions for any O/S


#===============================================================================
# n_node_information
# ------------------
# Display concise node information that fits on a standard 80x24 terminal.
#
# Usage:
#   n_node_information
#
# Behaviour:
#   - Loads host configuration variables
#   - Shows essential node information
#   - Checks console login status
#   - Fits output to standard terminal size
#
# Returns:
#   0 on success
#   1 on failure to load configuration
#===============================================================================
n_node_information() {
  # Load host configuration
  if ! n_load_remote_host_config 2>/dev/null; then
    echo "Error: Unable to load host configuration"
    return 1
  fi
  
  # Get essential info
  local provisioning_node=$(n_get_provisioning_node 2>/dev/null || echo "unknown")
  local dns_domain=$(n_remote_cluster_variable DNS_DOMAIN 2>/dev/null | tr -d '"' || echo "unknown")
  local mac_address=$(ip link show 2>/dev/null | awk '/ether/ {print $2; exit}' || echo "unknown")
  local uptime_display="unknown"
  if [[ -f /proc/uptime ]]; then
    local uptime_seconds=$(cut -d. -f1 /proc/uptime)
    uptime_display=$(printf '%dd %dh %dm' $((uptime_seconds/86400)) $((uptime_seconds%86400/3600)) $((uptime_seconds%3600/60)))
  fi
  
  # Check console status
  local console_status="enabled"
  if [[ -f /sbin/nologin-console ]] && grep -q "nologin-console" /etc/inittab 2>/dev/null; then
    console_status="disabled"
  fi
  
  # Count active services
  local active_count=0
  for svc in networking sshd rsyslog dbus libvirtd; do
    if rc-service ${svc} status >/dev/null 2>&1; then
      ((active_count++))
    fi
  done
  
  # Clear screen only if running interactively and not in boot
  if [[ -t 1 ]] && [[ "$(cat /proc/uptime | cut -d. -f1)" -gt 60 ]]; then
    clear
  fi
  
  # Display compact info (24 lines total)
  echo "================================================================================"
  echo "           HPS NODE: ${HOSTNAME:-unknown}"
  echo "================================================================================"
  echo "Type:     ${TYPE:-unknown} / ${HOST_PROFILE:-unknown}      State: ${STATE:-unknown}"
  echo "IP:       ${IP:-unknown}/${NETMASK:-unknown}"
  echo "Gateway:      ${provisioning_node}    MAC: ${mac_address}"
  echo "Domain:       ${dns_domain}"
  echo "--------------------------------------------------------------------------------"
  echo "Uptime:       ${uptime_display}    Services: ${active_count}/5 active"
  echo "Virt:     ${virtualization_status:-none} (${virtualization_type:-n/a})"
  echo "Console:      ${console_status}"
  echo "Updated:      ${UPDATED:-unknown}"
  echo "================================================================================"
  
  # Add appropriate footer based on console status
  if [[ "${console_status}" == "disabled" ]]; then
    echo ""
    echo "Console access disabled. Connect via SSH to ${IP:-this node}"
    echo ""
  fi
  
  return 0
}




