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

set logmsg ${FUNCNAME[1]} $(cluster_config get CLUSTER_NAME) \${net0/ip}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

echo
echo Connected to cluster $(cluster_config get CLUSTER_NAME)
echo Client IP: \${client_ip} MAC address: \${mac:hexraw}
echo
EOF
}


ipxe_cgi_fail () {
  local cfmsg="$1"
  hps_log error "[$(cgi_param get mac)] ${FUNCNAME[1]} $cfmsg"
#  cgi_header_plain
  echo "#!ipxe"
  echo "echo == ERROR =="
  echo "echo"
  echo "echo Error: $1"
  echo "echo"
  echo "sleep 10"
  echo "reboot"
  exit
}


ipxe_boot_from_disk () {
ipxe_header
echo "echo This device is installed."
echo "echo Handing back to BIOS to boot"
echo "sleep 5"
echo "exit"
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
      ipxe_cgi_fail "Unknown menu item: $item"
      ;;
  esac
}


ipxe_init () {

# This menu is delivered if the cluster is configured and we don't know who the host is yet

ipxe_header

cat <<EOF

set config_url ${CGI_URL}?mac=\${mac:hexraw}&cmd=boot_action
echo Requesting: \${config_url}

## If we can find a config, load it (replaces this iPXE config)
imgfetch --name config \${config_url} 
#|| goto no_host_config
imgload config
imgstat
imgexec config

# If there is no config - this should never happen as the boot manager will create it
#:no_host_config
#echo No host config found for MAC \${mac:hexraw} at \${config_url}
#sleep 10
#reboot

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

chain --replace ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

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

chain --replace ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

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

chain --replace ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

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
  local state="$(host_config "$mac" get STATE)"

  ipxe_header


  # check that we are not already installed
  if [ "$state" == "INSTALLED" ]
   then
    echo "echo Host already installed, aborting installation"
    echo "sleep 10"
    echo "reboot"
  fi


  host_config "$mac" set TYPE "$host_type"
  host_config "$mac" set STATE INSTALLING

  DIST_PATH="$HPS_DISTROS_DIR/${CPU}-${MFR}-${OSNAME}-${OSVER}"
  DIST_URL="distros/${CPU}-${MFR}-${OSNAME}-${OSVER}"

  case "${OSNAME}" in
    rockylinux)

    KERNEL_FILE=images/pxeboot/vmlinuz
    INITRD_FILE=images/pxeboot/initrd.img

    # check that the file exists
    if [ ! -f $DIST_PATH/${KERNEL_FILE} ]
     then
      ipxe_cgi_fail "$DIST_PATH/${KERNEL_FILE} doesn't exist for type $host_type"
    fi

  hps_log debug "[$mac] Preparing PXE Boot for ${OSNAME} ${OSVER} non-interactive installation"


IPXE_BOOT_INSTALL=$(cat <<EOF
# created at $(date)

# Detect CPU architecture
cpuid --ext 29 && set arch x86_64 || set arch i386

set diststring \${arch}-${MFR}-${OSNAME}-${OSVER}
set repo_base http://\${dhcp-server}/distros/\${diststring}

set kernel_url \${repo_base}/${KERNEL_FILE}
set initrd_url \${repo_base}/${INITRD_FILE}
set repo_url \${repo_base}
set ks ${CGI_URL}?cmd=kickstart&mac=\${mac:hexraw}&hosttype=${host_type}

# set kernel_args initrd=initrd.img inst.repo=\${repo_url} ip=dhcp rd.debug rd.live.debug console=ttyS0,115200n8 inst.ks=\${ks}
set kernel_args initrd=initrd.img inst.repo=\${repo_url} ip=dhcp console=ttyS0,115200n8 inst.ks=\${ks}

# Required to prevent corrupt initrd
imgfree

kernel \${kernel_url} \${kernel_args}
initrd \${initrd_url}

sleep 10
boot


#echo Booting image
#imgstat
#set logmsg ${FUNCNAME[1]} \${kernel_url} \${kernel_args} \${initrd_url}
#imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

EOF
)

# debug: make file with the ipxe menu
echo "${IPXE_BOOT_INSTALL}"  > /tmp/ipxe-boot-install.ipxe
echo "${IPXE_BOOT_INSTALL}"


  ;;
  
  debian)
    ipxe_cgi_fail "No Debian config yet"
  ;;
  *)
    ipxe_cgi_fail "No configuration for ${CPU}-${MFR}-${OSNAME}-${OSVER}"
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
chain --replace ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_cluster)
      echo "menu Cluster Configuration"

      local config_file="${HPS_CLUSTER_CONFIG_DIR}/cluster.conf"
      if [[ ! -f "$config_file" ]]; then
        echo "item --gap [x] Cluster config not found: $config_file"
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
chain --replace ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_host)
      echo "menu Host Configuration"

      local config_file="${HPS_HOST_CONFIG_DIR}/${mac}.conf"
      if [[ ! -f "$config_file" ]]; then
        echo "item --gap [x] Host config not found: $config_file"
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
chain --replace ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
EOF
      ;;

    show_paths)
      echo "menu System Paths"

      if [[ ! -f "${HPS_CONFIG}" ]]; then
        echo "item --gap [x]  hps.conf not found: ${HPS_CONFIG}"
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
chain --replace ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=${selection}
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



