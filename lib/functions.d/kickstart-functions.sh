__guard_source || return
# Define your functions below

generate_ks() {
#TODO: Make this common for kickstart and preeseed
  export  macid="$1"
  export  HOST_TYPE="$2"
  hps_log info "[$macid] ${FUNCNAME[0]} called from ${FUNCNAME[1]}"
  hps_log info "[$macid]" "Requesting kickstart for $macid ${HOST_TYPE}"
  cgi_header_plain

#  CLNAME=$(cluster_config get CLUSTER_NAME)
#  host_config "$macid" || {
#    hps_log debug "[x] Failed to load host config for $macid"
#    return 1
#  }
#  ks_type_${HOST_TYPE}

# Make variables available for the installer script

  export HOST_IP=$(host_config "$macid" get IP)
  export HOST_NETMASK=$(host_config "$macid" get NETMASK)
  export HOST_NAME=$(host_config "$macid" get HOSTNAME)
  export HOST_GATEWAY="$(cluster_config get DHCP_IP)"
  export HOST_DNS="$(cluster_config get DHCP_IP)"
  export HOST_TEMPLATE_DIR="${LIB_DIR}/host-install-templates"
  export INSTALLER_TYPE=kickstart
  export HOST_INSTALL_SCRIPT="${HOST_TEMPLATE_DIR}/${INSTALLER_TYPE}-${HOST_TYPE}.script"
  export HOST_INSTALL_FUNC="${INSTALLER_TYPE}-${HOST_TYPE}"

  host_config "$macid" set STATE "INSTALLING"
  hps_log info "[$macid]" "Script ${HOST_INSTALL_SCRIPT} offered"
  cat "${HOST_INSTALL_SCRIPT}" | script_render_template
}

script_render_template() {
# remap all var placeholders @...@ with the values from ${...}
  local var value
  local awk_args=()

  for var in $(compgen -v); do
    value="${!var-}"
    awk_args+=("-v" "$var=$value")
  done

  awk "${awk_args[@]}" '
    {
      line = $0
      while (match(line, /@[^@]+@/)) {
        var = substr(line, RSTART + 1, RLENGTH - 2)
        val = (var in ENVIRON) ? ENVIRON[var] : (var in awk_vars) ? awk_vars[var] : ""
        line = substr(line, 1, RSTART - 1) val substr(line, RSTART + RLENGTH)
      }
      print line
    }'
}

remote_function_lib () {
# Functions to be injected in to pre and post sections
# consider moving this to it's own file somewhere
cat <<EOF

remote_log() {
  local message="$1"
  local encoded
  local macid="${macid}"
  local gateway="${HOST_GATEWAY}"

  # URL-encode the message
  local c
  encoded=""
  for (( i=0; i<${#message}; i++ )); do
    c="${message:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) printf -v encoded '%s%%%02X' "$encoded" "'$c" ;;
    esac
  done

  # Send log message
  curl -s -X POST "http://@HOST_GATEWAY@/cgi-bin/boot_manager.sh?mac=@macid@&cmd=log_message&message=${encoded}"
}


EOF

}






