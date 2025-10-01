__guard_source || return
# Define your functions below


create_config_dnsmasq () {

local DNSMASQ_CONF="${CLUSTER_SERVICES_DIR}/dnsmasq.conf"
# these are cluster specific so should be in cluster/services
local DNS_HOSTS="${CLUSTER_SERVICES_DIR}/dns_hosts"
local DHCP_ADDRESSES="${CLUSTER_SERVICES_DIR}/dhcp_addresses"

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
interface="${DHCP_IFACE}"

# ---------------------------
# DHCP configuration
# ---------------------------

# Enable DHCP
dhcp-range=$(generate_dhcp_range_simple "$NETWORK_CIDR" "$DHCP_IP" "$DHCP_RANGESIZE")

# Optional: Log DHCP requests
log-dhcp
# DHCP reservations file
dhcp-hostsfile="${DHCP_ADDRESSES}"
dhcp-authoritative

# ---------------------------
# DNS configuration
# ---------------------------

port=53
domain="${DNS_DOMAIN}"
dhcp-option=option:domain-search,"${DNS_DOMAIN}"
# Additional host names
addn-hosts="${DNS_HOSTS}"
# Do not use /etc/hosts or /etc/resolv.conf
no-hosts
no-resolv
# for debugging
log-queries
# Option 1: Completely disable IPv6 DNS
filter-AAAA
expand-hosts 
local=/${DNS_DOMAIN}/


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

  # ensure these files exist
  touch ${DHCP_ADDRESSES}
  touch ${DNS_HOSTS}

  hps_log info "[OK] dnsmasq config generated at: ${DNSMASQ_CONF}"
  
}
