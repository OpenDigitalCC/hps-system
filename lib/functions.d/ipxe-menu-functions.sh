__guard_source || return
# Define your functions below

CGI_URL="http://\${next-server}/cgi-bin/boot_manager.sh"

ipxe_header () {
# Send pxe header so we don't get a boot failure
cgi_header_plain
# Set some variables to be used in IPXE scripts
TITLE_PREFIX="$(cluster_config get CLUSTER_NAME) \${mac:hexraw} \${net0/ip}:"
cat <<EOF
#!ipxe
set logmsg $(cluster_config get CLUSTER_NAME) \${net0/ip} iPXE Header requested by ${FUNCNAME[1]}
imgfetch --name log ${CGI_URL}?cmd=log_message&mac=\${mac:hexraw}&message=\${logmsg} || echo Log failed
echo
echo Connected to cluster $(cluster_config get CLUSTER_NAME) 
echo Client IP: \${client_ip} MAC address: \${mac:hexraw}
echo "Function: ${FUNCNAME[1]}"
echo
EOF
}

ipxe_cgi_fail () {
  # IPXE failure message
  ipxe_header
  local cfmsg="$1"
  hps_log error "$cfmsg"
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
      hps_log info "$item Reboot requested"
      ipxe_reboot "Menu selected - reboot"
      ;;

    local_boot)
      hps_log info "$item Boot from local disk"
      ipxe_header
      echo "echo Local boot requested"
      echo "sleep 5"
      echo "sanboot --no-describe --drive 0x80"
      ;;

    reinstall)
      hps_log info "$item Reinstall requested"
      host_config "$mac" set STATE REINSTALL
      ipxe_host_install_menu
      ;;

    rescue)
      hps_log info "$item Entering rescue shell"
      ipxe_header
      echo "echo Local shell"
      echo "sleep 1"
      echo "shell"
      ;;

    install_*)
      local HOST_TYPE="${item#install_}"
      local HOST_PROFILE=""
      
      # Check if there's an underscore indicating a profile suffix
      if [[ "$HOST_TYPE" =~ ^([^_]+)_(.+)$ ]]; then
        # Extract type and profile from the match
        HOST_TYPE="${BASH_REMATCH[1]}"
        HOST_PROFILE="${BASH_REMATCH[2]}"
        # Set HOST_PROFILE
        if [[ -n "${profile}" ]]; then
          host_config "$mac" set HOST_PROFILE "${profile}"
        fi  
        hps_log info "$item Running boot installer for type: '${HOST_TYPE}' profile: '${HOST_PROFILE}'"
      else
        # No profile suffix, HOST_PROFILE remains empty
        hps_log info "$item Running boot installer for type: '${HOST_TYPE}' (no profile)"
      fi
      
      ipxe_boot_installer "$mac" "${HOST_TYPE}"
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
      hps_log info "Unknown menu item: $item"
      ipxe_cgi_fail "Unknown menu item: $item"
      ;;
  esac
}


#TODO: this is redundant now
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

item --gap Install Thin Compute Host
item install_TCH  > Default profile
item install_TCH_KVM  > Profile: KVM virtualisation
item install_TCH_DOCKER  > Profile: Docker host
item install_TCH_BUILD  > Profile: Build tools for packaging

item --gap 
item --gap Install Storage Cluster Host
item install_SCH  > Default profile
item --gap 
item --gap Install Disaster Recovery Host
item install_DRH  > Default profile

choose selection && goto HANDLE_MENU

:HANDLE_MENU
set logmsg ${FUNCNAME[1]} Menu selected: \${selection}
imgfetch --name log ${CGI_URL}?cmd=log_message&message=\${logmsg} || echo Log failed

chain --replace ${CGI_URL}?cmd=process_menu_item&menu_item=\${selection}

EOF

}

ipxe_configure_main_menu () {

# This menu is delivered if the cluster is configured, but the host is not
# Main menu, if we are not configured
hps_log debug "Delivering configure menu"
ipxe_header

# run iPXE audit
ipxe_host_audit_include

if [[ "$(host_config "$mac" get FORCE_INSTALL)" == "YES" ]]; then
  FI_MENU="item force_install_off Disable forced installation"
  hps_log debug "Forced install set"
else
  FI_MENU="item force_install_on  Enable Forced installation, overwriting current O/S on next boot"
  hps_log debug "Forced install not set"
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
  hps_log info "Reboot requested $MSG"
  ipxe_header
  [[ -n $MSG ]] && echo "echo $MSG"
  echo "echo Rebooting..."
  echo "sleep 5"
  echo "reboot"
}


## This function runs once the user selects the install type from the install menu. 
# It is the opportunity to configure the host variables
ipxe_boot_installer () {
  local mac="$1"
  local host_type="$2"

  host_config "$mac" "set" "TYPE" "$host_type"

  local arch="$(host_config "$mac" get arch)"
  local os_id=$(get_host_os_id "$mac")  # Determines from cluster config
  host_config "$mac" "set" "os_id" "$os_id"

  hps_log info "Installing new host of type $host_type ($arch) with $os_id"

  # Assign network addresses and other host config details
  host_network_configure "$mac"

  # TCH are thin, so the only option is to network boot  
  if [[ "${host_type}" == "TCH" ]]; then
    # TCH: Set state and reboot for network boot preparation
    hps_log info "Setting up TCH for network boot"
    host_config "$mac" set STATE NETWORK_BOOT
    ipxe_reboot "TCH configured for network boot - rebooting to apply"
    exit
  fi

  # Select OS based on architecture and host type
  # First try architecture-specific config
  local lc_type=$(echo ${host_type} | tr '[:upper:]' '[:lower:]')
  os_key="os_${lc_type}_${arch}"
  os_id=$(cluster_config "get" "$os_key")

  # Fallback to any OS for this arch/type
  if [[ -z "$os_id" ]]; then
    os_id=$(os_config_select "$arch" "$lc_type")
  fi

  hps_log debug "os_key: $os_key os_id: $os_id"
 
  local state="$(host_config "$mac" get STATE)"

  # Last check - Abort if we are already installed
  if [ "$state" == "INSTALLED" ]
   then
    ipxe_reboot "Host already installed, aborting installation"
  fi

  local os_name=$(os_config "$os_id" "get" "name")
  local boot_server=$(cluster_config get DHCP_IP)
  local distro_mount=$(get_distro_base_path "$os_id" "mount")
  local repo_base="http://${boot_server}/$(get_distro_base_path $os_id http)"

  # Define file locations based on OS type
  case "$os_name" in
    rocky|rockylinux|alma|almalinux)
      local kernel_rel="images/pxeboot/vmlinuz"
      local initrd_rel="images/pxeboot/initrd.img"
      # Generate iPXE using HTTP paths
      local kickstart_cmd="http://${boot_server}/cgi-bin/boot_manager.sh?cmd=kickstart"
      local boot_kernel_line="$repo_base/${kernel_rel}"
      local boot_kernel_line="${boot_kernel_line} initrd=initrd.img" 
      local boot_kernel_line="${boot_kernel_line} inst.stage2=${repo_base}"
      local boot_kernel_line="${boot_kernel_line} rd.live.ram=1"
      local boot_kernel_line="${boot_kernel_line} ip=dhcp console=ttyS0,115200n8"
      local boot_kernel_line="${boot_kernel_line} inst.ks=${kickstart_cmd}"
      local boot_kernel_line="${boot_kernel_line} inst.text"  # Force text mode
      local boot_kernel_line="${boot_kernel_line} inst.syslog=ips:514"
#  local boot_kernel_line="${boot_kernel_line} inst.vnc"   # Enable VNC for debugging
#  local boot_kernel_line="${boot_kernel_line} rd.debug"   # Enable debug logging
#  local boot_kernel_line="${boot_kernel_line} inst.loglevel=debug"  # Anaconda debug
      local boot_initrd_line="${repo_base}/${initrd_rel}"
      ;;
    alpine)
      local kernel_rel="boot/vmlinuz-lts"
      local initrd_rel="boot/initramfs-lts"
      ;;
    *)
      ipxe_cgi_fail "Unknown OS type: $os_name"
      ;;
  esac

  mount_distro_iso "$os_id"

  # Check files exist using mount path
  if [[ ! -f "${distro_mount}/${kernel_rel}" ]]; then
    ipxe_cgi_fail "Kernel not found: ${distro_mount}/${kernel_rel} for $host_type/$arch"
  fi

  if [[ ! -f "${distro_mount}/${initrd_rel}" ]]; then
    ipxe_cgi_fail "Initrd not found: ${distro_mount}/${initrd_rel} for $host_type/$arch"
  fi


  hps_log debug "Preparing PXE Boot for ${os_id} non-interactive installation"
  hps_log debug "boot_kernel_line: $boot_kernel_line"

  hps_log info "Installer instruction sent. "
  _do_pxe_boot "$boot_kernel_line" "$boot_initrd_line"
}


ipxe_network_boot() {
  local host_type=$(host_config "$mac" get TYPE)
  hps_log debug "Booting host of type ${host_type}"
  
  case "$host_type" in
    TCH)
      # Validate Alpine repository before attempting boot
      os_id=$(get_host_os_id "$mac")
      if ! validate_alpine_repository "$os_id" "main" ; then
        local alpine_version="$(get_host_os_version "$mac")"
        hps_log error "Alpine repository validation failed for TCH boot"
        ipxe_cgi_fail "Alpine ${alpine_version} repository not ready. Run: sync_alpine_repository \"${alpine_version}\" \"main\""
        return 1
      fi
      ipxe_boot_alpine_tch
      ;;
    *)
      ipxe_cgi_fail "Network boot not supported for host type: $host_type"
      ;;
  esac
}


ipxe_boot_alpine_tch() {
  local alpine_version="$(get_host_os_version "$mac")"

  local client_ip=$(host_config "$mac" get IP)
  local ips_address=$(cluster_config get DHCP_IP)
  local network_cidr=$(cluster_config get NETWORK_CIDR)
  local hostname=$(host_config "$mac" get HOSTNAME)

  # Extract netmask from CIDR (10.99.1.0/24 -> 255.255.255.0)
  local prefix_len="${network_cidr##*/}"
  local netmask=$(cidr_to_netmask "$prefix_len")

  local download_base="http://${ips_address}/$(get_distro_base_path "$os_id" http)"

  local os_id=$(get_host_os_id "$mac")

  apkovl_file_disk="$(get_tch_apkovl_filepath)"
  # Generate apk overlay if missing
  if [[ ! -f "${apkovl_file_disk}" ]]; then
    hps_log info "Generating Alpine apkovl for version $alpine_version"
    tch_apkovol_create "${apkovl_file_disk}"
  fi

  hps_log debug "Configuring TCH version $alpine_version with static IP: $client_ip"

  local boot_kernel_args="initrd=initramfs-lts"
  boot_kernel_args="${boot_kernel_args} console=ttyS0,115200n8"
  boot_kernel_args="${boot_kernel_args} alpine_repo=${download_base}/apks/main"
  boot_kernel_args="${boot_kernel_args} ip=${client_ip}::${ips_address}:${netmask}:${hostname}:eth0:off"
  boot_kernel_args="${boot_kernel_args} apkovl=$download_base/$(get_tch_apkovl_filename)"

  local kernel_rel="boot/vmlinuz-lts"
  local initrd_rel="boot/initramfs-lts"
  
  local boot_kernel_line="${download_base}/${kernel_rel} ${boot_kernel_args}"
  local boot_initrd_line="${download_base}/${initrd_rel}"

  _do_pxe_boot "$boot_kernel_line" "$boot_initrd_line"
}


_do_pxe_boot () {
  local kernel="$1"
  local initrd="$2"
  # Validate required parameters
  if [[ -z "$kernel" ]] || [[ -z "$initrd" ]]; then
   hps_log error "Both kernel and initrd parameters are required"
    return 1
  fi
  hps_log info "Sending iPXE boot kernel and initrd"
  hps_log debug "kernel: $kernel"
  hps_log debug "initrd: $initrd"

  ipxe_header
  IPXE_BOOT_INSTALL=$(cat <<EOF
# created at $(date)

# Required to prevent corrupt initrd
imgfree

kernel $kernel
initrd $initrd

sleep 1
boot

EOF
  )
  echo "${IPXE_BOOT_INSTALL}"
  hps_log debug "Files sent"
}





ipxe_host_audit_include () {

# No header sent as this is an include to be used inside other functions

hps_log debug "Loading iPXE  audit"

cat <<EOF


# System audit with validation
isset \${manufacturer} && set mfg \${manufacturer:uristring} || set mfg UNKNOWN
isset \${product} && set prod \${product:uristring} || set prod UNKNOWN  
isset \${serial} && set ser \${serial:uristring} || set ser NONE
isset \${memsize} && set mem \${memsize} || set mem 0
isset \${buildarch} && set buildarch \${buildarch} || set buildarch UNKNOWN
isset \${platform} && set plat \${platform} || set plat UNKNOWN

set audit_data mfg=\${mfg}|prod=\${prod}|ser=\${ser}|mem=\${mem}|buildarch=\${buildarch}|plat=\${plat}
imgfetch --name audit ${CGI_URL}?cmd=host_audit&prefix=host&data=\${audit_data:uristring} || echo Audit failed

set net_data ip=\${net0/ip}|gw=\${net0/gateway}|dns=\${net0/dns}|dhcp=\${net0/dhcp-server}
imgfetch --name netinfo ${CGI_URL}?cmd=host_audit&prefix=net&data=\${net_data:uristring} || echo Network failed


# SMBIOS data - check if valid before sending
#isset \${smbios/bios-vendor} && iseq \${smbios/bios-vendor} \${smbios/bios-vendor} && set bios_v \${smbios/bios-vendor:uristring} || set bios_v NOTFOUND
#isset \${smbios/bios-version} && iseq \${smbios/bios-version} \${smbios/bios-version} && set bios_ver \${smbios/bios-version:uristring} || set bios_ver NOTFOUND
#isset \${smbios/baseboard-manufacturer} && iseq \${smbios/baseboard-manufacturer} \${smbios/baseboard-manufacturer} && set board_mfg \${smbios/baseboard-manufacturer:uristring} || set board_mfg NOTFOUND

set smbios_data bios_vendor=\${bios_v}|bios_ver=\${bios_ver}|board_mfg=\${board_mfg}
imgfetch --name smbios ${CGI_URL}?cmd=host_audit&prefix=smbios&data=\${smbios_data:uristring} || echo SMBIOS failed

set audit_data mfg=\${manufacturer:uristring}|prod=\${product:uristring}|ser=\${serial:uristring}|mem=\${memsize}|buildarch=\${buildarch}|plat=\${platform}
imgfetch --name audit ${CGI_URL}?cmd=host_audit&prefix=audit&data=\${audit_data:uristring} || echo Audit failed

# Example 2: SMBIOS data
#set smbios_data bios_vendor=\${smbios/bios-vendor:uristring}|bios_ver=\${smbios/bios-version:uristring}|board_mfg=\${smbios/baseboard-manufacturer:uristring}
#imgfetch --name smbios ${CGI_URL}?cmd=host_audit&prefix=smbios&data=\${smbios_data:uristring} || echo SMBIOS failed

# Example 3: PCI devices
#pciscan
#set pci_data 0:1f.0=\${pci/0:1f.0/vendor}.\${pci/0:1f.0/device}|0:00.0=\${pci/0:00.0/vendor}.\${pci/0:00.0/device}
#imgfetch --name pci ${CGI_URL}?cmd=host_audit&prefix=pci&data=\${pci_data:uristring} || echo PCI failed

EOF
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
item --gap Serial: \${serial}
item --gap Product: \${product}
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



