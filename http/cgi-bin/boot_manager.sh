#!/bin/bash
set -euo pipefail

# read HPS config
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

# Retrieve config file name of the cluster
CLUSTER_FILE=$(get_active_cluster_filename) || {
  ipxe_cgi_fail "No active cluster"
  exit 1
}

### ───── Ensure command is present else fail fast ─────

# Condition: do we have $cmd
if ! cgi_param exists cmd; then
  ipxe_cgi_fail "Command not specified"
  exit
else
  cmd="$(cgi_param get cmd)"
fi

### ───── Commands that do NOT require a MAC ─────

# Condition: is this fresh boot?
if [[ "$cmd" == "init" ]]; then
  hps_log info "[CGI] Initialisation requested from DHCP"
  ipxe_init
  exit
fi

### ───── Get the MAC or fail ─────

# Condition: do we have $mac
if ! cgi_param exists mac; then
  ipxe_cgi_fail "MAC address is required for command $cmd"
  exit
else
  mac="$(cgi_param get mac)"
fi

### ───── Commands that require a MAC ─────


# Command: set status
if [[ "$cmd" == "set_status" ]]
 then
  if ! cgi_param exists status
   then
    ipxe_cgi_fail "Param status is required for command $cmd"
    exit
  else
    SET_STATUS="$(cgi_param get status)"
  fi
  host_config "$mac" set STATE $SET_STATUS
  cgi_success "$mac set to $SET_STATUS"
  exit
fi


# Command: set host_name_value
if [[ "$cmd" == "set_host_name_value" ]]
 then
  if ! cgi_param exists name
   then
    ipxe_cgi_fail "Param name is required for command $cmd"
    exit
  else
    name="$(cgi_param get name)"
    value="$(cgi_param get value)"
  fi
  host_config "$mac" set $name $value
  cgi_success "$mac set $name to $value"
  exit
fi


# Command: Process ipxe menu

if [[ "$cmd" == "process_menu_item" ]]; then
  if ! cgi_param exists menu_item; then
    ipxe_cgi_fail "Missing required parameter: menu_item"
    exit
  fi
  menu_item="$(cgi_param get menu_item)"
  hps_log info "[$mac] Processing menu item: $menu_item"
  handle_menu_item "$menu_item" "$mac"
  exit
fi


# Command: write log entry
if [[ "$cmd" == "log_message" ]]
 then
  if ! cgi_param exists message
   then
    ipxe_cgi_fail "Param message is required for command $cmd"
  else
    LOG_MESSAGE="$(cgi_param get message)"
    cgi_header_plain
    echo "Log updated"
  fi
  hps_log info "[$mac] $cmd $LOG_MESSAGE"
  exit
fi


# Command: Network bootstrap via kickstart
if [[ "$cmd" == "kickstart" ]]; then
  if ! cgi_param exists hosttype; then
    ipxe_cgi_fail "Param hosttype is required for kickstart"
  fi
  hosttype="$(cgi_param get hosttype)"
  hps_log info "[$mac] Kickstart - Configuring host $hosttype"
  host_network_configure "$mac" "$hosttype"
  generate_ks "$mac" "$hosttype"
  exit
fi

# Command: Determine current state
if [[ "$cmd" == "determine_state" ]]; then
  hps_log info "[$mac] Host wants to know its state"
  state="$(host_config "$mac" get STATE)"
  hps_log info "[$mac] State: $state"
  cgi_success "$state"
  exit
fi


if [[ "$cmd" == "host_get_config" ]]; then
  hps_log info "[$mac] Config requested"
  cgi_header_plain
  host_config_show $mac
  exit
fi

# ----------------------

# Router: Decide what to do next
if [[ "$cmd" == "boot_action" ]]
 then
  hps_log info "[$mac] Host wants to know what to do next"
  if host_config_exists "$mac"
   then
    hps_log info "[$mac] Found config"
   else
    hps_log info "[$mac] No config found, initialising"
    host_initialise_config "$mac"
  fi
  state="$(host_config "$mac" get STATE)"
  hps_log info "[$mac] STATE: $state"

  case "$state" in
    UNCONFIGURED)
      hps_log info "[$mac] Unconfigured — offering install options."
      ipxe_configure_main_menu
      ;;

    CONFIGURED)
      hps_log info "[$mac] Configured — offering install options."
      # establish type and o/s from config and cluster, then go to install that
      ipxe_host_install_menu
      ;;

    INSTALLED)
      hps_log info "[$mac] Already installed. Booting from disk."
      ipxe_boot_from_disk
      exit
      ;;

    INSTALLING)
      hps_log info "[$mac] Currently installing. Continuing install."
      HTYPE=$(host_config "$mac" get TYPE)
      hps_log debug "[$mac] Installing TYPE: $HTYPE"
      ipxe_boot_installer "$HTYPE" ""
      ;;

    ACTIVE)
#      hps_log info "[$mac] Active and provisioned. Booting configured image."
#      ipxe_boot_provisioned
      ipxe_cgi_fail "Section not yet written for state $state"
      ;;

    REINSTALL)
#      hps_log info "[$mac] Reinstall requested. Returning to install menu."
#      ipxe_host_install_menu
      host_config "$mac" set STATE UNCONFIGURED
      ipxe_init
      ;;

    FAILED)
      hps_log info "[$mac] Install failed"
      ipxe_configure_main_menu
#      ipxe_cgi_fail "Installation marked as FAILED"
    ;;

    *)
      hps_log info "[$mac] Unknown or unset state. Failing.."
      ipxe_cgi_fail "State $state unknown or unhandled"
      ;;
  esac

  exit
fi



### ───── Manual host configuration ─────

# Command: Configure this host
if [[ "$cmd" == "config_host" ]]; then
  if ! cgi_param exists hosttype; then
    ipxe_cgi_fail "hosttype is required for config_host"
  fi
  hosttype="$(cgi_param get hosttype)"
  host_config "$mac" set TYPE "$hosttype"
  exit
fi

### ───── Unknown or unhandled command ─────

ipxe_cgi_fail "Unknown or unsupported command: $cmd"



