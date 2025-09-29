__guard_source || return
# Define your functions below


create_config_dnsmasq () {
source $(get_active_cluster_filename 2>/dev/null)

local DNSMASQ_CONF="${HPS_SERVICE_CONFIG_DIR}/dnsmasq.conf"

if [[ -z "${DHCP_IP}" ]]; then
  echo "[ERROR] No DHCP IP, can't configure dnsmasq"
    exit 0
fi

hps_log info "Configuring dnsmasq on $DHCP_IP..." 

cat > "${DNSMASQ_CONF}" <<EOF

# dnsmasq base configuration for PXE/TFTP/DHCP

# ---------------------------
# System config
# ---------------------------

# Bind only to this IP (set dynamically from cluster config)
listen-address=${DHCP_IP}

# Interface to bind to within the container
#interface=eth0 # Should this be ${DHCP_IFACE}?
interface="${DHCP_IFACE}"

# ---------------------------
# DHCP configuration
# ---------------------------


# Enable DHCP
dhcp-range=$(generate_dhcp_range_simple "$NETWORK_CIDR" "$DHCP_IP" 20)

# Optional: Log DHCP requests
log-dhcp

# ---------------------------
# DNS configuration
# ---------------------------

port=53
domain="${DNS_DOMAIN}"
dhcp-option=option:domain-search,"${DNS_DOMAIN}"
#addn-hosts="${HPS_SERVICE_CONFIG_DIR}/dns_hosts"
# DHCP reservations file
dhcp-hostsfile="${HPS_SERVICE_CONFIG_DIR}/dns_hosts"
dhcp-authoritative
# Do not use /etc/hosts or /etc/resolv.conf
no-hosts
no-resolv

# ---------------------------
# TFTP
# ---------------------------

# Enable TFTP
enable-tftp
tftp-root=${HPS_TFTP_DIR}

# ---------------------------
# PXE config
# ---------------------------

# PXE-specific options (optional)
#pxe-service=x86PC, "PXE Boot", pxelinux

# PXE boot filename (BIOS)
dhcp-boot=undionly.kpxe   # For BIOS
dhcp-match=set:ipxe,175   # Match iPXE clients by option 175
dhcp-boot=tag:ipxe,http://${DHCP_IP}/cgi-bin/boot_manager.sh?cmd=init  # For iPXE clients

EOF

  touch ${HPS_SERVICE_CONFIG_DIR}/dns_hosts

  hps_log info "[OK] dnsmasq config generated at: ${DNSMASQ_CONF}"

}
