__guard_source || return
# Define your functions below

ipxe_header () {

# Send pxe header so we don't get a boot failure
cgi_header_plain

# Set some variables to be used in IPXE scripts
CGI_URL="http://\${next-server}/cgi-bin/boot_manager.sh"
TITLE_PREFIX="$(cluster_config get CLUSTER_NAME) \${mac:hexraw} \${net0/ip}:"

cat <<EOF
#!ipxe

set logmsg ${FUNCNAME[1]} $(cluster_config get CLUSTER_NAME) \${net0/ip} ipxe_header
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

# Print some info
#echo
#echo Connected to cluster $(cluster_config get CLUSTER_NAME)
#echo Client IP: \${client_ip} MAC address: \${mac:hexraw}
#echo
EOF
}


handle_menu_item() {
  local item="$1"
  local mac="$2"

  case "$item" in

    init_menu)
      ipxe_init
      ;;

    install_menu)
      if has_sch_host
       then
        ipxe_install_hosts_menu
      else
        ipxe_install_sch
       fi
      ;;

    recover_DRH)
      ipxe_init
      ;;

    show_ipxe|show_cluster|show_host|show_paths)
      ipxe_show_info ${item}
      ;;

    unconfigure)
      ipxe_header
      host_config_delete "$mac"
      echo "sleep 1"
      echo "reboot"
      ;;

  
    reboot)
      hps_log info "[$mac] $item Reboot requested"
      ipxe_header
      echo "echo Rebooting"
      echo "sleep 1"
      echo "reboot"
      ;;

    local_boot)
      hps_log info "[$mac] $item Boot from local disk"
      ipxe_header
      echo "echo Local boot requested"
      echo "sleep 5"
      echo "sanboot --no-describe --drive 0x80"
      ;;

    reinstall)
      hps_log info "[$mac] $item Reinstall requested"
      host_config "$mac" set STATE REINSTALL
      ipxe_install_menu
      ;;

    rescue)
      hps_log info "[$mac] $item Entering rescue shell"
      ipxe_header
      echo "echo Local shell"
      echo "sleep 1"
      echo "shell"
      ;;

    install_TCH|install_DRH|install_SCH|install_CCH)
      local type="${item#install_}"
      ipxe_boot_installer "$type"
      ;;

    *)
      hps_log info "[$mac] Unknown menu item: $item"
      cgi_fail "Unknown menu item: $item"
      ;;
  esac
}


ipxe_init () {

# This menu is delivered if the cluster is configured and we don't know who the host is yet

ipxe_header

cat <<EOF

set config_url ${CGI_URL}?mac=\${mac:hexraw}&cmd=determine_state
echo Requesting: \${config_url}

# If we can find a config, load it (replaces this iPXE config)
imgfetch --name config \${config_url} || goto no_host_config
imgload config
imgstat
imgexec config

# If there is no config - this should never happen as the boot manager will create it
:no_host_config
echo No host config found for MAC \${mac:hexraw} at \${config_url}
sleep 5
reboot

EOF

}


ipxe_install_sch () {
ipxe_header

cat <<EOF
menu ${TITLE_PREFIX} Install Storage Cluster Host
item --gap 
item --gap At least one Storage Cluster Hosts must be configured.
item --gap 
item init_menu    < Back to initialisation menu
item --gap 
item install_SCH  > Install Storage Cluster Host

choose selection && goto HANDLE_MENU

:HANDLE_MENU
set logmsg ${FUNCNAME[1]} Menu selected: \${selection}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

chain ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

EOF

}

ipxe_install_menu () {
ipxe_header

cat <<EOF
menu ${TITLE_PREFIX} Select installation option:
item --gap What would you like to configure \${mac:hexraw} as?
item --gap 
item init_menu    < Back to initialisation menu
item --gap 
item install_TCH  > Install Thin Compute Host
item install_SCH  > Install Storage Cluster Host
item install_DRH  > Install Disaster Recovery Host
item install_CCH  > Install Container Cluster Host

choose selection && goto HANDLE_MENU

:HANDLE_MENU
set logmsg ${FUNCNAME[1]} Menu selected: \${selection}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

chain ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

EOF

}

ipxe_configure_menu () {

# This menu is delivered if the cluster is configured, but the host is not
# Main menu, if we are not configured

# has_sch_host - otherwise can only configure storage

# iPXE output as heredoc

hps_log debug "[$mac] Delivering configure menu"

ipxe_header

cat <<EOF

menu ${TITLE_PREFIX} Select a host option:

item install_menu > Host install menu
item --gap 
item recover_DRH  > NOT YET IMPLEMENTED: Recover from Disaster Recovery Host (DRH) 
item --gap 
item local_boot   Boot from local disk
item reboot       Reboot system
item --gap 
item show_ipxe    Show host and cluster configuration
item rescue       Enter rescue shell
item reinstall    Reinstall current host
item unconfigure  Unconfigure this host

choose selection && goto HANDLE_MENU

:HANDLE_MENU
set logmsg ${FUNCNAME[1]} Menu selected: \${selection}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

chain ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

EOF

}

ipxe_boot_installer () {
  local host_type=$1
  hps_log info "[$mac] Installing new host of type $host_type"
  
  load_cluster_host_type_profiles

  local CPU="$(get_host_type_param ${host_type} CPU)"
  local MFR="$(get_host_type_param ${host_type} MFR)"
  local OSNAME="$(get_host_type_param ${host_type} OSNAME)"
  local OSVER="$(get_host_type_param ${host_type} OSVER)"

  host_config "$mac" set TYPE "$host_type"
  host_config "$mac" set STATE INSTALLING


  DIST_PATH="$HPS_DISTROS_DIR/${CPU}-${MFR}-${OSNAME}/${OSVER}"
  DIST_URL="distros/${CPU}-${MFR}-${OSNAME}/${OSVER}"

  ipxe_header

# HPS_PACKAGES_DIR

  case "${OSNAME}" in
    rockylinux)

    KERNEL_FILE=images/pxeboot/vmlinuz
    INITRD_FILE=images/pxeboot/initrd.img

    # check that the file exists
    if [ ! -f $DIST_PATH/${KERNEL_FILE} ]
     then
      cgi_fail "$DIST_PATH/${KERNEL_FILE} doesn't exist"
    fi

  hps_log debug "[$mac] Preparing PXE Boot for ${OSNAME} install"

  cat <<EOF

kernel http://\${next-server}/${DIST_URL}/${KERNEL_FILE} \
  inst.stage2=http://\${next-server}/${DIST_URL} \
  inst.ks=${CGI_URL}?cmd=kickstart&mac=\${mac:hexraw}&hosttype=${host_type} \
  ip=dhcp \
  console=ttyS0,115200n8

initrd http://\${next-server}/${DIST_URL}/${INITRD_FILE}
boot

EOF
  ;;
  
  debian)
    cgi_fail "No Debian config yet"
  ;;
  *)
    cgi_fail "No configuration for ${CPU}-${MFR}-${OSNAME}-${OSVER}"
  ;;
esac


}






ipxe_show_info() {
  ipxe_header
  local category="$1"

  case "$category" in
  
    show_ipxe)
      cat <<'EOF'
menu Host iPXE Information
item --gap MAC: ${mac}
item --gap IP: ${net0/ip}
item --gap Hostname: ${hostname}
item --gap Platform: ${platform} (${buildarch})
item --gap UUID: ${uuid}
item --gap Serial: ${serial}
item --gap Product: ${product}
item --gap
item init_menu    < Back to initialisation menu
item --gap
item show_cluster > Show cluster configuration
item show_host    > Show host configuration
item show_paths   > Show system paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_cluster)
      echo "menu Cluster Configuration"

      local config_file="${HPS_CLUSTER_CONFIG_DIR}/cluster.conf"
      if [[ ! -f "$config_file" ]]; then
        echo "item --gap [✗] Cluster config not found: $config_file"
      else
        while IFS='=' read -r k v; do
          [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
          v="${v%\"}"; v="${v#\"}"
          echo "item --gap ${k}: ${v}"
        done < "$config_file"
      fi

      cat <<'EOF'

item --gap
item init_menu     < Back to initialisation menu
item --gap
item show_ipxe     > Show iPXE system info
item show_host     > Show host configuration
item show_paths    > Show system paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_host)
      echo "menu Host Configuration"

      local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"
      if [[ ! -f "$config_file" ]]; then
        echo "item --gap [✗] Host config not found: $config_file"
      else
        while IFS='=' read -r k v; do
          [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
          v="${v%\"}"; v="${v#\"}"
          echo "item --gap ${k}: ${v}"
        done < "$config_file"
      fi

      cat <<'EOF'

item --gap
item init_menu     < Back to initialisation menu
item --gap
item show_ipxe     > Show iPXE system info
item show_cluster  > Show cluster configuration
item show_paths    > Show system paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_paths)
      echo "menu System Paths"

      if [[ ! -f "${HPS_CONFIG}" ]]; then
        echo "item --gap [✗]  hps.conf not found: ${HPS_CONFIG}"
      else
        grep -E '^export ' "${HPS_CONFIG}" | while read -r line; do
          varname=$(echo "$line" | cut -d= -f1 | awk '{print $2}')
          value=$(echo "$line" | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')
          echo "item --gap ${varname}: ${value}"
        done
      fi

      cat <<'EOF'

item --gap
item init_menu     < Back to initialisation menu
item --gap
item show_ipxe     > Show iPXE system info
item show_cluster  > Show cluster configuration
item show_host     > Show host configuration

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    *)
      echo "#!ipxe"
      echo "echo Unknown category: $category"
      echo "sleep 3"
      echo "chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=init_menu"
      ;;
  esac
}



