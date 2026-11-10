#!/usr/bin/env bash
#===============================================================================
# hps-forget-hook.sh agents | agent <name> | dns-dhcp
# ---------------------------------------------------
# The IPS-side steps of `hps-onboard forget` and `hps-onboard prune-agents`.
# hps-onboard runs this as $HPS_ONBOARD_FORGET_CMD <verb> [name] (a program
# path, no shell), the same way as hps-netconf-hook.sh.
#
#   agents        print the names of the agents registered with the dispatcher,
#                 one per line (ce_agent_names)
#   agent <name>  unregister that agent (ce_unpair_agent). Exit 0 removed, 4 no
#                 such agent, 1 failed. Needs root.
#   dns-dhcp      regenerate the DHCP reservations and DNS entries and reload
#                 dnsmasq (update_dns_dhcp_files, the same call as after a host
#                 is configured). IPS-10 owns that generation and may change it.
#
# Environment: HPS_BASE (default /srv); HPS_SYSTEM_PATH overrides
# $HPS_BASE/hps-system; CTRL_EXEC_DISPATCHER names the dispatcher CLI.
#===============================================================================
set -euo pipefail

usage() {
  echo "usage: hps-forget-hook.sh agents | agent <name> | dns-dhcp" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

HPS_BASE="${HPS_BASE:-/srv}"
SYSTEM_PATH="${HPS_SYSTEM_PATH:-${HPS_BASE}/hps-system}"
export HPS_BASE

if [[ ! -f "${SYSTEM_PATH}/lib/functions.sh" ]]; then
  echo "hps-forget-hook: function library not found: ${SYSTEM_PATH}/lib/functions.sh" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${SYSTEM_PATH}/lib/functions.sh"

verb="$1"
case "$verb" in
  agents)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    ce_agent_names
    ;;
  agent)
    [[ $# -eq 2 && -n "$2" ]] || { usage; exit 2; }
    ce_unpair_agent "$2"
    ;;
  dns-dhcp)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    hps_log info "forget: regenerating DHCP and DNS files"
    update_dns_dhcp_files
    ;;
  *)
    usage
    exit 2
    ;;
esac
