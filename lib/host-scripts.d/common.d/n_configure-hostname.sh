#===============================================================================
# n_set_hostname_and_hosts
# ------------------------
# Set system hostname and create basic hosts file entry across distributions.
#
# Usage:
#   n_set_hostname_and_hosts
#
# Prerequisites:
#   - Functions n_remote_host_variable and n_remote_cluster_variable must be available
#
# Behaviour:
#   - Gets hostname from: n_remote_host_variable HOSTNAME
#   - Gets domain from: n_remote_cluster_variable DNS_DOMAIN
#   - Gets IP from: n_remote_host_variable IP
#   - Sets hostname using hostnamectl if available (systemd systems)
#   - Falls back to hostname command and distribution-specific files
#   - Creates /etc/hosts with loopback and hostname entries
#
# Returns:
#   0 on success
#   1 on missing configuration values
#   2 on hostname setting failure
#   3 on hosts file creation failure
#===============================================================================
n_set_hostname_and_hosts() {
    local hostname
    local domain
    local ip
    local fqdn
    
    # Get configuration values
    hostname=$(n_remote_host_variable HOSTNAME) || {
        echo "Error: failed to get hostname from n_remote_host_variable" >&2
        return 1
    }
    
    domain=$(n_remote_cluster_variable DNS_DOMAIN) || {
        echo "Warning: failed to get domain, proceeding without domain" >&2
        domain=""
    }
    
    # Remove quotes if present
    domain=${domain//\"/}
    
    ip=$(n_remote_host_variable IP) || {
        echo "Error: failed to get IP from n_remote_host_variable" >&2
        return 1
    }
    
    # Validate required values
    if [[ -z "${hostname}" ]]; then
        echo "Error: hostname is empty" >&2
        return 1
    fi
    
    if [[ -z "${ip}" ]]; then
        echo "Error: IP is empty" >&2
        return 1
    fi
    
    # Construct FQDN
    if [[ -n "${domain}" ]]; then
        fqdn="${hostname}.${domain}"
    else
        fqdn="${hostname}"
    fi
    
    echo "Setting hostname: ${hostname} (FQDN: ${fqdn}, IP: ${ip})"
    n_remote_log "Setting hostname: ${hostname} (FQDN: ${fqdn}, IP: ${ip})"
    
    # Set hostname using appropriate method
    if command -v hostnamectl >/dev/null 2>&1; then
        # systemd-based systems
        hostnamectl set-hostname "${hostname}" 2>/dev/null || {
            echo "Error: hostnamectl failed" >&2
            return 2
        }
        n_remote_log "Hostname set via hostnamectl: ${hostname}"
    else
        # Non-systemd systems
        hostname "${hostname}" 2>/dev/null || {
            echo "Error: hostname command failed" >&2
            return 2
        }
        n_remote_log "Hostname set via hostname command: ${hostname}"
        
        # Persist hostname
        echo "${hostname}" > /etc/hostname || {
            echo "Error: failed to write /etc/hostname" >&2
            return 2
        }
        n_remote_log "Created /etc/hostname with: ${hostname}"
        
        # Alpine-specific
        if [[ -f /etc/conf.d/hostname ]]; then
            echo "hostname=\"${hostname}\"" > /etc/conf.d/hostname
            n_remote_log "Updated Alpine /etc/conf.d/hostname"
        fi
        
        # RHEL/Rocky-specific
        if [[ -f /etc/sysconfig/network ]]; then
            if grep -q "^HOSTNAME=" /etc/sysconfig/network 2>/dev/null; then
                sed -i "s/^HOSTNAME=.*/HOSTNAME=${hostname}/" /etc/sysconfig/network
            else
                echo "HOSTNAME=${hostname}" >> /etc/sysconfig/network
            fi
            n_remote_log "Updated RHEL/Rocky /etc/sysconfig/network"
        fi
    fi
    
    # Create /etc/hosts
    cat > /etc/hosts <<EOF
# IPv4
127.0.0.1   localhost localhost.localdomain
${ip}       ${fqdn} ${hostname}

# IPv6
::1         localhost localhost.localdomain ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
    
    if [[ $? -ne 0 ]]; then
        echo "Error: failed to create /etc/hosts" >&2
        return 3
    fi
    
    n_remote_log "Created /etc/hosts with hostname: ${hostname}, FQDN: ${fqdn}, IP: ${ip}"
    
    echo "Hostname and hosts file configured successfully"
    n_remote_log "n_set_hostname_and_hosts completed successfully"
    return 0
}
