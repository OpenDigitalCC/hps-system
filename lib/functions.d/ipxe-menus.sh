__guard_source || return
# Define your functions below

ipxe_header () {
cgi_header_plain
cat <<EOF
#!ipxe

# Set some variables
set client_ip \${net0/ip}

# Print some info
echo
echo Connected to cluster $(cluster_config get CLUSTER_NAME)
echo Client IP: \${client_ip} MAC address: \${mac:hexraw}
echo
EOF
}


ipxe_first_boot () {

# This menu is delivered if the cluster is configured, but the host is not



# iPXE output as heredoc

ipxe_header

cat <<EOF

# Request per-host config
set config_url http://\${next-server}/cgi-bin/boot_manager.sh?mac=\${mac:hexraw}&cmd=get_config
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


ipxe_config_menu () {

# This menu is delivered if the cluster is configured, but the host is not
# Main menu, if we are not configured

# has_sch_host - otherwise can only configure storage

# iPXE output as heredoc

ipxe_header

cat <<EOF

menu Select a host configuration option:

echo What would you like to configure \${mac:hexraw} as?

item SCH Storage Cluster Host
item DRH Disaster Recovery Host
item TCH Thin Compute Host
item CCH Container Cluster Host
item local Boot from local disk
item reboot Reboot
choose host_type && goto \${host_type}

:TCH
chain http://\${next-server}/cgi-bin/boot_manager.sh?cmd=config_host&mac=\${mac:hexraw}&hosttype=TCH || goto no_chain_config
:DRH
chain http://\${next-server}/cgi-bin/boot_manager.sh?cmd=config_host&mac=\${mac:hexraw}&hosttype=DRH || goto no_chain_config
:SCH
chain http://\${next-server}/cgi-bin/boot_manager.sh?cmd=config_host&mac=\${mac:hexraw}&hosttype=SCH || goto no_chain_config
:CCH
chain http://\${next-server}/cgi-bin/boot_manager.sh?cmd=config_host&mac=\${mac:hexraw}&hosttype=CCH || goto no_chain_config

:no_chain_config
echo No chained config found for \${host_type}

:local
sanboot --no-describe --drive 0x80

:reboot
reboot

EOF

}

install_rocky () {

ipxe_header

cat <<EOF

set base-url http://\${next-server}/distros/rocky/9/x86_64

kernel ${base-url}/images/pxeboot/vmlinuz \
  inst.stage2=${base-url} \
  inst.ks= http://\${next-server}/cgi-bin/kickstart.sh?mac=\${mac:hexraw} \
  ip=dhcp \
  console=ttyS0,115200n8

initrd ${base-url}/images/pxeboot/initrd.img
boot

EOF

}

