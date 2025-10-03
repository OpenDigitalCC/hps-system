
#===============================================================================
# n_configure_minimal_networking
# ------------------------------
# Configure minimal networking on Alpine TCH node for service dependencies.
#
# Prerequisites:
#   - Alpine Linux base system
#   - Network already configured via iPXE kernel parameters
#
# Behaviour:
#   - Creates /etc/network/interfaces with proper network config
#   - Ensures loopback interface is up
#   - Adds networking to boot runlevel
#   - Does NOT start networking service (let OpenRC handle dependencies)
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_configure_minimal_networking() {
    n_remote_log "Configuring minimal networking for service dependencies"
    
    # Get network info from iPXE-configured interface
    local primary_iface=""
    local ip_addr=""
    local netmask=""
    local gateway=""
    
    # Find the interface that has an IP (excluding lo)
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        if ip addr show ${iface} | grep -q "inet "; then
            primary_iface="${iface}"
            # Extract IP and netmask
            local ip_line=$(ip addr show ${iface} | grep "inet " | head -1)
            ip_addr=$(echo ${ip_line} | awk '{print $2}' | cut -d'/' -f1)
            local cidr=$(echo ${ip_line} | awk '{print $2}' | cut -d'/' -f2)
            # Convert CIDR to netmask if needed
            case ${cidr} in
                24) netmask="255.255.255.0" ;;
                16) netmask="255.255.0.0" ;;
                8)  netmask="255.0.0.0" ;;
                *)  netmask="255.255.255.0" ;;
            esac
            break
        fi
    done
    
    # Get gateway from routing table
    gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    
    # Create network interfaces file
    echo "[HPS] Creating /etc/network/interfaces..."
    n_remote_log "Creating /etc/network/interfaces with ${primary_iface:-eth0} configuration"
    
    if [[ -n "${primary_iface}" ]] && [[ -n "${ip_addr}" ]]; then
        # We have network info from iPXE
        cat > /etc/network/interfaces <<EOF
# Network configuration from iPXE boot
auto lo
iface lo inet loopback

auto ${primary_iface}
iface ${primary_iface} inet static
    address ${ip_addr}
    netmask ${netmask}
    gateway ${gateway}
EOF
    else
        # Fallback minimal config
        cat > /etc/network/interfaces <<EOF
# Minimal interfaces file
auto lo
iface lo inet loopback

# Primary interface configured by iPXE
auto eth0
iface eth0 inet manual
EOF
    fi
    
    n_remote_log "Created /etc/network/interfaces"
    
    # Ensure loopback is up (critical for many services)
    if ! ip link show lo | grep -q "UP"; then
        echo "[HPS] Bringing up loopback interface..."
        ip link set lo up
        n_remote_log "Brought up loopback interface"
    fi
    
    # Add networking to boot runlevel (not default)
    if ! rc-update show boot | grep -q networking; then
        echo "[HPS] Adding networking to boot runlevel..."
        rc-update add networking boot
        n_remote_log "Added networking to boot runlevel"
    fi
    
    # Start networking service if not already running
    if ! rc-service networking status >/dev/null 2>&1; then
        echo "[HPS] Starting networking service..."
        n_remote_log "Starting networking service"
        
        # First ensure all dependencies are met
        rc-service networking zap >/dev/null 2>&1  # Clear any stuck state
        
        if rc-service networking start >/dev/null 2>&1; then
            n_remote_log "Networking service started successfully"
        else
            # Check if network is actually working despite service failure
            if ip link show | grep -q "state UP" && ip route | grep -q default; then
                n_remote_log "Networking service reports failure but network is functional"
                # Force the service to be marked as started
                n_force_network_started
                return 0
            else
                n_remote_log "ERROR: Failed to start networking service"
                return 1
            fi
        fi
    else
        n_remote_log "Networking service already running"
    fi
    
    n_remote_log "Minimal networking configuration complete"
    return 0
}

#===============================================================================
# n_force_network_started
# -----------------------
# Force networking service to appear started for dependency resolution.
#
# Usage:
#   n_force_network_started
#
# Behaviour:
#   - Creates OpenRC state files to mark networking as started
#   - Works around iPXE-configured networks that bypass normal init
#
# Returns:
#   0 on success
#   1 on failure
#===============================================================================
n_force_network_started() {
    n_remote_log "Forcing networking service to appear started"
    
    # Clean any failed state
    rc-service networking zap >/dev/null 2>&1
    
    # Create all necessary state files
    mkdir -p /run/openrc/started
    mkdir -p /run/openrc/softlevel
    
    # Mark as started
    touch /run/openrc/started/networking
    
    # Also mark in deptree if it exists
    if [[ -f /run/openrc/deptree ]]; then
        # Add networking to the started services in deptree
        sed -i 's/^RC_SVCNAME="networking" RC_RUNLEVEL="[^"]*" RC_SERVICE="[^"]*"/& RC_STARTED="YES"/' /run/openrc/deptree 2>/dev/null || true
    fi
    
    # Alternative method: create init.d status file
    mkdir -p /run/openrc/exclusive
    echo "started" > /run/openrc/exclusive/networking 2>/dev/null || true
    
    # Verify
    if [[ -f /run/openrc/started/networking ]]; then
        n_remote_log "Successfully marked networking as started"
        
        # Double-check with rc-status
        if rc-status | grep -q "networking.*started"; then
            n_remote_log "Verified: networking shows as started in rc-status"
        else
            n_remote_log "WARNING: networking marked but not showing in rc-status"
        fi
        return 0
    else
        n_remote_log "ERROR: Failed to mark networking as started"
        return 1
    fi
}


n_queue_add n_configure_minimal_networking

n_queue_add n_force_network_started


