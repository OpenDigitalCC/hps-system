#!/bin/bash
# ctrl-exec-auth-hook.sh - HPS authorisation hook for ctrl-exec-api on the IPS.
#
# Installed by ce_api_bring_up as $CTRL_EXEC_DISPATCHER_CONF_DIR/auth-hook-hps
# and named by `auth_hook =` in ctrl-exec.conf. Called by ctrl-exec-api, and by
# ced (the dispatcher CLI), before every request with the context in ENVEXEC_*
# variables (see ctrl-exec's auth-hook.example).
#
#   Since ctrl-exec 0.14.7 the dispatcher tells the hook who is asking:
#   ENVEXEC_CALLER (cli = ced, api = a request the API serves) and
#   ENVEXEC_LISTENER (for an API caller unix, tcp or tls; empty for ced). Both
#   are set by ctrl-exec's code path, never from the request. Policy on the IPS:
#
#   1. a caller on the API's unix socket (ENVEXEC_SOURCE_IP "unix:..."): only
#      root may act (ENVEXEC_PEER_UID 0; the root job runner hps-jobs and
#      hps-run.sh). The web user (www-data) never reaches the socket at all
#      (api_socket_group = ctrl-exec); this is the second line;
#   2. ced (ENVEXEC_CALLER=cli), which only a holder of dispatcher.key (root,
#      ctrl-exec) can run: allowed;
#   3. an API caller on the TLS listener (ENVEXEC_CALLER=api,
#      ENVEXEC_LISTENER=tls): the API listens on TCP only when the cluster
#      key operator_api_listen is set (TLS, one address of the IPS;
#      ce_operator_api_configure). An operator call must arrive on tls; an API
#      caller on any other listener (plain tcp) is denied. Such a caller
#      must present an operator credential (the request token) that
#      hps-operator issued and has not revoked: its SHA-256 is in hps-operators beside this hook. An operator
#      may then
#        - pass the API's pre-route check (action api),
#        - ping the IPS's own agent,
#        - run an ips-admin script on the IPS's own agent,
#      where the agent name and the script names come from hps-operator.conf
#      beside this hook (ce_ips_agent_write_config). Never a node agent, never
#      another script, never two hosts, never a stored result (status). Every
#      operator run is logged: who, from where, the script and its arguments
#      (never the input: ctrl-exec gives hooks only its field names);
#   4. everything else is denied and logged.
#
# An older dispatcher sets neither variable (ENVEXEC_CALLER absent). The hook
# then fails closed for operators: no TCP caller is ever treated as an operator,
# so remote operator access does not work (ce_api_bring_up keeps the operator API
# off for ctrl-exec < 0.14.7). HPS's own callers keep working: the unix socket
# (root) as above, and ced, recognised as before by its parent process, which
# is not the API's request handler (the only use left of /proc, for this case).
#
# Exit 0 = authorised; 1 denied, 2 bad credentials, 3 insufficient privilege
# (ctrl-exec's codes). Fail closed.
set -u
action="${ENVEXEC_ACTION:-}"
script="${ENVEXEC_SCRIPT:-}"
hosts="${ENVEXEC_HOSTS:-}"
src="${ENVEXEC_SOURCE_IP:-}"
uid="${ENVEXEC_PEER_UID:-}"
token="${ENVEXEC_TOKEN:-}"
user="${ENVEXEC_USERNAME:-}"
caller="${ENVEXEC_CALLER:-}"
listener="${ENVEXEC_LISTENER:-}"
args_json="${ENVEXEC_ARGS_JSON:-[]}"

HOOK_DIR="${0%/*}"
OPERATORS="${HOOK_DIR}/hps-operators"
OPCONF="${HOOK_DIR}/hps-operator.conf"

# The username is the caller's own claim: shown, never trusted.
user="${user//[^A-Za-z0-9_.@-]/?}"

deny() {
  logger -t hps-auth-hook -p auth.warning "DENY action=${action} script=${script} hosts=${hosts} source=${src} peer_uid=${uid:-none}${2:+ $2}: $3"
  exit "$1"
}

# parent_is_api: the process that ran this hook is ctrl-exec-api. Used only when
# the dispatcher is older than 0.14.7 and sets no ENVEXEC_CALLER.
parent_is_api() {
  local cmdline=""
  if [[ -r "/proc/${PPID}/cmdline" ]]; then
    cmdline=$(tr '\0' ' ' < "/proc/${PPID}/cmdline" 2> /dev/null) || cmdline=""
  fi
  [[ -z "$cmdline" || "$cmdline" == *ctrl-exec-api* ]]
}

# conf_value <key>: one "key = value" line of hps-operator.conf.
conf_value() {
  awk -v k="$1" -F '=' '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$OPCONF"
}

operator_check() {
  [[ -r "$OPCONF" ]] || deny 1 "" "TCP caller, and no operator configuration (no IPS agent yet)"
  [[ -r "$OPERATORS" ]] || deny 2 "" "TCP caller, and no operator credential has been issued"
  [[ "$token" =~ ^[A-Za-z0-9_-]{32,128}$ ]] || deny 2 "" "TCP caller without an operator credential"
  local hash name ips_agent scripts s ok=0
  hash=$(printf '%s' "$token" | sha256sum)
  hash="${hash%% *}"
  name=$(awk -v h="$hash" '$1 !~ /^#/ && $2 == h { print $1; exit }' "$OPERATORS")
  [[ "$name" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || deny 2 "" "unknown or revoked operator credential"
  ips_agent=$(conf_value ips_agent)
  scripts=$(conf_value scripts)
  [[ -n "$ips_agent" ]] || deny 1 "operator=${name}" "no IPS agent named in hps-operator.conf"
  case "$action" in
    api)
      exit 0 ;;
    ping)
      [[ "$hosts" == "$ips_agent" ]] || deny 3 "operator=${name}" "an operator reaches only ${ips_agent}"
      logger -t hps-auth-hook -p auth.info "OPERATOR ping operator=${name} source=${src} user=${user} hosts=${hosts}"
      exit 0 ;;
    run)
      [[ "$hosts" == "$ips_agent" ]] || deny 3 "operator=${name}" "an operator runs only on ${ips_agent}; nodes are driven through the IPS tools"
      for s in $scripts; do
        if [[ "$s" == "$script" ]]; then
          ok=1
        fi
      done
      [[ $ok -eq 1 ]] || deny 3 "operator=${name}" "${script} is not an ips-admin script"
      logger -t hps-auth-hook -p auth.notice "OPERATOR run operator=${name} source=${src} user=${user} agent=${hosts} script=${script} args=${args_json:0:1024}"
      exit 0 ;;
    *)
      deny 3 "operator=${name}" "action ${action} is not open to operators" ;;
  esac
}

case "$src" in
  unix:*)
    [[ "$uid" =~ ^[0-9]+$ ]] || deny 1 "" "no peer uid"
    [[ "$uid" -eq 0 ]] || deny 1 "" "peer uid is not root"
    logger -t hps-auth-hook -p auth.info "ALLOW action=${action} script=${script} hosts=${hosts} peer_uid=${uid}"
    exit 0 ;;
esac

case "$caller" in
  cli)
    # ced (the CLI), which only a holder of dispatcher.key (root, ctrl-exec)
    # can run.
    logger -t hps-auth-hook -p auth.info "ALLOW cli action=${action} script=${script} hosts=${hosts} source=${src}"
    exit 0 ;;
  api)
    # An operator call arrives on the TLS listener and nowhere else. (The unix
    # socket was handled above; a plain tcp listener is not offered.)
    [[ "$listener" == "tls" ]] || deny 1 "" "API caller on listener '${listener:-none}'; operator calls must arrive on tls"
    operator_check ;;
  "")
    # No ENVEXEC_CALLER: a dispatcher older than 0.14.7. Fail closed for
    # operators; keep ced working as before.
    if ! parent_is_api; then
      logger -t hps-auth-hook -p auth.info "ALLOW cli (no ENVEXEC_CALLER) action=${action} script=${script} hosts=${hosts} source=${src}"
      exit 0
    fi
    deny 1 "" "no ENVEXEC_CALLER (ctrl-exec older than 0.14.7): operator access refused" ;;
  *)
    deny 1 "" "unknown caller '${caller}'" ;;
esac
