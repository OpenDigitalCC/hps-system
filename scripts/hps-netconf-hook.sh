#!/usr/bin/env bash
#===============================================================================
# hps-netconf-hook.sh <mac>
# -------------------------
# Network configuration step of `hps-onboard assign`. hps-onboard runs this as
# $HPS_ONBOARD_NETCONF_CMD <mac> (a program path, no shell) before it writes
# STATE=NETWORK_BOOT.
#
# host_network_configure allocates IP and hostname, writes IP, NETMASK,
# HOSTNAME, TYPE and STATE=CONFIGURED, and itself runs host_post_config_hooks
# (DHCP/DNS rebuild), so nothing more is called here. TYPE may be a comma list
# (SCH,TCH): it is stored as given and the first element names the host.
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system.
#===============================================================================
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "usage: hps-netconf-hook.sh <mac>" >&2
  exit 2
fi

HPS_BASE="${HPS_BASE:-/srv}"
SYSTEM_PATH="${HPS_SYSTEM_PATH:-${HPS_BASE}/hps-system}"
export HPS_BASE

if [[ ! -f "${SYSTEM_PATH}/lib/functions.sh" ]]; then
  echo "hps-netconf-hook: function library not found: ${SYSTEM_PATH}/lib/functions.sh" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${SYSTEM_PATH}/lib/functions.sh"

hps_log info "[$1] netconf hook: host_network_configure"
host_network_configure "$1"
