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
# The node's pairing request timeout, seconds: hps-pair's HPS_PAIR_TIMEOUT
# (node-manager/nixos-26/boot/hps-pair.sh), the --timeout of its
# request-pairing; the dispatcher keeps the request that long. One approval
# waits this long in total for its pairing jobs (pairing-list, pairing-approve),
# so the IPS never gives up on a request the node still holds open (incident
# 2026-11-12: a 15 s wait gave up behind a 30 s storage-up). Keep the two equal.
: "${CTRL_EXEC_PAIR_REQUEST_TIMEOUT:=300}"
# How many times a node that missed its pairing window is told to reboot into
# netboot (a new boot script, a new window) before the IPS gives up on it and
# records pair_failed_at. Counted in the host key pair_reboots; a pairing
# resets it.
: "${CTRL_EXEC_PAIR_MAX_REBOOTS:=3}"
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
# install.sh with the given role flag (--dispatcher, --api, or --agent for the
# IPS's own agent, ce_ips_agent_bring_up). Logs and returns 1 when the tarball,
# install.sh or the install itself fails.
#===============================================================================
_ce_tarball_install() {
  local role="$1"
  if [[ ! -f "$CTRL_EXEC_DISPATCHER_TARBALL" ]]; then
    hps_log error "_ce_tarball_install ${role}: ctrl-exec tarball missing: $CTRL_EXEC_DISPATCHER_TARBALL"
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
  # install.sh's exit status decides (ctrl-exec 0.14.5: --api exits 0 in the
  # IPS container, where systemd is not PID 1; HPS no longer second-guesses a
  # failed install by looking for the binary).
  if ! ( cd "$srcdir" && ./install.sh "$role" ); then
    hps_log error "ce_dispatcher_bring_up: install.sh $role failed"
    rm -rf "$work"
    return 1
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
    # The TCP listener: off, unless the cluster key operator_api_listen names
    # an address of this IPS, where it listens with TLS for remote operators
    # (ce_operator_api_configure, ips-admin-functions.sh; docs/OPERATOR.md).
    # The operator API needs ctrl-exec >= CTRL_EXEC_MIN_VERSION (the hook is told
    # its caller and listener; api_forward_token): with an older dispatcher it
    # stays off, and the error names the requirement.
    if ! _ce_dispatcher_at_least "$CTRL_EXEC_MIN_VERSION"; then
      hps_log error "ce_api_bring_up: ctrl-exec >= ${CTRL_EXEC_MIN_VERSION} is required for operator access (installed: $(_ce_dispatcher_version || echo unknown)); the operator API stays off"
      _ce_conf_set "$conf" api_port off || hps_log warn "ce_api_bring_up: cannot set api_port"
      _ce_conf_unset "$conf" api_bind api_tls_cert api_tls_key api_forward_token || true
    elif declare -f ce_operator_api_configure > /dev/null 2>&1; then
      ce_operator_api_configure "$conf" || hps_log warn "ce_api_bring_up: cannot configure the operator API listener"
      # The operator's token must not reach the agents (it would be passed on
      # to each script's stdin context).
      _ce_conf_set "$conf" api_forward_token no || hps_log warn "ce_api_bring_up: cannot set api_forward_token"
    elif ! grep -qE '^[[:space:]]*api_port[[:space:]]*=' "$conf"; then
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
#   $2 - seconds to wait for the pairing-list job (job runner path; default
#        CTRL_EXEC_PAIR_REQUEST_TIMEOUT)
#
# Returns: 0 and prints JSON if found; 1 if absent; 3 if absent from the queue
# file and the listing job did not finish in time (not known yet: retry).
#===============================================================================
_ce_read_pair_request() {
  local reqid="$1" wait="${2:-$CTRL_EXEC_PAIR_REQUEST_TIMEOUT}"
  local row host ip listing rc=0
  # The listing needs the dispatcher config, so the CGI asks the job runner.
  if _ce_is_root; then
    listing=$("$CTRL_EXEC_DISPATCHER" list-requests 2>/dev/null) || listing=""
  else
    listing=$(_ce_job "$wait" pairing-list 2>/dev/null) || rc=$?
    (( rc == 0 )) || listing=""
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
    (( rc == 124 )) && return 3
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
# Sets CE_PAIR_WINDOW_LEFT (seconds left in the window, 0 when none) and
# CE_PAIR_LAST_BOOT_AT (the key's value).
#
# Returns: 0 inside the window; 4 when the request came after it closed;
# 1 when last_boot_at is unusable (missing, not a number, in the future).
#===============================================================================
_ce_within_pair_window() {
  local mac="$1"
  local booted now age
  CE_PAIR_WINDOW_LEFT=0
  booted=$(host_registry "$mac" get last_boot_at 2>/dev/null) || booted=""
  CE_PAIR_LAST_BOOT_AT="$booted"
  if [[ ! "$booted" =~ ^[0-9]+$ ]]; then
    hps_log error "ce_approve: ${mac} has no usable last_boot_at ('${booted}'); refusing"
    return 1
  fi
  now=$(date +%s)
  age=$((now - booted))
  if (( age < 0 )); then
    hps_log error "ce_approve: ${mac} last_boot_at is ${age#-}s in the future; refusing"
    return 1
  fi
  if (( age > CTRL_EXEC_PAIR_WINDOW )); then
    hps_log error "ce_approve: ${mac} request ${age}s after boot script; window is ${CTRL_EXEC_PAIR_WINDOW}s"
    return 4
  fi
  CE_PAIR_WINDOW_LEFT=$((CTRL_EXEC_PAIR_WINDOW - age))
  return 0
}

#===============================================================================
# _ce_pair_answer <reason> <message>
# ----------------------------------
# Record why ce_approve_pair_request decided as it did, for the API reply:
# CE_PAIR_REASON (a fixed word, docs/OPERATOR.md "Pairing") and CE_PAIR_DETAIL.
#===============================================================================
_ce_pair_answer() {
  CE_PAIR_REASON="$1"
  CE_PAIR_DETAIL="$2"
}

#===============================================================================
# _ce_pair_missed_window <mac>
# ----------------------------
# The node asked after its window. While pair_reboots is below
# CTRL_EXEC_PAIR_MAX_REBOOTS it is counted up and the node is told to reboot
# into netboot (return 4, reason outside_window): the boot script renews
# last_boot_at and with it the window. After that the IPS gives up: pair_failed_at
# is recorded (hps-monitor and hps-ips-check report it) and the answer is a
# refusal (return 1, reason reboots_exhausted).
#===============================================================================
_ce_pair_missed_window() {
  local mac="$1" n
  n=$(host_registry "$mac" get pair_reboots 2>/dev/null) || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n < CTRL_EXEC_PAIR_MAX_REBOOTS )); then
    n=$((n + 1))
    host_registry "$mac" set pair_reboots "$n" > /dev/null 2>&1 \
      || hps_log warn "ce_approve: cannot record pair_reboots for ${mac}"
    hps_log warn "ce_approve: ${mac} missed its pairing window; reboot ${n} of ${CTRL_EXEC_PAIR_MAX_REBOOTS} into netboot"
    _ce_pair_answer outside_window "the request came after the ${CTRL_EXEC_PAIR_WINDOW}s pairing window; reboot ${n} of ${CTRL_EXEC_PAIR_MAX_REBOOTS}"
    return 4
  fi
  if ! host_registry "$mac" get pair_failed_at > /dev/null 2>&1; then
    host_registry "$mac" set pair_failed_at "$(date +%s)" > /dev/null 2>&1 \
      || hps_log warn "ce_approve: cannot record pair_failed_at for ${mac}"
  fi
  hps_log error "ce_approve: ${mac} missed its pairing window after ${n} reboot(s); giving up (pair_failed_at set). Reboot it by hand once the cause is fixed"
  _ce_pair_answer reboots_exhausted "missed the pairing window after ${n} reboot(s); the IPS gave up (pair_failed_at)"
  return 1
}

#===============================================================================
# _ce_hosts_awaiting_pairing
# --------------------------
# The hosts still expecting to pair: an enrolment-eligible STATE, a usable
# last_boot_at at most CTRL_EXEC_PAIR_WINDOW seconds ago, and no
# ctrl_exec_paired_at (nor the old ctrl_exec_paired). Prints "<mac> <deadline
# epoch>" per host. Without list_cluster_hosts (a bare test harness) none.
#===============================================================================
_ce_hosts_awaiting_pairing() {
  local h state last now
  declare -F list_cluster_hosts > /dev/null || return 0
  now=$(date +%s)
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    state=$(host_registry "$h" get STATE 2>/dev/null) || continue
    case "$state" in
      INSTALLING|CONFIGURING|NETWORK_BOOT|HELD) ;;
      *) continue ;;
    esac
    last=$(host_registry "$h" get last_boot_at 2>/dev/null) || continue
    [[ "$last" =~ ^[0-9]+$ ]] || continue
    (( now - last >= 0 && now - last <= CTRL_EXEC_PAIR_WINDOW )) || continue
    host_registry "$h" get ctrl_exec_paired_at > /dev/null 2>&1 && continue
    host_registry "$h" get ctrl_exec_paired > /dev/null 2>&1 && continue
    printf '%s %s\n' "$h" "$((last + CTRL_EXEC_PAIR_WINDOW))"
  done < <(list_cluster_hosts 2>/dev/null)
  return 0
}

#===============================================================================
# _ce_close_window_unless_awaited
# -------------------------------
# Close the dispatcher pairing listener unless another host is still within
# its own window and unpaired (_ce_hosts_awaiting_pairing): then it stays open
# (it stops itself at its own timeout) and the log names how many wait and
# when the last of their windows ends. A failed close is only logged.
#===============================================================================
_ce_close_window_unless_awaited() {
  local waiting n last now
  waiting=$(_ce_hosts_awaiting_pairing)
  if [[ -n "$waiting" ]]; then
    n=$(printf '%s\n' "$waiting" | wc -l)
    last=$(printf '%s\n' "$waiting" | awk '$2 > m { m = $2 } END { print m + 0 }')
    now=$(date +%s)
    hps_log info "ce_approve: pairing window kept open: ${n} host(s) still within their window and unpaired; the last window ends in $((last - now))s"
    return 0
  fi
  ce_pairing_window_close > /dev/null 2>&1 || hps_log warn "ce_approve: pairing window close failed"
  return 0
}

#===============================================================================
# _ce_close_window_after_approval
# -------------------------------
# Close the dispatcher pairing listener once a node is approved, unless other
# hosts still wait to pair (_ce_close_window_unless_awaited). The per-request
# handler in the listener delivers the signed certificate on the agent's next
# poll, so the close is delayed by CTRL_EXEC_PAIR_CLOSE_DELAY seconds (default
# 15) in a detached background job; 0 decides immediately. The dispatcher also
# stops itself at the window timeout, so a failed close is only logged.
#===============================================================================
_ce_close_window_after_approval() {
  local delay="${CTRL_EXEC_PAIR_CLOSE_DELAY:-15}"
  if [[ ! "$delay" =~ ^[0-9]+$ ]] || (( delay == 0 )); then
    _ce_close_window_unless_awaited
    return 0
  fi
  ( sleep "$delay"; _ce_close_window_unless_awaited ) > /dev/null 2>&1 < /dev/null &
  disown 2> /dev/null || true
  return 0
}

# The ctrl-exec release that delivers what HPS's operator access and ips-admin
# rely on (R-036): the agent's `bind`, the hook's ENVEXEC_CALLER/ENVEXEC_LISTENER,
# `approve --read-timeout`, and the dispatcher's api_forward_token.
: "${CTRL_EXEC_MIN_VERSION:=0.14.7}"

#===============================================================================
# _ce_dispatcher_version
# ----------------------
# The installed dispatcher's version ("ctrl-exec-dispatcher --version" prints
# "ctrl-exec-dispatcher X.Y.Z"). Prints X.Y.Z, or nothing when it cannot be
# read. Returns 0 when printed, 1 otherwise.
#===============================================================================
_ce_dispatcher_version() {
  local out ver
  out=$("$CTRL_EXEC_DISPATCHER" --version 2> /dev/null) || return 1
  ver="${out##* }"
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$ver"
}

#===============================================================================
# _ce_dispatcher_at_least [<version>]
# -----------------------------------
# True when the installed dispatcher is at least <version> (default
# CTRL_EXEC_MIN_VERSION). A version that cannot be read counts as older.
#===============================================================================
_ce_dispatcher_at_least() {
  local want="${1:-$CTRL_EXEC_MIN_VERSION}" have a b i
  have=$(_ce_dispatcher_version) || return 1
  IFS=. read -r -a a <<< "$have"
  IFS=. read -r -a b <<< "$want"
  for i in 0 1 2; do
    if ((10#${a[i]:-0} > 10#${b[i]:-0})); then
      return 0
    fi
    if ((10#${a[i]:-0} < 10#${b[i]:-0})); then
      return 1
    fi
  done
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
#   $2 - reqid : pairing request id the node reported; empty when the node has
#                none yet (it asks only whether to keep trying: checks 1, 3, 4)
#   $3 - caller-ip (optional): the API connection's peer address
#
# Checks (all must pass):
#   1. Host registry entry exists for MAC and STATE is enrolment-eligible
#      (INSTALLING, CONFIGURING, NETWORK_BOOT for a RAM-booted node, or HELD:
#      a held node in the audit image pairs so it can be inspected).
#   2. Pairing request exists and its hostname (exactly the host's FQDN) + IP
#      match the registry allocation.
#   3. The request arrives within CTRL_EXEC_PAIR_WINDOW seconds of the host's
#      last boot-script issue (last_boot_at); a missing key refuses. This
#      per-host window is the security control; a late node is told to reboot
#      (a new boot script renews it), at most CTRL_EXEC_PAIR_MAX_REBOOTS times.
#   4. No prior approval this provisioning cycle (ctrl_exec_paired_at unset;
#      ctrl_exec_paired, the pre-IPS-07 name, is read as a fallback).
#
# The pairing jobs of one approval (job runner path) wait at most
# CTRL_EXEC_PAIR_REQUEST_TIMEOUT seconds in total. On approval, and on a window
# refusal, the dispatcher pairing window is closed unless another host still
# waits within its own window (_ce_close_window_unless_awaited).
#
# Sets CE_PAIR_REASON and CE_PAIR_DETAIL (the API reply's reason and details),
# CE_PAIR_WINDOW_LEFT and CE_PAIR_LAST_BOOT_AT.
#
# Returns:
#   0  approved (records ctrl_exec_paired_at=<epoch>, and for one release the
#      same epoch under the old name ctrl_exec_paired; clears pair_reboots and
#      pair_failed_at). Reason paired.
#   1  refused: stop trying (reason refused, or reboots_exhausted)
#   2  usage / internal error
#   3  not yet: retry within the window (reason pending: a pairing job did not
#      finish in time; unknown_request: the dispatcher does not hold the reqid,
#      request pairing again; no_request: no reqid was given)
#   4  outside the window: reboot into netboot (reason outside_window)
#===============================================================================
# shellcheck disable=SC2034  # the CE_PAIR_* answer is read by http/api/api.sh
ce_approve_pair_request() {
  local mac="${1:?Usage: ce_approve_pair_request <mac> [<reqid>] [caller-ip]}"
  local reqid="${2-}"
  # caller_ip: the API connection's peer address (api.sh resolved it to this
  # MAC by ARP). Used only to bind a HELD node, which has no allocation yet.
  local caller_ip="${3:-}"
  local deadline rc=0
  CE_PAIR_REASON=refused
  CE_PAIR_DETAIL=""
  CE_PAIR_WINDOW_LEFT=0
  CE_PAIR_LAST_BOOT_AT=""
  deadline=$(( $(date +%s) + CTRL_EXEC_PAIR_REQUEST_TIMEOUT ))

  # reqid is agent-derived; constrain to the dispatcher's charset before it
  # reaches a file path or the CLI.
  if [[ -n "$reqid" && ! "$reqid" =~ ^[a-f0-9]+$ ]]; then
    hps_log error "ce_approve: malformed reqid from ${mac}: ${reqid}"
    _ce_pair_answer refused "malformed reqid"
    return 1
  fi

  # Check 1: known host in an enrolment-eligible state.
  local state
  state=$(host_registry "$mac" get STATE 2>/dev/null) || {
    hps_log error "ce_approve: no registry entry for ${mac}"
    _ce_pair_answer refused "no registry entry for this MAC"
    return 1
  }
  case "$state" in
    INSTALLING|CONFIGURING|NETWORK_BOOT|HELD) ;;
    *)
      hps_log error "ce_approve: ${mac} STATE '${state}' not enrolment-eligible"
      _ce_pair_answer refused "STATE ${state} is not enrolment-eligible"
      return 1
      ;;
  esac

  # Check 3: arrival within the window of the last boot-script issue.
  _ce_within_pair_window "$mac" || rc=$?
  if (( rc == 4 )); then
    rc=0
    _ce_pair_missed_window "$mac" || rc=$?
    _ce_close_window_unless_awaited
    return "$rc"
  elif (( rc != 0 )); then
    _ce_pair_answer refused "no usable last_boot_at"
    _ce_close_window_unless_awaited
    return 1
  fi

  # Check 4 (cheap, do before reading files): one approval per cycle.
  local already
  already=$(host_registry "$mac" get ctrl_exec_paired_at 2>/dev/null) || already=""
  if [[ -z "$already" ]]; then
    already=$(host_registry "$mac" get ctrl_exec_paired 2>/dev/null) || already=""
  fi
  if [[ -n "$already" ]]; then
    hps_log error "ce_approve: ${mac} already paired this cycle (${already})"
    _ce_pair_answer refused "already paired this boot (${already})"
    return 1
  fi

  if [[ -z "$reqid" ]]; then
    hps_log info "ce_approve: ${mac} has no pairing request yet; ${CE_PAIR_WINDOW_LEFT}s left in its window"
    _ce_pair_answer no_request "no reqid given; ${CE_PAIR_WINDOW_LEFT}s left in the window"
    return 3
  fi

  # Check 2: request exists and binds to this host's allocation.
  local req_json now
  now=$(date +%s)
  rc=0
  req_json=$(_ce_read_pair_request "$reqid" "$(( deadline > now ? deadline - now : 1 ))") || rc=$?
  if (( rc == 3 )); then
    hps_log warn "ce_approve: request ${reqid} for ${mac} not readable yet (the pairing-list job did not finish in time); the node retries"
    _ce_pair_answer pending "the pairing-list job did not finish in time"
    return 3
  elif (( rc != 0 )); then
    hps_log error "ce_approve: no pending request ${reqid} for ${mac}"
    _ce_pair_answer unknown_request "the dispatcher holds no pending request ${reqid}; request pairing again"
    return 3
  fi

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
      _ce_pair_answer refused "no allocated IP to bind the request to"
      return 1
    fi
  fi
  if [[ "$req_ip" != "$reg_ip" ]]; then
    hps_log error "ce_approve: ${mac} request IP '${req_ip}' != allocated '${reg_ip}'"
    _ce_pair_answer refused "request source address does not match the allocation"
    return 1
  fi
  # Hostname is advisory: only enforce when the registry has one recorded.
  # The one hostname rule (docs/NAMING.md): the agent registers under the host's
  # FQDN, so the request must carry exactly host_fqdn (registry HOSTNAME plus
  # the cluster DNS domain). The peer IP above remains the strong check.
  if [[ -n "$reg_hostname" ]]; then
    local reg_fqdn
    reg_fqdn=$(host_fqdn "$mac" 2>/dev/null) || {
      hps_log error "ce_approve: ${mac} has no usable FQDN for '${reg_hostname}'"
      _ce_pair_answer refused "no usable FQDN"
      return 1
    }
    if [[ "${req_hostname,,}" != "$reg_fqdn" ]]; then
      hps_log error "ce_approve: ${mac} request hostname '${req_hostname}' != '${reg_fqdn}'"
      _ce_pair_answer refused "request hostname does not match ${reg_fqdn}"
      return 1
    fi
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
      _ce_pair_answer refused "the dispatcher approve failed"
      return 1
    }
  else
    now=$(date +%s)
    rc=0
    approve_out=$(_ce_job "$(( deadline > now ? deadline - now : 1 ))" pairing-approve "$reqid" --replace 2>&1) || rc=$?
    if (( rc == 124 )); then
      hps_log warn "ce_approve: the pairing-approve job for ${reqid} (${mac}) did not finish in time; the node retries"
      _ce_pair_answer pending "the pairing-approve job did not finish in time"
      return 3
    elif (( rc != 0 )); then
      hps_log error "ce_approve: dispatcher approve failed for ${reqid}: ${approve_out}"
      _ce_pair_answer refused "the dispatcher approve failed"
      return 1
    fi
  fi
  hps_log info "ce_approve: dispatcher: $(printf '%s' "$approve_out" | tr '\n' ' ' | cut -c1-300)"
  local replaced_line
  while IFS= read -r replaced_line; do
    [[ -n "$replaced_line" ]] && hps_log info "ce_approve: replaced registration: ${replaced_line}"
  done < <(printf '%s\n' "$approve_out" | grep -E 'REPLACED_BY|Replaced:' || true)

  local paired_at
  paired_at="$(date +%s)"
  host_registry "$mac" set ctrl_exec_paired_at "$paired_at" || {
    hps_log warn "ce_approve: approved ${reqid} but failed to record ctrl_exec_paired_at for ${mac}"
  }
  # Compatibility window (IPS-07): the old key, same epoch value, for one release.
  host_registry "$mac" set ctrl_exec_paired "$paired_at" || {
    hps_log warn "ce_approve: approved ${reqid} but failed to record ctrl_exec_paired for ${mac}"
  }
  # A pairing ends the boot chain: the reboot count starts again.
  host_registry "$mac" delete pair_reboots > /dev/null 2>&1 || true
  host_registry "$mac" delete pair_failed_at > /dev/null 2>&1 || true
  _ce_pair_answer paired "approved"
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
# The call is bounded by CE_RUN_TIMEOUT seconds (default 900): lab
# 2026-11-10, the agent answered osvc-status (EXIT=0, 257 ms) and the
# dispatcher CLI never returned, holding chain P for nine hours.
#
# Returns: the dispatcher's exit status (0 all-ok); 124 when the call did not
# return within CE_RUN_TIMEOUT.
#===============================================================================
ce_run() {
  local host="${1:?Usage: ce_run <host> <script> [args...]}"
  local script="${2:?Usage: ce_run <host> <script> [args...]}"
  shift 2
  local limit="${CE_RUN_TIMEOUT:-900}" rc=0

  if (( $# > 0 )); then
    timeout --kill-after=10 "$limit" "$CTRL_EXEC_DISPATCHER" run "$host" "$script" -- "$@" || rc=$?
  else
    timeout --kill-after=10 "$limit" "$CTRL_EXEC_DISPATCHER" run "$host" "$script" || rc=$?
  fi
  if (( rc == 124 || rc == 137 )); then
    echo "ce_run: ${script} on ${host}: no answer from the dispatcher within ${limit}s" >&2
    return 124
  fi
  return "$rc"
}

#===============================================================================
# ce_agent_names
# --------------
# The names of the agents registered with the dispatcher, one per line (the
# HOSTNAME column of `list-agents`, through its --json form). Needs the
# dispatcher's config, so it runs as root (the CLI, tests); the CGI cannot.
#
# Returns: 0 (a registry with no agents prints nothing), 1 when the dispatcher
# cannot be run or answers something that is not JSON.
#===============================================================================
ce_agent_names() {
  local out
  if ! _ce_is_root; then
    hps_log error "ce_agent_names: needs root (the dispatcher config is ctrl-exec-only)"
    return 1
  fi
  out=$("$CTRL_EXEC_DISPATCHER" list-agents --json 2>&1) || {
    hps_log error "ce_agent_names: list-agents failed: ${out}"
    return 1
  }
  if [[ "$out" == "No registered agents."* ]]; then
    return 0
  fi
  printf '%s\n' "$out" | jq -r '.[].hostname // empty' || {
    hps_log error "ce_agent_names: list-agents did not return JSON"
    return 1
  }
}

#===============================================================================
# ce_unpair_agent
# ---------------
# Remove one agent registration from the dispatcher (`unpair <name>`): the
# record under agents/<name>.json goes, so the dispatcher no longer addresses
# it. ctrl-exec has no dispatcher-side certificate revocation (as of 0.14.5):
# the agent's certificate stays valid until its expiry, and the revocation list
# lives on agents (revoked-serials), where a forgotten host has no agent left
# to hold it. The name is the agent's registered name (an FQDN under the one
# hostname rule, docs/NAMING.md). Used by hps-onboard forget and
# hps-onboard prune-agents (scripts/hps-forget-hook.sh).
#
# Arguments: $1 - the agent name
#
# Returns: 0 removed; 4 no such agent (nothing to remove); 1 failed or not root.
#===============================================================================
ce_unpair_agent() {
  local name="${1:?Usage: ce_unpair_agent <agent-name>}" out
  # The dispatcher's own rule for a name that may become a file name.
  if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    hps_log error "ce_unpair_agent: '${name}' is not a valid agent name"
    return 1
  fi
  if ! _ce_is_root; then
    hps_log error "ce_unpair_agent: needs root (the dispatcher config is ctrl-exec-only)"
    return 1
  fi
  out=$("$CTRL_EXEC_DISPATCHER" unpair "$name" 2>&1) || {
    if [[ "$out" == *"No registry entry"* ]]; then
      hps_log info "ce_unpair_agent: no agent registered as ${name}"
      return 4
    fi
    hps_log error "ce_unpair_agent: unpair ${name} failed: ${out}"
    return 1
  }
  hps_log info "ce_unpair_agent: unregistered agent ${name}"
  return 0
}
