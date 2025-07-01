__guard_source || return
# Define your functions below

generate_ks() {
#TODO: Make this common for kickstart and preeseed
  local macid="$1"
  local type="$2"
  hps_log info "[$macid] ${FUNCNAME[0]} called from ${FUNCNAME[1]}"
  hps_log info "[$macid]" "Requesting kickstart for $macid $type"
  cgi_header_plain

#  CLNAME=$(cluster_config get CLUSTER_NAME)
#  host_config "$macid" || {
#    hps_log debug "[x] Failed to load host config for $macid"
#    return 1
#  }
#  ks_type_${type}

# Make variables available for the installer script

HOST_IP=$(host_config "$macid" get IP)
HOST_NETMASK=$(host_config "$macid" get NETMASK)
HOST_NAME=$(host_config "$macid" get HOSTNAME)
HOST_GATEWAY="$(cluster_config get DHCP_IP)"
HOST_DNS="$(cluster_config get DHCP_IP)"
HOST_TEMPLATE_DIR="${LIB_DIR}/host-install-templates"
HOST_INSTALL_SCRIPT="${HOST_TEMPLATE_DIR}/${INSTALLER_TYPE}-${type}.script"
INSTALLER_TYPE=kickstart

host_config "$macid" set STATE "INSTALLING from ${HOST_INSTALL_SCRIPT}"

cat "${HOST_INSTALL_SCRIPT}"

}






