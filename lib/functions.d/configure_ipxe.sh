
__guard_source || return
# Define your functions below


configure_ipxe () {
  local output_file="${HPS_MENU_CONFIG_DIR}/boot.ipxe"
  local server_ip="${DHCP_IP}"

  mkdir -p "$(dirname "$output_file")"

  cat > "$output_file" <<EOF
#!ipxe

# Automatically configure network
dhcp
set client_ip \${net0/ip}
echo Detected client IP: \${client_ip}

# Set server IP (injected by HPS config)
set server_ip ${server_ip}

# Normalize MAC address
set mac:hexraw \${mac:hexraw:~2}

# Attempt to fetch host-specific config
set config_url http://\${server_ip}/hosts/\${mac:hexraw}.conf
echo Config URL: \${config_url}

imgfetch --name config \${config_url} || goto no_config
imgload config
imgstat
imgexec config

:no_config
echo No host config found for MAC: \${mac:hexraw}
echo Waiting
sleep 5
goto main_menu

:main_menu
menu Select a host configuration option:
item TCH Thin Compute Host
item SCH Storage Cluster Host
item DRH Disaster Recovery Host
item CCH Container Cluster Host
item local Boot from local disk
item reboot Reboot

choose --default local --timeout 10000 hosttype && goto \${hosttype}

:TCH
chain http://\${server_ip}/cgi-bin/menu.sh?mac=\${mac:hexraw}&hosttype=TCH
:DRH
chain http://\${server_ip}/cgi-bin/menu.sh?mac=\${mac:hexraw}&hosttype=DRH
:SCH
chain http://\${server_ip}/cgi-bin/menu.sh?mac=\${mac:hexraw}&hosttype=SCH
:CCH
chain http://\${server_ip}/cgi-bin/menu.sh?mac=\${mac:hexraw}&hosttype=CCH

:local
sanboot --no-describe --drive 0x80

:reboot
reboot
EOF

  echo "[OK] boot.ipxe written to $output_file"
}

