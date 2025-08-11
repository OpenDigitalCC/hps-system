__guard_source || return
# Define your functions below




configure_dnsmasq () {
source $(get_active_cluster_filename 2>/dev/null)

local DNSMASQ_CONF="${HPS_SERVICE_CONFIG_DIR}/dnsmasq.conf"

if [[ -z "${DHCP_IP}" ]]; then
  echo "[ERROR] No DHCP IP, can't configure dnsmasq"
    exit 0
fi

echo "[*] Configuring dnsmasq on $DHCP_IP..." 

cat > "${DNSMASQ_CONF}" <<EOF

# dnsmasq base configuration for PXE/TFTP/DHCP

# Do not use /etc/hosts or /etc/resolv.conf
no-hosts
no-resolv

# Bind only to this IP (set dynamically from cluster config)
listen-address=${DHCP_IP}

# Interface to bind to within the container
interface=eth0 # Should this be ${DHCP_IFACE}?

# Enable DHCP
dhcp-range=$(generate_dhcp_range_simple "$NETWORK_CIDR" "$DHCP_IP" 20)

# Enable TFTP
enable-tftp
tftp-root=${HPS_TFTP_DIR}

# Optional: Log DHCP requests
log-dhcp

# DNS configuration
domain="${DNS_DOMAIN}"
dhcp-option=option:domain-search,"${DNS_DOMAIN}"
addn-hosts="${HPS_SERVICE_CONFIG_DIR}/dns_hosts"

# PXE-specific options (optional)
#pxe-service=x86PC, "PXE Boot", pxelinux

# PXE boot filename (BIOS)
dhcp-boot=undionly.kpxe   # For BIOS
dhcp-match=set:ipxe,175   # Match iPXE clients by option 175
dhcp-boot=tag:ipxe,http://${DHCP_IP}/cgi-bin/boot_manager.sh?cmd=init  # For iPXE clients

EOF

# TODO: I am sure this isn't needed now, delete
#mkdir -p ${HPS_TFTP_DIR}
#cp /usr/lib/ipxe/undionly.kpxe "${HPS_TFTP_DIR}"
#cp /usr/lib/ipxe/snponly.efi "${HPS_TFTP_DIR}"
#cp /usr/lib/ipxe/ipxe.efi "${HPS_TFTP_DIR}"

touch ${HPS_SERVICE_CONFIG_DIR}/dns_hosts

echo "[OK] dnsmasq config generated at: ${DNSMASQ_CONF}"

}
