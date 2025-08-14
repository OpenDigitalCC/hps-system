#!/bin/bash
set -euo pipefail

# read HPS config
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/functions.sh"

#client_ip="${REMOTE_ADDR:-}"
mac="$(get_client_mac "${REMOTE_ADDR}")"
#mac="$(get_request_mac)"


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
  hps_log info "Initialisation requested from DHCP"
  ipxe_init
  exit
fi

### ───── Get the MAC or fail ─────


# Condition: do we have $mac
# Ensure $mac is set from CGI param or fallback

# TODO: Remove this section as it is redundant, as MAC is derived from IP
#if [[ -z "${mac:-}" ]]; then
#  if cgi_param exists mac; then
#    mac="$(cgi_param get mac)"
#  else
#    ipxe_cgi_fail "MAC address is required for command $cmd"
#    exit 1
#  fi
#fi


#if ! cgi_param exists mac; then
#  ipxe_cgi_fail "MAC address is required for command $cmd"
#  exit
#else
#  mac="$(cgi_param get mac)"
#fi

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
  host_config "$mac" set STATE "$SET_STATUS"
  cgi_success "$mac set to $SET_STATUS"
  exit
fi



# Command: get or set host variables
if [[ "$cmd" == "host_variable" ]]
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

# --- Command: get or set host variables (receiver side) ---
# cmd=host_variable&name=<name>[&value=<value>]
# - Requires: name
# - If 'value' param exists (even empty) -> set name=value, return success
# - If 'value' param missing            -> get current value, return it
if [[ "$cmd" == "host_variable" ]]; then
  # Require 'name'
  if ! cgi_param exists name; then
    ipxe_cgi_fail "Param 'name' is required for command $cmd"
    exit
  fi

  name="$(cgi_param get name)"

  if cgi_param exists value; then
    # SET path (value may be empty; presence of param triggers set)
    value="$(cgi_param get value)"
    if host_config "$mac" set "$name" "$value"; then
      cgi_success "$mac set $name to $value"
    else
      ipxe_cgi_fail "Failed to set $name for $mac"
    fi
  else
    # GET path
    if host_config "$mac" exists "$name"; then
      val="$(host_config "$mac" get "$name")"
      # Return raw value as payload (cgi_success wraps it)
      cgi_success "$val"
    else
      ipxe_cgi_fail "Key '$name' not found for $mac"
    fi
  fi
  exit
fi



# Command: Process ipxe menu

if [[ "$cmd" == "process_menu_item" ]]; then
  if ! cgi_param exists menu_item; then
    ipxe_cgi_fail "Missing required parameter: menu_item"
    exit
  fi
  menu_item="$(cgi_param get menu_item)"
  hps_log info "Processing ipxe menu item: $menu_item"
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
  hps_log info "$LOG_MESSAGE"
  exit
fi


# Command: Network bootstrap via kickstart
if [[ "$cmd" == "kickstart" ]]; then
  if ! cgi_param exists hosttype; then
    ipxe_cgi_fail "Param hosttype is required for kickstart"
  fi
  hosttype="$(cgi_param get hosttype)"
  hps_log info "Kickstart - Configuring host $hosttype"
  host_network_configure "$mac" "$hosttype"
  generate_ks "$mac" "$hosttype"
  exit
fi

# Command: Determine current state
if [[ "$cmd" == "determine_state" ]]; then
  hps_log info "Host wants to know its state"
  state="$(host_config "$mac" get STATE)"
  hps_log info "State: $state"
  cgi_success "$state"
  exit
fi


# get the host config file

if [[ "$cmd" == "host_get_config" ]]; then
  hps_log info "Config requested"
  cgi_header_plain
  host_config_show $mac
  exit
fi

# Command: Configure this host

if [[ "$cmd" == "config_host" ]]; then
  if ! cgi_param exists hosttype; then
    ipxe_cgi_fail "hosttype is required for config_host"
  fi
  hosttype="$(cgi_param get hosttype)"
  host_config "$mac" set TYPE "$hosttype"
  exit
fi

# Command: get the distro bootsrtap script

if [[ "$cmd" == "bootstrap_initialise_distro" ]]; then
  hps_log info "Bootstrap config requested"
  cgi_header_plain
  bootstrap_initialise_distro "$mac"
  exit
fi


# Command: get the host script library

if [[ "$cmd" == "initialise_host_scripts" ]]; then
  hps_log info "distro script lib requested"
  cgi_header_plain
  if cgi_param exists distro; then
    initialise_host_scripts "$(cgi_param get distro)"
  else
    ipxe_cgi_fail "$cmd: Parameter distro not provided"
  fi
  exit
fi


# Command: Generate an opensvc conf
if [[ "$cmd" == "generate_opensvc_conf" ]]; then
  hps_log info "Request to generate opensvc.conf"
  cgi_header_plain
  generate_opensvc_conf "$mac"
  exit
fi


# ----------------------

# Router: Decide what to do next
if [[ "$cmd" == "boot_action" ]]
 then
  hps_log info "Host wants to know what to do next"
  if host_config_exists "$mac"
   then
    hps_log info "Found config"
   else
    hps_log info "No config found, initialising"
    host_initialise_config "$mac"
  fi
  state="$(host_config "$mac" get STATE)"
  hps_log info "STATE: $state"

  case "$state" in
    UNCONFIGURED)
      hps_log info "Unconfigured — offering install options."
      ipxe_configure_main_menu
      ;;

    CONFIGURED)
      hps_log info "Configured — offering install options."
      # establish type and o/s from config and cluster, then go to install that
      ipxe_host_install_menu
      ;;

    INSTALLED)
      hps_log info "Already installed. Booting from disk."
      ipxe_boot_from_disk
      exit
      ;;

    UNMANAGED)
      hps_log info "Device set to UNMANAGED, booting from disk"
      ipxe_boot_from_disk
      exit
      ;;

    INSTALLING)
      hps_log info "Currently installing. Continuing install."
      HTYPE=$(host_config "$mac" get TYPE)
      hps_log debug "[$mac] Installing TYPE: $HTYPE"
      ipxe_boot_installer "$HTYPE" ""
      ;;

    ACTIVE)
#      hps_log info "Active and provisioned. Booting configured image."
#      ipxe_boot_provisioned
      ipxe_cgi_fail "Section not yet written for state $state"
      ;;

    REINSTALL)
#      hps_log info "Reinstall requested. Returning to install menu."
#      ipxe_host_install_menu
      host_config "$mac" set STATE UNCONFIGURED
      ipxe_init
      ;;

    FAILED)
      hps_log info "Install failed"
      ipxe_configure_main_menu
#      ipxe_cgi_fail "Installation marked as FAILED"
    ;;

    *)
      hps_log info "Unknown or unset state. Failing.."
      ipxe_cgi_fail "State $state unknown or unhandled"
      ;;
  esac

  exit
fi




### ───── Unknown or unhandled command ─────

ipxe_cgi_fail "Unknown or unsupported command: $cmd"



