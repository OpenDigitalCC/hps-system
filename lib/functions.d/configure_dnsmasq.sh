
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

# Interface to bind to
interface=eth0

# Enable DHCP
dhcp-range=$(generate_dhcp_range_simple "$NETWORK_CIDR" "$DHCP_IP" 20)


# Enable TFTP
enable-tftp
tftp-root=${HPS_TFTP}

# Optional: Log DHCP requests
log-dhcp

# Optional: Don't forward DNS (acts as DHCP/TFTP only)
#port=0

# PXE-specific options (optional)
#pxe-service=x86PC, "PXE Boot", pxelinux

# PXE boot filename (BIOS)
dhcp-boot=undionly.kpxe   # For BIOS
dhcp-match=set:ipxe,175   # Match iPXE clients by option 175
dhcp-boot=tag:ipxe,http://${DHCP_IP}/menu/boot.ipxe  # For iPXE clients

EOF

mkdir -p ${HPS_TFTP}

cp /usr/lib/ipxe/undionly.kpxe "${HPS_TFTP}"
cp /usr/lib/ipxe/snponly.efi "${HPS_TFTP}"
cp /usr/lib/ipxe/ipxe.efi "${HPS_TFTP}"

echo "[OK] dnsmasq config generated at: ${DNSMASQ_CONF}"

}
