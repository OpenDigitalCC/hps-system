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

if cgi_param equals cmd mark_installed
 then
  host_config "$mac" set STATE INSTALLED
  exit
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

## We have a mac address, so lets get on with config

mac=$(cgi_param get mac)


if host_config $mac equals STATE INSTALLED
 then
#  [[ has_sch_host ]] !! cgi_fail "Cluster $(cluster_config get CLUSTER_NAME) has no storage nodes configured, can't continue"
  ipxe_boot_from_disk
  # boot the host from iscsi 
fi


if cgi_param equals cmd kickstart
 then
  TYPE=$(cgi_param get hosttype)
  hps_log info "[$mac] Auto-configuring host network"
  host_network_configure $mac $TYPE
  cgi_header_plain
  generate_ks "$mac" "$TYPE"
fi


if cgi_param equals cmd get_config
 then
  HOST_CONFIG_FILE=${HPS_HOST_CONFIG_DIR}/$mac.conf
  hps_log info "[$mac]  Config requested: ${HOST_CONFIG_FILE}"  
  if [[ ! -f ${HOST_CONFIG_FILE} ]]
   then
    # initialise the config file
    hps_log info "[$mac]  Running host_initialise_config"
    host_initialise_config $mac
    exit
  fi

  if host_config $mac equals STATE CONFIGURED
   then
#    [[ has_sch_host ]] || cgi_fail "Cluster $(cluster_config get CLUSTER_NAME) has no storage nodes configured, can't continue"
    hps_log info "[$mac] Delivering CONFIGURED file state: $(host_config $mac get STATE)"
    # deliver the ipxe config to install tie o/s
     ipxe_config_menu
     hps_log info "[$mac] State: $(host_config $mac get STATE), running config menu"
     exit
  fi
  elif cgi_param equals cmd config_host
   then
   # run the menu-based autoconfig for this host type
   host_config $mac set TYPE $(cgi_param get hosttype)
   hps_log info "[$mac] config_host requested for type $(cgi_param get hosttype)"
  fi
fi


cgi_fail "Command not specified for $mac"



