#!/bin/bash
#===============================================================================
# Node Init Wrapper Functions
# File: /srv/hps-system/lib/node-functions.d/common.d/n_init-wrappers.sh
#
# Wrapper functions for init sequence that need specific parameters or logic.
# These are called by the init sequence to provide a clean interface.
#===============================================================================


#===============================================================================
# n_install_opensvc_packages
# --------------------------
# Install OpenSVC client and server packages.
#
# Behaviour:
#   - Wrapper for n_install_apk_packages_from_ips
#   - Installs opensvc-server and opensvc-client from IPS repository
#   - OS-agnostic wrapper (implementation may vary per OS)
#
# Returns:
#   0 on success
#   Non-zero on failure
#
# Example:
#   n_install_opensvc_packages
#
#===============================================================================
n_install_opensvc_packages() {
  n_remote_log "Installing OpenSVC packages..."
  
  # Detect OS and use appropriate package manager
  if [[ -f /etc/alpine-release ]]; then
    # Alpine Linux - use apk
    n_install_apk_packages_from_ips opensvc-server opensvc-client
  elif [[ -f /etc/rocky-release ]] || [[ -f /etc/redhat-release ]]; then
    # Rocky/RHEL - use rpm/dnf
    # TODO: Implement Rocky package installation
    n_remote_log "Rocky OpenSVC installation not yet implemented"
    return 1
  else
    n_remote_log "ERROR: Unknown OS, cannot install OpenSVC packages"
    return 1
  fi
}
