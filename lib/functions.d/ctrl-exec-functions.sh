# shellcheck shell=bash
# ctrl-exec-functions.sh
#
# IPS-side integration with ctrl-exec (mTLS remote script execution).
# See docs/adr/0001-orchestration-split.md, 0002-ctrl-exec-enrolment-trust.md.
#
# This library runs on the IPS, alongside the ctrl-exec dispatcher and its CA.
# It provides:
#   - ce_pairing_window_open / _close : bound the pairing listener to a
#     provisioning window
#   - ce_approve_pair_request         : registry-bound auto-approval of a
#     node's pairing request (the core enrolment trust decision)
#   - ce_run                          : run an allowlisted script on a paired
#     node over mTLS
#
# The dispatcher CLI is ctrl-exec-dispatcher (aliased 'ced' upstream). We call
# the binary by its full name so no shell alias is required.

# Full path to the dispatcher CLI; overridable for tests.
: "${CTRL_EXEC_DISPATCHER:=ctrl-exec-dispatcher}"
# Where the dispatcher queues pending pairing requests (Exec::Pairing
# $PAIRING_DIR). Overridable for tests.
: "${CTRL_EXEC_PAIRING_DIR:=/var/lib/ctrl-exec/pairing}"
# Default pairing window, seconds. Matches the agent's
# request-pairing --background --timeout in ctrl-exec.init.
: "${CTRL_EXEC_PAIR_WINDOW:=300}"

#===============================================================================
# ce_pairing_window_open
# ----------------------
# Open the dispatcher's pairing listener (port 7444) for a bounded window so
# provisioning nodes can submit CSRs. Auto-stops after the window (the
# dispatcher enforces its own max, currently 600s).
#
# Arguments:
#   $1 - timeout seconds (optional, default CTRL_EXEC_PAIR_WINDOW)
#
# Returns: 0 on success, non-zero on dispatcher error.
#===============================================================================
ce_pairing_window_open() {
  local timeout="${1:-$CTRL_EXEC_PAIR_WINDOW}"

  if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    hps_log error "ce_pairing_window_open: timeout must be numeric: $timeout"
    return 1
  fi

  hps_log info "Opening ctrl-exec pairing window for ${timeout}s"
  "$CTRL_EXEC_DISPATCHER" pairing-mode start --timeout "$timeout" || {
    hps_log error "Failed to start ctrl-exec pairing mode"
    return 1
  }
  return 0
}

#===============================================================================
# ce_pairing_window_close
# -----------------------
# Close the pairing listener before its timeout (e.g. once the expected nodes
# have paired).
#
# Returns: 0 on success, non-zero on dispatcher error.
#===============================================================================
ce_pairing_window_close() {
  hps_log info "Closing ctrl-exec pairing window"
  "$CTRL_EXEC_DISPATCHER" pairing-mode stop || {
    hps_log error "Failed to stop ctrl-exec pairing mode"
    return 1
  }
  return 0
}

#===============================================================================
# _ce_read_pair_request
# ----------------------
# Read a queued pairing request record by reqid. Emits the raw JSON on stdout.
# The dispatcher stores one file per request; list-requests has no JSON mode,
# so we read the file directly (the approver runs on the IPS where the
# dispatcher's state lives).
#
# Arguments:
#   $1 - reqid
#
# Returns: 0 and prints JSON if found; 1 if absent.
#===============================================================================
_ce_read_pair_request() {
  local reqid="$1"
  local req_file="${CTRL_EXEC_PAIRING_DIR}/${reqid}.json"

  if [[ ! -f "$req_file" ]]; then
    return 1
  fi
  cat -- "$req_file"
}

#===============================================================================
# ce_approve_pair_request
# -----------------------
# Registry-bound auto-approval. Approves a node's pairing request ONLY when
# every binding check ties the request to a node HPS is actively provisioning
# (see ADR 0002). This replaces the MAC-only OpenSVC join-token path.
#
# Arguments:
#   $1 - mac   : reporting node's MAC (from the authenticated API caller)
#   $2 - reqid : pairing request id the node reported
#
# Checks (all must pass):
#   1. Host registry entry exists for MAC and STATE is enrolment-eligible.
#   2. Pairing request exists and its hostname + IP match the registry
#      allocation.
#   3. No prior approval this provisioning cycle (ctrl_exec_paired unset).
#
# Returns:
#   0  approved (records ctrl_exec_paired=<epoch>)
#   1  denied (reason logged)
#   2  usage / internal error
#===============================================================================
ce_approve_pair_request() {
  local mac="${1:?Usage: ce_approve_pair_request <mac> <reqid>}"
  local reqid="${2:?Usage: ce_approve_pair_request <mac> <reqid>}"

  # reqid is agent-derived; constrain to the dispatcher's charset before it
  # reaches a file path or the CLI.
  if [[ ! "$reqid" =~ ^[a-f0-9]+$ ]]; then
    hps_log error "ce_approve: malformed reqid from ${mac}: ${reqid}"
    return 1
  fi

  # Check 1: known host in an enrolment-eligible state.
  local state
  state=$(host_registry "$mac" get STATE 2>/dev/null) || {
    hps_log error "ce_approve: no registry entry for ${mac}"
    return 1
  }
  case "$state" in
    INSTALLING|CONFIGURING) ;;
    *)
      hps_log error "ce_approve: ${mac} STATE '${state}' not enrolment-eligible"
      return 1
      ;;
  esac

  # Check 3 (cheap, do before reading files): one approval per cycle.
  local already
  already=$(host_registry "$mac" get ctrl_exec_paired 2>/dev/null) || already=""
  if [[ -n "$already" ]]; then
    hps_log error "ce_approve: ${mac} already paired this cycle (${already})"
    return 1
  fi

  # Check 2: request exists and binds to this host's allocation.
  local req_json
  req_json=$(_ce_read_pair_request "$reqid") || {
    hps_log error "ce_approve: no pending request ${reqid} for ${mac}"
    return 1
  }

  local req_hostname req_ip
  req_hostname=$(printf '%s' "$req_json" | jq -r '.hostname // ""')
  # source_ip is the connection peer; ip is the agent's self-reported address.
  # Require the peer IP to match the allocation - the self-reported field is
  # attacker-controlled, the peer address is not.
  req_ip=$(printf '%s' "$req_json" | jq -r '.source_ip // ""')

  local reg_hostname reg_ip
  reg_hostname=$(host_registry "$mac" get HOSTNAME 2>/dev/null) || reg_hostname=""
  reg_ip=$(host_registry "$mac" get IP 2>/dev/null) || reg_ip=""

  if [[ -z "$reg_ip" ]]; then
    hps_log error "ce_approve: ${mac} has no allocated IP; cannot bind request"
    return 1
  fi
  if [[ "$req_ip" != "$reg_ip" ]]; then
    hps_log error "ce_approve: ${mac} request IP '${req_ip}' != allocated '${reg_ip}'"
    return 1
  fi
  # Hostname is advisory: only enforce when the registry has one recorded.
  if [[ -n "$reg_hostname" && "$req_hostname" != "$reg_hostname" ]]; then
    hps_log error "ce_approve: ${mac} request hostname '${req_hostname}' != '${reg_hostname}'"
    return 1
  fi

  # All bindings satisfied - approve, keyed to the request's own IP.
  hps_log info "ce_approve: approving ${reqid} for ${mac} (${reg_hostname:-$req_hostname} @ ${reg_ip})"
  if ! "$CTRL_EXEC_DISPATCHER" approve "$reqid" --ip "$reg_ip"; then
    hps_log error "ce_approve: dispatcher approve failed for ${reqid}"
    return 1
  fi

  host_registry "$mac" set ctrl_exec_paired "$(date +%s)" || {
    hps_log warn "ce_approve: approved ${reqid} but failed to record ctrl_exec_paired for ${mac}"
  }
  return 0
}

#===============================================================================
# ce_run
# ------
# Run an allowlisted script on a paired node over mTLS. Thin wrapper over the
# dispatcher; the node's scripts.conf allowlist is the authorisation surface.
#
# Arguments:
#   $1  - host   : agent hostname (as registered at pairing)
#   $2  - script : allowlisted script name (e.g. hps-node)
#   $@  - args   : remaining args passed after '--' to the script
#
# Returns: the dispatcher's exit status (0 all-ok).
#===============================================================================
ce_run() {
  local host="${1:?Usage: ce_run <host> <script> [args...]}"
  local script="${2:?Usage: ce_run <host> <script> [args...]}"
  shift 2

  if (( $# > 0 )); then
    "$CTRL_EXEC_DISPATCHER" run "$host" "$script" -- "$@"
  else
    "$CTRL_EXEC_DISPATCHER" run "$host" "$script"
  fi
}
