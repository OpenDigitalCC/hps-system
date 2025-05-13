#!/bin/bash
set -euo pipefail

# read HPS config
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

# Retrieve config file name of the cluster
CLUSTER_FILE=$(get_active_cluster_filename) || {
  cgi_fail "No active cluster"
  exit 1
}


# read the cluster config
source "$CLUSTER_FILE"

# Send the initial header to PXE client
#cgi_header_plain

# Set a banner for the mmenu
CLUSTER_HEADER="${CLUSTER_NAME:-Unknown} - ${NAME:-Unnamed Cluster}"

#mac=$(get_param "mac")
#hosttype=\$(get_param "hosttype")

#[[ -z "$mac" || -z "\$hosttype" ]] && {
#  cgi_fail "Missing required parameters"
#  exit 1
#}

# Optional: normalize MAC
# mac=$(normalise_mac "$mac") || { cgi_fail "Invalid MAC format"; exit 1; }

# if no params, run first_boot which will call this script asking for the config file

if ! cgi_param exists cmd
 then
  cgi_fail "Command not specified"
fi

if cgi_param equals cmd firstboot
 then
  hps_log info "First boot requested"
  ipxe_first_boot
  exit
fi

if ! cgi_param exists mac
 then
  cgi_fail "mac address not provided"
fi

if host_config equals STATE INSTALLED
 then
#  [[ has_sch_host ]] !! cgi_fail "Cluster $(cluster_config get CLUSTER_NAME) has no storage nodes configured, can't continue"
  cgi_fail "INSTALLED section not written yet"
  # boot the host from iscsi 
fi


if cgi_param equals cmd get_config
 then
  HOST_CONFIG_FILE=${HPS_HOST_CONFIG_DIR}/$(cgi_param get mac).conf
  hps_log info "[$(cgi_param get mac)]  Config requested: ${HOST_CONFIG_FILE}"  
  if [[ ! -f ${HOST_CONFIG_FILE} ]]
   then
    # initailise the config file
    hps_log info "[$(cgi_param get mac)]  Running host_initialise_config"
    host_initialise_config $(cgi_param get mac)
    exit
  fi

  if host_config equals STATE CONFIGURED
   then
    [[ has_sch_host ]] || cgi_fail "Cluster $(cluster_config get CLUSTER_NAME) has no storage nodes configured, can't continue"
    hps_log info "[$(cgi_param get mac)] Delivering CONFIGURED file state: $(host_config get STATE)"
    # deliver the ipxe config to install tie o/s
    cgi_fail "CONFIGURED section not yet written"
   else
     ipxe_config_menu
     hps_log info "[$(cgi_param get mac)] State: $(host_config get STATE), running config menu"
     exit
  fi
  elif cgi_param equals cmd config_host
   then
   # run the menu-based autoconfig for this host type
   host_config set TYPE $(cgi_param get hosttype)
   hps_log info "[$(cgi_param get mac)] config_host requested for type $(cgi_param get hosttype)"
  fi
fi


cgi_fail "Command not specified for $(cgi_param get mac)"



