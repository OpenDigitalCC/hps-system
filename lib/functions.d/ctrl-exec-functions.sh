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
# Persistent bases on the /srv bind-mount so the CA and pairing/agent state
# survive container image rebuilds. The upstream defaults (/etc/ctrl-exec,
# /var/lib/ctrl-exec) are symlinked here at bring-up.
: "${CTRL_EXEC_PERSIST_CONF:=/srv/ctrl-exec/conf}"
: "${CTRL_EXEC_PERSIST_STATE:=/srv/ctrl-exec/state}"
# Floating dispatcher tarball served from the IPS package repo (see the
# node-side CTRL_EXEC_TARBALL note; the same latest-symlink convention).
: "${CTRL_EXEC_DISPATCHER_TARBALL:=/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz}"

#===============================================================================
# _ce_persist_dir
# ---------------
# Ensure an upstream ctrl-exec path is backed by persistent storage on /srv:
# create the persistent target and symlink the upstream path to it, unless the
# upstream path is already a real (non-symlink) directory with content.
#
# Arguments: $1 persistent target, $2 upstream path
#===============================================================================
_ce_persist_dir() {
  local target="$1" upstream="$2"
  mkdir -p "$target" || return 1
  # Already linked correctly.
  if [[ -L "$upstream" && "$(readlink "$upstream")" == "$target" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$upstream")" || return 1
  # Migrate any existing real directory's content into the persistent target.
  if [[ -d "$upstream" && ! -L "$upstream" ]]; then
    cp -a "$upstream/." "$target/" 2>/dev/null || true
    rm -rf "$upstream"
  fi
  ln -sfn "$target" "$upstream"
}

#===============================================================================
# ce_dispatcher_bring_up
# ----------------------
# Idempotent IPS-side dispatcher bring-up, safe to call on every start:
#   1. Back /etc/ctrl-exec and /var/lib/ctrl-exec with persistent /srv storage.
#   2. Install the dispatcher from the HPS-served tarball if absent.
#   3. Initialise the CA and the dispatcher cert once.
#
# Returns: 0 on success (or already up), non-zero on failure.
#===============================================================================
ce_dispatcher_bring_up() {
  _ce_persist_dir "$CTRL_EXEC_PERSIST_CONF" /etc/ctrl-exec || {
    hps_log error "ce_dispatcher_bring_up: cannot persist /etc/ctrl-exec"
    return 1
  }
  _ce_persist_dir "$CTRL_EXEC_PERSIST_STATE" /var/lib/ctrl-exec || {
    hps_log error "ce_dispatcher_bring_up: cannot persist /var/lib/ctrl-exec"
    return 1
  }

  # Install the dispatcher if the CLI is not on PATH.
  if ! command -v "$CTRL_EXEC_DISPATCHER" >/dev/null 2>&1; then
    if [[ ! -f "$CTRL_EXEC_DISPATCHER_TARBALL" ]]; then
      hps_log error "ce_dispatcher_bring_up: dispatcher tarball missing: $CTRL_EXEC_DISPATCHER_TARBALL"
      return 1
    fi
    local work="/tmp/ce-dispatcher-install.$$"
    mkdir -p "$work" || return 1
    if ! tar -xzf "$CTRL_EXEC_DISPATCHER_TARBALL" -C "$work"; then
      hps_log error "ce_dispatcher_bring_up: cannot unpack dispatcher tarball"
      rm -rf "$work"
      return 1
    fi
    local srcdir
    srcdir="$(find "$work" -maxdepth 1 -type d -name 'ctrl-exec-*' | head -n1)"
    if [[ -z "$srcdir" || ! -x "$srcdir/install.sh" ]]; then
      hps_log error "ce_dispatcher_bring_up: install.sh not found in tarball"
      rm -rf "$work"
      return 1
    fi
    ( cd "$srcdir" && ./install.sh --dispatcher ) || {
      hps_log error "ce_dispatcher_bring_up: dispatcher install failed"
      rm -rf "$work"
      return 1
    }
    rm -rf "$work"
  fi

  # Initialise the CA and dispatcher cert once (persisted under /srv).
  if [[ ! -f /etc/ctrl-exec/ca.crt ]]; then
    hps_log info "ce_dispatcher_bring_up: initialising ctrl-exec CA"
    "$CTRL_EXEC_DISPATCHER" setup-ca || {
      hps_log error "ce_dispatcher_bring_up: setup-ca failed"
      return 1
    }
    "$CTRL_EXEC_DISPATCHER" setup-ctrl-exec || {
      hps_log error "ce_dispatcher_bring_up: setup-ctrl-exec failed"
      return 1
    }
  fi

  hps_log info "ce_dispatcher_bring_up: dispatcher ready"
  return 0
}

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
