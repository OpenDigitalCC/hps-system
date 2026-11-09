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
#
# The dispatcher config and key are ctrl-exec-only (0600), so the CGI (www-data)
# cannot run the dispatcher. When `id -u` is not 0 the pairing window, the
# pending-request listing and the approval go through the root job runner
# (jobs-functions.sh, bin/hps-jobs, ADR 0006); as root (CLI, tests) they call
# the dispatcher directly.

# Full path to the dispatcher CLI; overridable for tests.
: "${CTRL_EXEC_DISPATCHER:=ctrl-exec-dispatcher}"
# Where the dispatcher queues pending pairing requests (Exec::Pairing
# $PAIRING_DIR). Overridable for tests.
: "${CTRL_EXEC_PAIRING_DIR:=/var/lib/ctrl-exec/pairing}"
# Default pairing window, seconds. Matches the agent's
# request-pairing --background --timeout in ctrl-exec.init.
: "${CTRL_EXEC_PAIR_WINDOW:=300}"
# Persistent bases on the /srv bind-mount so the CA and pairing/agent state
# survive container image rebuilds. The upstream defaults (/etc/ctrl-exec-dispatcher,
# /var/lib/ctrl-exec) are symlinked here at bring-up.
: "${CTRL_EXEC_PERSIST_CONF:=/srv/ctrl-exec/conf}"
: "${CTRL_EXEC_PERSIST_STATE:=/srv/ctrl-exec/state}"
# Dispatcher paths since ctrl-exec 0.14: config and CA in /etc/ctrl-exec-dispatcher,
# state in /var/lib/ctrl-exec. Overridable for tests.
: "${CTRL_EXEC_DISPATCHER_CONF_DIR:=/etc/ctrl-exec-dispatcher}"
: "${CTRL_EXEC_DISPATCHER_STATE_DIR:=/var/lib/ctrl-exec}"
# Floating dispatcher tarball served from the IPS package repo (see the
# node-side CTRL_EXEC_TARBALL note; the same latest-symlink convention).
: "${CTRL_EXEC_DISPATCHER_TARBALL:=/srv/hps-resources/packages/ctrl-exec/ctrl-exec-latest.tar.gz}"
# The API client plugins (.deb, same convention: the lab resources hold the
# release file and a ctrl-exec-api-plugins-latest.deb symlink to it).
: "${CTRL_EXEC_API_PLUGINS_DEB:=/srv/hps-resources/packages/ctrl-exec/ctrl-exec-api-plugins-latest.deb}"
# Where that deb installs the client, and where bring-up links it onto PATH.
: "${CTRL_EXEC_CLI_INSTALLED:=/usr/share/ctrl-exec/plugins/ce-api-plugins/ctrl-exec-cli/ctrl-exec-cli}"
: "${CTRL_EXEC_CLI_LINK:=/usr/local/bin/ctrl-exec-cli}"
# The API unix socket (ctrl-exec.conf api_socket) and its group. Group hps lets
# root and the state group call it; the API runs as ctrl-exec, which bring-up
# adds to hps so it may own a socket of that group.
: "${CTRL_EXEC_API_SOCKET:=/run/ctrl-exec-api/api.sock}"
: "${CTRL_EXEC_API_SOCKET_GROUP:=ctrl-exec}"
: "${CTRL_EXEC_DISPATCHER_CONF:=${CTRL_EXEC_DISPATCHER_CONF_DIR}/ctrl-exec.conf}"

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
# _ce_tarball_install <install.sh role flag>
# -----------------------------------------
# Unpack $CTRL_EXEC_DISPATCHER_TARBALL into a scratch directory and run its
# install.sh with the given role flag (--dispatcher or --api). Logs and returns
# 1 when the tarball, install.sh or the install itself fails.
#===============================================================================
_ce_tarball_install() {
  local role="$1"
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
  local binary
  case "$role" in
    --dispatcher) binary="$CTRL_EXEC_DISPATCHER" ;;
    --api) binary="ctrl-exec-api" ;;
    *) binary="" ;;
  esac
  if ! ( cd "$srcdir" && ./install.sh "$role" ); then
    # install.sh --api ends with "systemctl daemon-reload": in the IPS
    # container systemctl exists but systemd is not PID 1, so the install
    # reports failure after the binary and library are in place (supervisord
    # runs the API here; the unit is not used). The binary decides.
    if [[ -n "$binary" ]] && command -v "$binary" >/dev/null 2>&1; then
      hps_log warn "ce_dispatcher_bring_up: install.sh $role reported failure after installing $binary (no init system in the container; its service unit is unused here)"
    else
      hps_log error "ce_dispatcher_bring_up: install.sh $role failed"
      rm -rf "$work"
      return 1
    fi
  fi
  rm -rf "$work"
  return 0
}

#===============================================================================
# ce_dispatcher_bring_up
# ----------------------
# Idempotent IPS-side dispatcher bring-up, safe to call on every start:
#   1. Back /etc/ctrl-exec-dispatcher and /var/lib/ctrl-exec with persistent /srv storage.
#   2. Install the dispatcher from the HPS-served tarball if absent.
#   3. Initialise the CA and the dispatcher cert once.
#
# Returns: 0 on success (or already up), non-zero on failure.
#===============================================================================
ce_dispatcher_bring_up() {
  _ce_persist_dir "$CTRL_EXEC_PERSIST_CONF" "$CTRL_EXEC_DISPATCHER_CONF_DIR" || {
    hps_log error "ce_dispatcher_bring_up: cannot persist $CTRL_EXEC_DISPATCHER_CONF_DIR"
    return 1
  }
  _ce_persist_dir "$CTRL_EXEC_PERSIST_STATE" "$CTRL_EXEC_DISPATCHER_STATE_DIR" || {
    hps_log error "ce_dispatcher_bring_up: cannot persist $CTRL_EXEC_DISPATCHER_STATE_DIR"
    return 1
  }

  # The persisted config and state carry the group id of the image that
  # wrote them; the current image's ctrl-exec group must own them or the
  # API (user ctrl-exec) cannot read ctrl-exec.conf. Group only: owners
  # (root for the config, ctrl-exec for dispatcher.key and the state) stay.
  if getent group ctrl-exec > /dev/null 2>&1; then
    local d
    for d in "$CTRL_EXEC_DISPATCHER_CONF_DIR" "$CTRL_EXEC_DISPATCHER_STATE_DIR"; do
      [[ -d "$d" ]] || continue
      chgrp -R ctrl-exec "$d/" 2> /dev/null \
        || hps_log warn "ce_dispatcher_bring_up: cannot set group ctrl-exec on $d"
    done
    if [[ -f "$CTRL_EXEC_DISPATCHER_CONF_DIR/dispatcher.key" ]]; then
      chown ctrl-exec "$CTRL_EXEC_DISPATCHER_CONF_DIR/dispatcher.key" 2> /dev/null || true
    fi
  fi

  # Install the dispatcher and the API server from the HPS-served tarball,
  # each only when its binary is not on PATH. They are two roles of one
  # tarball (install.sh --dispatcher, install.sh --api) and are checked
  # separately: an image that already carries the dispatcher still needs
  # the API (hps-jobs and hps-run.sh --input use it).
  if ! command -v "$CTRL_EXEC_DISPATCHER" >/dev/null 2>&1; then
    _ce_tarball_install --dispatcher || return 1
  fi
  if ! command -v ctrl-exec-api >/dev/null 2>&1; then
    _ce_tarball_install --api || return 1
    hps_log info "ce_dispatcher_bring_up: ctrl-exec-api installed"
  fi

  # Initialise the CA and dispatcher cert once (persisted under /srv).
  if [[ ! -f "$CTRL_EXEC_DISPATCHER_CONF_DIR/ca.crt" ]]; then
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

  ce_api_bring_up || return 1

  hps_log info "ce_dispatcher_bring_up: dispatcher ready"
  return 0
}

#===============================================================================
# ce_api_bring_up
# ---------------
# The ctrl-exec-api side of the IPS (idempotent, root):
#   1. api_socket and api_socket_group in ctrl-exec.conf, appended once (an
#      existing api_socket line is left alone).
#   2. The service user ctrl-exec joins the socket's group (hps).
#   3. The API client (ctrl-exec-cli) from the plugins .deb, only when absent,
#      linked onto PATH.
# program:ctrl-exec-api then serves the socket (supervisor-functions.sh).
# A missing plugins .deb is a warning: hps-run.sh --input needs it, nothing
# else does.
#===============================================================================
ce_api_bring_up() {
  local conf="$CTRL_EXEC_DISPATCHER_CONF"
  if [[ -f "$conf" ]]; then
    if ! grep -qE '^[[:space:]]*api_socket[[:space:]]*=' "$conf"; then
      printf '\n# HPS: API unix socket for the IPS job runner and hps-run.sh --input\napi_socket = %s\napi_socket_group = %s\n' \
        "$CTRL_EXEC_API_SOCKET" "$CTRL_EXEC_API_SOCKET_GROUP" >> "$conf" || {
        hps_log error "ce_api_bring_up: cannot write api_socket to $conf"
        return 1
      }
      hps_log info "ce_api_bring_up: api_socket set in $conf"
    fi
    # Socket only: with no TCP listener the auth hook can treat every
    # non-socket request as ced.
    if ! grep -qE '^[[:space:]]*api_port[[:space:]]*=' "$conf"; then
      printf 'api_port = off\n' >> "$conf" || hps_log warn "ce_api_bring_up: cannot set api_port"
    fi
    # The authorisation hook: only the root job runner, on the unix socket,
    # may call the API (scripts/ctrl-exec-auth-hook.sh). Installed as a real
    # root-owned file; named in ctrl-exec.conf once.
    local hook_src="${HPS_SYSTEM_PATH:-/srv/hps-system}/scripts/ctrl-exec-auth-hook.sh"
    local hook_dst="$CTRL_EXEC_DISPATCHER_CONF_DIR/auth-hook-hps"
    if [[ -f "$hook_src" ]]; then
      if ! cmp -s "$hook_src" "$hook_dst" 2>/dev/null; then
        install -m 0755 -o 0 -g 0 "$hook_src" "$hook_dst" || hps_log warn "ce_api_bring_up: cannot install $hook_dst"
      fi
      if ! grep -qE '^[[:space:]]*auth_hook[[:space:]]*=' "$conf"; then
        printf 'auth_hook = %s\n' "$hook_dst" >> "$conf" || hps_log warn "ce_api_bring_up: cannot set auth_hook"
        hps_log info "ce_api_bring_up: auth_hook set to $hook_dst"
      fi
    else
      hps_log warn "ce_api_bring_up: $hook_src missing; the API will deny every request (api_auth_default=deny)"
    fi
  else
    hps_log warn "ce_api_bring_up: $conf not found; api_socket not set"
  fi

  if getent passwd ctrl-exec > /dev/null 2>&1 && getent group "$CTRL_EXEC_API_SOCKET_GROUP" > /dev/null 2>&1; then
    if ! id -nG ctrl-exec 2> /dev/null | tr ' ' '\n' | grep -qx "$CTRL_EXEC_API_SOCKET_GROUP"; then
      usermod -aG "$CTRL_EXEC_API_SOCKET_GROUP" ctrl-exec \
        || hps_log warn "ce_api_bring_up: cannot add ctrl-exec to group $CTRL_EXEC_API_SOCKET_GROUP"
    fi
  fi

  if ! command -v ctrl-exec-cli > /dev/null 2>&1 && [[ ! -x "$CTRL_EXEC_CLI_INSTALLED" ]]; then
    if [[ -f "$CTRL_EXEC_API_PLUGINS_DEB" ]]; then
      hps_log info "ce_api_bring_up: installing the API client from $CTRL_EXEC_API_PLUGINS_DEB"
      dpkg -i "$CTRL_EXEC_API_PLUGINS_DEB" > /dev/null || {
        hps_log warn "ce_api_bring_up: dpkg -i of the API plugins failed"
        return 0
      }
    else
      hps_log warn "ce_api_bring_up: ctrl-exec-cli absent and $CTRL_EXEC_API_PLUGINS_DEB missing; hps-run.sh --input unavailable"
      return 0
    fi
  fi
  if [[ -x "$CTRL_EXEC_CLI_INSTALLED" && ! -e "$CTRL_EXEC_CLI_LINK" ]]; then
    ln -s "$CTRL_EXEC_CLI_INSTALLED" "$CTRL_EXEC_CLI_LINK" \
      || hps_log warn "ce_api_bring_up: cannot link $CTRL_EXEC_CLI_LINK"
  fi
  return 0
}

# _ce_is_root: true when running as uid 0 (CLI, tests); the CGI is not.
_ce_is_root() {
  [[ "$(id -u)" -eq 0 ]]
}

# _ce_job <wait seconds> <kind> [args...]
# Run one privileged action through the root job runner: submit, wait, relay the
# job's stdout/stderr, return its exit.
_ce_job() {
  local wait="$1" id
  shift
  id=$(hps_job_submit "$@") || return 1
  hps_job_wait "$id" "$wait"
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
  if _ce_is_root; then
    "$CTRL_EXEC_DISPATCHER" pairing-mode start --timeout "$timeout" || {
      hps_log error "Failed to start ctrl-exec pairing mode"
      return 1
    }
  else
    _ce_job 5 pairing-window-open "$timeout" || {
      hps_log error "Failed to start ctrl-exec pairing mode (job runner)"
      return 1
    }
  fi
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
  if _ce_is_root; then
    "$CTRL_EXEC_DISPATCHER" pairing-mode stop || {
      hps_log error "Failed to stop ctrl-exec pairing mode"
      return 1
    }
  else
    _ce_job 5 pairing-window-close || {
      hps_log error "Failed to stop ctrl-exec pairing mode (job runner)"
      return 1
    }
  fi
  return 0
}

#===============================================================================
# _ce_read_pair_request
# ----------------------
# Read a pending pairing request by reqid. Emits JSON {id,hostname,ip,
# source_ip} on stdout.
#
# ctrl-exec 0.14.1 `list-requests` prints a table (ID, HOSTNAME, SOURCE IP, ...)
# and has no --json mode, so the dispatcher CLI is read as that table first.
# If the CLI is unavailable or does not list the reqid, the queue file the
# dispatcher keeps (one JSON file per request, CTRL_EXEC_PAIRING_DIR) is the
# fallback; the approver runs on the IPS where that state lives.
#
# Arguments:
#   $1 - reqid
#
# Returns: 0 and prints JSON if found; 1 if absent.
#===============================================================================
_ce_read_pair_request() {
  local reqid="$1"
  local row host ip listing
  # The listing needs the dispatcher config, so the CGI asks the job runner.
  if _ce_is_root; then
    listing=$("$CTRL_EXEC_DISPATCHER" list-requests 2>/dev/null) || listing=""
  else
    listing=$(_ce_job 15 pairing-list 2>/dev/null) || listing=""
  fi
  row=$(printf '%s\n' "$listing" | awk -v id="$reqid" '$1 == id { print $2 " " $3; exit }') || row=""
  if [[ -n "$row" ]]; then
    read -r host ip <<< "$row"
    jq -n --arg id "$reqid" --arg h "$host" --arg ip "$ip" \
      '{id: $id, hostname: $h, ip: $ip, source_ip: $ip}'
    return 0
  fi

  local req_file="${CTRL_EXEC_PAIRING_DIR}/${reqid}.json"
  if [[ ! -f "$req_file" ]]; then
    return 1
  fi
  cat -- "$req_file"
}

#===============================================================================
# _ce_within_pair_window
# ----------------------
# ADR 0002 check 3: the pairing request must arrive within CTRL_EXEC_PAIR_WINDOW
# seconds of the host's last boot-script issue (host key last_boot_at, epoch,
# written by ipxe_init_handler). A missing or non-numeric key is a refusal,
# never a pass.
#
# Arguments:
#   $1 - mac
#
# Returns: 0 inside the window; 1 outside it or when last_boot_at is unusable.
#===============================================================================
_ce_within_pair_window() {
  local mac="$1"
  local booted now age
  booted=$(host_registry "$mac" get last_boot_at 2>/dev/null) || booted=""
  if [[ ! "$booted" =~ ^[0-9]+$ ]]; then
    hps_log error "ce_approve: ${mac} has no usable last_boot_at ('${booted}'); refusing"
    return 1
  fi
  now=$(date +%s)
  age=$((now - booted))
  if (( age < 0 || age > CTRL_EXEC_PAIR_WINDOW )); then
    hps_log error "ce_approve: ${mac} request ${age}s after boot script; window is ${CTRL_EXEC_PAIR_WINDOW}s"
    return 1
  fi
  return 0
}

#===============================================================================
# _ce_close_window_after_approval
# -------------------------------
# Close the dispatcher pairing listener once a node is approved. The per-request
# handler in the listener delivers the signed certificate on the agent's next
# poll, so the close is delayed by CTRL_EXEC_PAIR_CLOSE_DELAY seconds (default
# 15) in a detached background job; 0 closes immediately. The dispatcher also
# stops itself at the window timeout, so a failed close is only logged.
#===============================================================================
_ce_close_window_after_approval() {
  local delay="${CTRL_EXEC_PAIR_CLOSE_DELAY:-15}"
  if [[ ! "$delay" =~ ^[0-9]+$ ]] || (( delay == 0 )); then
    ce_pairing_window_close > /dev/null 2>&1 || hps_log warn "ce_approve: pairing window close failed"
    return 0
  fi
  ( sleep "$delay"; ce_pairing_window_close ) > /dev/null 2>&1 < /dev/null &
  disown 2> /dev/null || true
  return 0
}

#===============================================================================
# _ce_dispatcher_supports_replace
# -------------------------------
# True when the dispatcher's usage text lists approve --replace (0.14.3+). A
# feature probe on the usage text: an unknown option makes the dispatcher print
# it and exit before it touches its config.
#===============================================================================
_ce_dispatcher_supports_replace() {
  local help
  help=$("$CTRL_EXEC_DISPATCHER" --help 2>&1 || true)
  [[ "$help" == *--replace* ]]
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
#   1. Host registry entry exists for MAC and STATE is enrolment-eligible
#      (INSTALLING, CONFIGURING, NETWORK_BOOT for a RAM-booted node, or HELD:
#      a held node in the audit image pairs so it can be inspected).
#   2. Pairing request exists and its hostname + IP match the registry
#      allocation.
#   3. The request arrives within CTRL_EXEC_PAIR_WINDOW seconds of the host's
#      last boot-script issue (last_boot_at); a missing key refuses.
#   4. No prior approval this provisioning cycle (ctrl_exec_paired unset).
#
# On approval the dispatcher pairing window is closed (after a short delay;
# see _ce_close_window_after_approval). On a window refusal it is closed at once.
#
# Returns:
#   0  approved (records ctrl_exec_paired=<epoch>)
#   1  denied (reason logged)
#   2  usage / internal error
#===============================================================================
ce_approve_pair_request() {
  local mac="${1:?Usage: ce_approve_pair_request <mac> <reqid> [caller-ip]}"
  local reqid="${2:?Usage: ce_approve_pair_request <mac> <reqid> [caller-ip]}"
  # caller_ip: the API connection's peer address (api.sh resolved it to this
  # MAC by ARP). Used only to bind a HELD node, which has no allocation yet.
  local caller_ip="${3:-}"

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
    INSTALLING|CONFIGURING|NETWORK_BOOT|HELD) ;;
    *)
      hps_log error "ce_approve: ${mac} STATE '${state}' not enrolment-eligible"
      return 1
      ;;
  esac

  # Check 3: arrival within the window of the last boot-script issue.
  if ! _ce_within_pair_window "$mac"; then
    ce_pairing_window_close > /dev/null 2>&1 || true
    return 1
  fi

  # Check 4 (cheap, do before reading files): one approval per cycle.
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
    # A HELD node has no allocation yet (assign allocates it). Bind to the API
    # caller's peer address instead: the API resolved that address to this MAC
    # by ARP, so a pairing request from the same address is the same machine.
    if [[ "$state" == "HELD" && -n "$caller_ip" ]]; then
      reg_ip="$caller_ip"
      hps_log info "ce_approve: ${mac} is HELD with no allocation; binding to API caller ${caller_ip}"
    else
      hps_log error "ce_approve: ${mac} has no allocated IP; cannot bind request"
      return 1
    fi
  fi
  if [[ "$req_ip" != "$reg_ip" ]]; then
    hps_log error "ce_approve: ${mac} request IP '${req_ip}' != allocated '${reg_ip}'"
    return 1
  fi
  # Hostname is advisory: only enforce when the registry has one recorded.
  # Compare first labels: the agent registers under its FQDN, and a node with
  # a second NIC on a foreign LAN can pick up a foreign domain (or .lab.hps),
  # which must not decide the binding; the peer IP above is the strong check.
  if [[ -n "$reg_hostname" && "${req_hostname%%.*}" != "${reg_hostname%%.*}" ]]; then
    hps_log error "ce_approve: ${mac} request hostname '${req_hostname}' != '${reg_hostname}'"
    return 1
  fi

  # All bindings satisfied - approve. The binding to the allocated IP was
  # checked above; ctrl-exec-dispatcher 0.14.x approve takes only <reqid>
  # (no --ip: it fails with "Too many arguments").
  hps_log info "ce_approve: approving ${reqid} for ${mac} (${reg_hostname:-$req_hostname} @ ${reg_ip})"
  # The dispatcher prints its approval details on stdout; this function runs
  # inside a CGI whose stdout is the HTTP response, so capture them.
  # ctrl-exec 0.14.3+ takes --replace: a node that re-pairs (new boot, same
  # source address) unregisters its previous registration, so one node is one
  # registration. An older dispatcher gets the plain approve.
  # As the CGI user the approval goes to the job runner, which probes for
  # --replace itself; it returns the dispatcher's exit and output as here.
  local approve_out
  local -a approve_args=(approve "$reqid")
  if _ce_is_root; then
    if _ce_dispatcher_supports_replace; then
      approve_args+=(--replace)
    else
      hps_log info "ce_approve: dispatcher has no approve --replace; approving without it"
    fi
    approve_out=$("$CTRL_EXEC_DISPATCHER" "${approve_args[@]}" 2>&1) || {
      hps_log error "ce_approve: dispatcher approve failed for ${reqid}: ${approve_out}"
      return 1
    }
  else
    approve_out=$(_ce_job 15 pairing-approve "$reqid" --replace 2>&1) || {
      hps_log error "ce_approve: dispatcher approve failed for ${reqid}: ${approve_out}"
      return 1
    }
  fi
  hps_log info "ce_approve: dispatcher: $(printf '%s' "$approve_out" | tr '\n' ' ' | cut -c1-300)"
  local replaced_line
  while IFS= read -r replaced_line; do
    [[ -n "$replaced_line" ]] && hps_log info "ce_approve: replaced registration: ${replaced_line}"
  done < <(printf '%s\n' "$approve_out" | grep -E 'REPLACED_BY|Replaced:' || true)

  host_registry "$mac" set ctrl_exec_paired "$(date +%s)" || {
    hps_log warn "ce_approve: approved ${reqid} but failed to record ctrl_exec_paired for ${mac}"
  }
  _ce_close_window_after_approval
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
