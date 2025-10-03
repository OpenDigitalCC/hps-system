
#===============================================================================
# n_install_kvm
# -------------
# Install KVM virtualization stack on Alpine TCH node.
#
# Prerequisites:
#   - Alpine Linux base system
#   - Node functions loaded (n_remote_log, n_remote_host_variable)
#
# Behaviour:
#   - Installs qemu-system-x86_64, qemu-img, libvirt, libvirt-daemon
#   - Ensures networking service appears started for libvirtd dependency
#   - Enables libvirtd service at boot
#   - Starts libvirtd service
#   - Logs progress to IPS
#   - Sets host variable for virtualization status
#
# Returns:
#   0 on success
#   1 if package installation fails
#   2 if libvirtd fails to start
#===============================================================================
n_install_kvm() {
    echo "[HPS] Installing virtualization packages..."
    n_remote_log "Starting virtualization installation on TCH node"
    
    # Install virtualization packages
    n_remote_log "Installing virtualization packages: qemu-system-x86_64 qemu-img libvirt libvirt-daemon dbus"
    if ! apk add --no-cache \
        qemu-system-x86_64 \
        qemu-img \
        libvirt \
        libvirt-daemon \
        dbus \
        libvirt-client; then
        echo "[HPS] ERROR: Failed to install virtualization packages"
        n_remote_log "ERROR: Failed to install virtualization packages"
        n_remote_host_variable "virtualization_status" "install_failed"
        return 1
    fi
    
    # Start dbus first (libvirtd dependency)
    n_remote_log "Starting dbus service"
    rc-update add dbus default
    if ! rc-service dbus start; then
        n_remote_log "WARNING: Failed to start dbus, continuing anyway"
    fi
    
    # Enable libvirtd at boot
    rc-update add libvirtd default
    n_remote_log "Enabled libvirtd service at boot"
    
    # Ensure networking service appears started for libvirtd dependency
    if ! rc-service networking status >/dev/null 2>&1; then
        echo "[HPS] Network not marked as started, checking functionality..."
        n_remote_log "Checking network functionality for libvirtd dependency"
        
        # Check if network is actually functional (iPXE configured)
        if ip route | grep -q default && ip link show | grep -q "state UP"; then
            echo "[HPS] Network is functional, forcing networking service as started"
            n_force_network_started
        else
            echo "[HPS] WARNING: Network may not be fully functional"
            n_remote_log "WARNING: Network functionality check failed"
        fi
    fi
    
    # Check if we're in boot sequence
    local in_boot=0
    if [[ "$(cat /proc/uptime | cut -d. -f1)" -lt 60 ]] || [[ ! -f /run/openrc/softlevel ]]; then
        in_boot=1
        n_remote_log "Detected boot sequence - will defer service startup"
    fi
    
    # Start libvirtd service
    n_remote_log "Starting libvirtd service"
    if ! rc-service libvirtd start; then
        if [[ ${in_boot} -eq 1 ]]; then
            echo "[HPS] Deferring libvirtd start until after boot"
            n_remote_log "Deferring libvirtd start until after boot"
            n_defer_service_start
            n_remote_host_variable "virtualization_status" "pending_boot"
        else
            echo "[HPS] ERROR: Failed to start libvirtd"
            n_remote_log "ERROR: Failed to start libvirtd"
            n_remote_host_variable "virtualization_status" "start_failed"
            return 2
        fi
    else
        # Record successful installation
        n_remote_host_variable "virtualization_status" "active"
    fi
    n_remote_host_variable "virtualization_type" "kvm"
    
    echo "[HPS] Virtualization installation complete"
    n_remote_log "Virtualization installation completed successfully"
    return 0
}




#===============================================================================
# n_force_start_services
# ----------------------
# Force start dbus and libvirtd by bypassing init checks.
#
# Usage:
#   n_force_start_services
#
# Behaviour:
#   - Starts dbus daemon directly
#   - Starts libvirtd daemon directly
#   - Creates pidfiles and marks services as started
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_force_start_services() {
    n_remote_log "Force starting services by bypassing init"
    
    # Force start dbus
    if ! pgrep dbus-daemon >/dev/null 2>&1; then
        n_remote_log "Starting dbus-daemon directly"
        
        # Create dbus directories
        mkdir -p /var/run/dbus
        mkdir -p /var/lib/dbus
        
        # Generate machine-id if missing
        if [[ ! -f /var/lib/dbus/machine-id ]]; then
            dbus-uuidgen > /var/lib/dbus/machine-id
        fi
        
        # Start dbus-daemon
        /usr/bin/dbus-daemon --system --fork --print-pid
        
        # Mark as started for OpenRC
        mkdir -p /run/openrc/started
        touch /run/openrc/started/dbus
        
        n_remote_log "dbus-daemon started"
    else
        n_remote_log "dbus-daemon already running"
    fi
    
    # Give dbus a moment to start
    sleep 1
    
    # Force start libvirtd
    if ! pgrep libvirtd >/dev/null 2>&1; then
        n_remote_log "Starting libvirtd directly"
        
        # Create required directories
        mkdir -p /var/run/libvirt
        mkdir -p /var/log/libvirt
        mkdir -p /var/lib/libvirt
        
        # Start libvirtd in daemon mode
        /usr/sbin/libvirtd --daemon --pid-file=/var/run/libvirtd.pid
        
        # Mark as started for OpenRC
        touch /run/openrc/started/libvirtd
        
        # Wait for libvirtd to initialize
        sleep 2
        
        # Verify it's running
        if pgrep libvirtd >/dev/null 2>&1; then
            n_remote_log "libvirtd started successfully"
        else
            n_remote_log "ERROR: libvirtd failed to start"
            return 1
        fi
    else
        n_remote_log "libvirtd already running"
    fi
    
    return 0
}


n_queue_add n_install_kvm


n_queue_add n_force_start_services


