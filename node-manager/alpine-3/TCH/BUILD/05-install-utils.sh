#===============================================================================
# n_install_base_services
# -----------------------
# Install and start basic services from a package list.
#
# Usage:
#   n_install_base_services
#
# Behaviour:
#   - Installs packages from PACKAGES list
#   - Starts services from SERVICES list
#   - Alpine-specific: uses apk and rc-service
#
# Returns:
#   0 on success
#   1 on package installation failure
#   2 on service start failure
#===============================================================================
n_install_base_services() {
    # Package list - add/remove as needed
    local PACKAGES="rsyslog openssh-server"
    
    # Service names - add/remove as needed
    local SERVICES="rsyslog sshd"
    
    n_remote_log "Starting base services installation"
    
    # Update package index
    apk update || {
        n_remote_log "ERROR: apk update failed"
        return 1
    }
    
    # Install packages
    n_remote_log "Installing packages: ${PACKAGES}"
    apk add ${PACKAGES} || {
        n_remote_log "ERROR: Failed to install packages"
        return 1
    }
    n_remote_log "Packages installed successfully"
    
    # Start and enable services
    for service in ${SERVICES}; do
        n_remote_log "Starting service: ${service}"
        
        # Enable service at boot
        rc-update add ${service} default 2>/dev/null || {
            n_remote_log "WARNING: Failed to enable ${service} at boot"
        }
        
        # Start service
        rc-service ${service} start || {
            n_remote_log "ERROR: Failed to start ${service}"
            return 2
        }
        
        n_remote_log "Service ${service} started"
    done
    
    n_remote_log "Base services installation completed"
    return 0
}
