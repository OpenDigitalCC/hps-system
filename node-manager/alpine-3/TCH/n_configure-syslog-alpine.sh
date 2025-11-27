#===============================================================================
# n_configure_syslog
# ------------------
# Configure node to send syslog to IPS
#
# Parameters:
#   $1 - IPS hostname/IP (optional, defaults to 'ips')
#
# Returns:
#   0 on success
#   1 on failure
#
# Example:
#   n_configure_syslog
#   n_configure_syslog "10.99.1.1"
#===============================================================================
n_configure_syslog() {
  local ips_host="${1:-10.99.1.1}"

# TODO: This doesn't actually start on boot but it should. it works after manual start.

  # Configure syslog
  echo "SYSLOGD_OPTS=\"-R ${ips_host}:514\"" > /etc/conf.d/syslog
  
  # Ensure it's added to boot
  rc-update add syslog default
  
  rc-service syslog start
  
  # Test
  logger -p local1.info "Syslog configured for $(hostname)"
  
  # Verify
  n_remote_log "Syslog service configured and started"
}




