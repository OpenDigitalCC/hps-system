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
  # IPXE failure message
  ipxe_header
  local cfmsg="$1"
  hps_log error "[$(cgi_param get mac)] ${FUNCNAME[1]} $cfmsg"
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
  # Boot from local disk via bios by exiting the iPXE stack
  ipxe_header
  echo "echo Handing back to BIOS to boot"
  echo "sleep 5"
  echo "exit"
}

handle_menu_item() {
  # This function handles any ipxe menu function across all menus
  local item="$1"
  local mac="$2"

  case "$item" in

    init_menu)
      ipxe_init
      ;;

    host_install_menu)
      if cluster_has_installed_sch
       then
        ipxe_host_install_menu
      else
        ipxe_host_install_sch
       fi
      ;;

    recover_DRH)
      ipxe_init
      ;;

    show_ipxe|show_cluster|show_host|show_paths)
      ipxe_show_info ${item}
      ;;

    unconfigure)
      host_config_delete "$mac"
      ipxe_reboot "Menu selected - Unconfigure $mac and reboot"
      ;;

    unmanage)
      host_config "$mac" set STATE UNMANAGED
      ipxe_reboot "Menu selected - Set to UNMANAGED and reboot"
      ;;
  
    reboot)
      hps_log info "[$mac] $item Reboot requested"
      ipxe_reboot "Menu selected - reboot"
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
      ipxe_host_install_menu
      ;;

    rescue)
      hps_log info "[$mac] $item Entering rescue shell"
      ipxe_header
      echo "echo Local shell"
      echo "sleep 1"
      echo "shell"
      ;;

    install_*)
      local HOST_TYPE="${item#install_}"
      local HOST_TYPE="${HOST_TYPE%_*}"
      local HOST_PROFILE="${item##*_}"
      hps_log info "[$mac] $item Running boot installer for type: "${HOST_TYPE}" profile: "${HOST_PROFILE}""
      ipxe_boot_installer "${HOST_TYPE}" "${HOST_PROFILE}"
      ;;

    force_install_*)
      if [[ "${item}" == "force_install_on" ]] 
       then
        host_config "$mac" set FORCE_INSTALL YES
        host_config "$mac" set STATUS UNCONFIGURED
        ipxe_reboot "FORCE_INSTALL set to YES"
       else
        host_config "$mac" set FORCE_INSTALL NO
#        host_config "$mac" set STATUS UNCONFIGURED
        ipxe_reboot "FORCE_INSTALL set to NO"
      fi       
      ;;

    *)
      hps_log info "[$mac] Unknown menu item: $item"
      ipxe_cgi_fail "Unknown menu item: $item"
      ;;
  esac
}


ipxe_init () {
  # This menu is delivered if the cluster is configured and we don't know who the host is yet as we don't yet have the MAC
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


ipxe_host_install_sch () {
  # Run this to present menu to install SCH
  ipxe_header

cat <<EOF
# Fixed iPXE menu for Storage Cluster Host installation
:start
menu ${TITLE_PREFIX} Install Storage Cluster Host
item --gap 
item --gap At least one Storage Cluster Host must be configured for a cluster.
item --gap Note: This will execute the installation immediately
item --gap 
item init_menu    < Back to initialisation menu
item --gap 
item install_SCH_STORAGESINGLE  > Install now: ZFS single-disk (for testing or multiple hosts)
item install_SCH_STORAGERAID    > Install now: ZFS RAID (for multiple local disks)
choose action

set logmsg "Menu selected: \${action}"
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed
chain --replace ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${action}

EOF

}

ipxe_host_install_menu () {
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

ipxe_configure_main_menu () {

# This menu is delivered if the cluster is configured, but the host is not
# Main menu, if we are not configured

hps_log debug "[$mac] Delivering configure menu"

ipxe_header

if [[ "$(host_config "$mac" get FORCE_INSTALL)" == "YES" ]]; then
  FI_MENU="item force_install_off Disable forced installation"
  hps_log debug "[$mac] Forced install set"
else
  FI_MENU="item force_install_on  Enable Forced installation, overwriting current O/S on next boot"
  hps_log debug "[$mac] Forced install not set"
fi


cat <<EOF

menu ${TITLE_PREFIX} Select a host option:

item --gap Host options
item host_install_menu > Host install menu
item show_ipxe    > Show host and cluster configuration
item --gap 
item recover_DRH  > NOT YET IMPLEMENTED: Recover from Disaster Recovery Host (DRH) 
item --gap 
item --gap System options
item rescue       < Enter rescue shell
item local_boot   < Boot from local disk
item reboot       < Reboot host
item --gap 

item --gap Advanced options
item unmanage     Set this host to not be managed by HPS
item unconfigure  Unconfigure this host
item reinstall    Reinstall current host
${FI_MENU}

choose selection && goto HANDLE_MENU

:HANDLE_MENU
set logmsg ${FUNCNAME[1]} Menu selected: \${selection}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed

chain --replace ${CGI_URL}?cmd=process_menu_item&mac=\${mac:hexraw}&menu_item=\${selection}

EOF

}

ipxe_reboot () {
  local MSG=$1
  hps_log info "[$mac] Reboot requested $MSG"
  ipxe_header
  [[ -n $MSG ]] && echo "echo $MSG"
  echo "echo Rebooting..."
  echo "sleep 5"
  echo "reboot"
}

ipxe_boot_installer () {
  local host_type=$1
  local profile=$2
  
  hps_log info "[$mac] Installing new host of type $host_type"
  
  load_cluster_host_type_profiles

  local CPU="$(get_host_type_param ${host_type} CPU)"
  local MFR="$(get_host_type_param ${host_type} MFR)"
  local OSNAME="$(get_host_type_param ${host_type} OSNAME)"
  local OSVER="$(get_host_type_param ${host_type} OSVER)"
  local state="$(host_config "$mac" get STATE)"

  # check that we are not already installed
  if [ "$state" == "INSTALLED" ]
   then
    ipxe_reboot "Host already installed, aborting installation"
  fi

  host_config "$mac" set TYPE "$host_type"
  if [[ -n "$profile" ]]
   then
    host_config "$mac" set PROFILE "$profile"
  fi

  DIST_PATH="$HPS_DISTROS_DIR/${CPU}-${MFR}-${OSNAME}-${OSVER}"
  DIST_URL="distros/${CPU}-${MFR}-${OSNAME}-${OSVER}"

  mount_distro_iso "${CPU}-${MFR}-${OSNAME}-${OSVER}"

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
  ipxe_header
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
  #echo "${IPXE_BOOT_INSTALL}"  > /tmp/ipxe-boot-install.ipxe
  host_config "$mac" set STATE INSTALLING
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
menu iPXE host data
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
#item show_ipxe     > Show iPXE host data
item show_cluster > Show cluster configuration
item show_host    > Show host configuration
item show_paths   > Show HPS paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain --replace ${CGI_URL}?cmd=process_menu_item&menu_item=${selection}
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
item show_ipxe     > Show iPXE host data
#item show_cluster  > Show cluster configuration
item show_host     > Show host configuration
item show_paths    > Show HPS paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain --replace ${CGI_URL}?cmd=process_menu_item&menu_item=${selection}
EOF
      ;;

    show_host)
      echo "menu Host Configuration"
      if [[ ! -f "${HPS_CONFIG}" ]]
       then
        echo "item --gap [x] Host config not found: ${HPS_CONFIG}"
      else
        while IFS='=' read -r k v; do
          [[ "$k" =~ ^#.*$ || -z "$k" ]] && continue
          v="${v%\"}"; v="${v#\"}"
          echo "item --gap ${k}: ${v}"
        done < "${HPS_CONFIG}"
      fi

      cat <<'EOF'

item --gap
item init_menu     < Back to initialisation menu
item --gap
item show_ipxe     > Show iPXE host data
item show_cluster  > Show cluster configuration
#item show_host     > Show host configuration
item show_paths    > Show HPS paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain --replace ${CGI_URL}?cmd=process_menu_item&menu_item=${selection}
EOF
      ;;

    show_paths)
      echo "menu HPS Paths"

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
item show_ipxe     > Show iPXE host data
item show_cluster  > Show cluster configuration
item show_host     > Show host configuration
#item show_paths    > Show HPS paths

choose selection && goto HANDLE_MENU

:HANDLE_MENU
chain --replace ${CGI_URL}?cmd=process_menu_item&menu_item=${selection}
EOF
      ;;

    *)
      echo "echo Unknown item: $category"
      echo "sleep 3"
      echo "chain ${CGI_URL}?cmd=process_menu_item&mac=${mac:hexraw}&menu_item=init_menu"
      ;;
  esac
}



