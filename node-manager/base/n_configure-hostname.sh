#===============================================================================
# n_fqdn / n_shortname / n_set_kernel_hostname
# --------------------------------------------
# The one hostname rule (docs/NAMING.md): a node's identity is the FQDN
# <label>.<cluster dns domain>; the label is the registry HOSTNAME. Nothing
# else joins or splits names.
#
#   n_fqdn <name> [domain]      print <first label of name, lower case>.<domain>
#                               (the label alone when the domain is empty);
#                               fails when the result is longer than 63
#                               characters (the om3 node-name cap)
#   n_shortname <name>          print the first label, lower case
#   n_set_kernel_hostname <fqdn> make it the static and the transient kernel
#                               hostname (hostnamectl); when the static name
#                               cannot be written, the transient name only,
#                               then hostname(1)
#===============================================================================
n_shortname() {
    local label="${1%%.*}"
    printf '%s\n' "${label,,}"
}

n_fqdn() {
    local label domain
    label=$(n_shortname "${1:-}")
    domain="${2:-}"
    domain="${domain//\"/}"
    domain="${domain,,}"
    if [[ -z "$label" ]]; then
        echo "n_fqdn: no hostname given" >&2
        return 1
    fi
    if [[ -n "$domain" && ! "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
        echo "n_fqdn: '${domain}' is not a usable DNS domain" >&2
        return 1
    fi
    local name="$label"
    if [[ -n "$domain" ]]; then
        name="${label}.${domain}"
    fi
    if [[ ${#name} -gt 63 ]]; then
        echo "n_fqdn: ${name} is ${#name} characters; the limit is 63 (om3 node names). Use a shorter DNS domain." >&2
        return 1
    fi
    printf '%s\n' "$name"
}

n_set_kernel_hostname() {
    local name="$1"
    # The NixOS path only (n_set_hostname_and_hosts): /etc/hostname is
    # store-managed (a link into the read-only store), so a static name always
    # fails and systemd-hostnamed logs it. The transient name only (lab
    # 2026-11-11).
    if command -v hostnamectl >/dev/null 2>&1; then
        if hostnamectl set-hostname --transient "${name}"; then
            return 0
        fi
    fi
    hostname "${name}"
}

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
#   - Gets domain from: n_remote_cluster_variable network_dns_domain
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
    local root="${HPS_OS_ROOT:-}"
    
    # Get configuration values
    hostname=$(n_remote_host_variable HOSTNAME) || {
        echo "Error: failed to get hostname from n_remote_host_variable" >&2
        return 1
    }
    
    domain=$(n_remote_cluster_variable network_dns_domain) || {
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
    
    # Construct FQDN (the one rule; refuses an FQDN over 63 characters)
    fqdn=$(n_fqdn "${hostname}" "${domain}") || return 1
    hostname=$(n_shortname "${hostname}")
    
    echo "Setting hostname: ${hostname} (FQDN: ${fqdn}, IP: ${ip})"
    n_remote_log "Setting hostname: ${hostname} (FQDN: ${fqdn}, IP: ${ip})"

    # NixOS: /etc/hostname and /etc/hosts are store-managed. Set the kernel
    # hostname for this boot only and leave the files alone.
    if n_os_is_nixos; then
        n_set_kernel_hostname "${fqdn}" || {
            echo "Error: setting the kernel hostname failed" >&2
            return 2
        }
        n_remote_log "nixos: kernel hostname set to the FQDN: ${fqdn}"
        n_nixos_skip "/etc/hostname and /etc/hosts writes"
        return 0
    fi
    
    # Set hostname using appropriate method: the FQDN is the kernel hostname
    if command -v hostnamectl >/dev/null 2>&1; then
        # systemd-based systems
        hostnamectl set-hostname "${fqdn}" 2>/dev/null || {
            echo "Error: hostnamectl failed" >&2
            return 2
        }
        n_remote_log "Hostname set via hostnamectl: ${fqdn}"
    else
        # Non-systemd systems
        hostname "${fqdn}" 2>/dev/null || {
            echo "Error: hostname command failed" >&2
            return 2
        }
        n_remote_log "Hostname set via hostname command: ${fqdn}"
        
        # Persist hostname
        echo "${fqdn}" > "${root}/etc/hostname" || {
            echo "Error: failed to write /etc/hostname" >&2
            return 2
        }
        n_remote_log "Created /etc/hostname with: ${hostname}"
        
        # Alpine-specific
        if [[ -f "${root}/etc/conf.d/hostname" ]]; then
            echo "hostname=\"${fqdn}\"" > "${root}/etc/conf.d/hostname"
            n_remote_log "Updated Alpine /etc/conf.d/hostname"
        fi
        
        # RHEL/Rocky-specific
        if [[ -f "${root}/etc/sysconfig/network" ]]; then
            if grep -q "^HOSTNAME=" "${root}/etc/sysconfig/network" 2>/dev/null; then
                sed -i "s/^HOSTNAME=.*/HOSTNAME=${fqdn}/" "${root}/etc/sysconfig/network"
            else
                echo "HOSTNAME=${fqdn}" >> "${root}/etc/sysconfig/network"
            fi
            n_remote_log "Updated RHEL/Rocky /etc/sysconfig/network"
        fi
    fi
    
    # Create /etc/hosts
    cat > "${root}/etc/hosts" <<EOF
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
    
    n_remote_log "Completed successfully"
    return 0
}
