#!/bin/bash
# ctrl-exec-auth-hook.sh - HPS authorisation hook for ctrl-exec-api on the IPS.
#
# Installed by ce_api_bring_up as $CTRL_EXEC_DISPATCHER_CONF_DIR/auth-hook-hps
# and named by `auth_hook =` in ctrl-exec.conf. Called by ctrl-exec-api before
# every request with the context in ENVEXEC_* variables (see ctrl-exec's
# auth-hook.example). Policy on the IPS:
#
#   - the API's TCP listener is off (api_port = off, set by ce_api_bring_up):
#     API callers exist only on the unix socket (ENVEXEC_SOURCE_IP "unix:…");
#   - a request with no unix peer is therefore ced (CLI), which only a holder
#     of dispatcher.key (root, ctrl-exec) can run: allowed;
#   - only the root job runner (hps-jobs) may act: ENVEXEC_PEER_UID must be 0.
#     The web user (www-data) never reaches the socket at all
#     (api_socket_group = ctrl-exec), this is the second line;
#   - everything else is denied and logged.
#
# Exit 0 = authorised, non-zero = denied (fail closed).
set -u
action="${ENVEXEC_ACTION:-}"
script="${ENVEXEC_SCRIPT:-}"
hosts="${ENVEXEC_HOSTS:-}"
src="${ENVEXEC_SOURCE_IP:-}"
uid="${ENVEXEC_PEER_UID:-}"

deny() {
  logger -t hps-auth-hook -p auth.warning "DENY action=${action} script=${script} hosts=${hosts} source=${src} peer_uid=${uid:-none}: $1"
  exit 1
}

case "$src" in
  unix:*) ;;
  *)
    # Not a unix-socket caller. The API's TCP listener is off on the IPS
    # (api_port = off), so this is ced (CLI), which only a holder of
    # dispatcher.key (root, ctrl-exec) can run; ced reports 127.0.0.1.
    logger -t hps-auth-hook -p auth.info "ALLOW cli action=${action} script=${script} hosts=${hosts} source=${src}"
    exit 0 ;;
esac
[[ "$uid" =~ ^[0-9]+$ ]] || deny "no peer uid"
[[ "$uid" -eq 0 ]] || deny "peer uid is not root"

logger -t hps-auth-hook -p auth.info "ALLOW action=${action} script=${script} hosts=${hosts} peer_uid=${uid}"
exit 0
