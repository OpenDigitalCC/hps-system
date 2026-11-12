# shellcheck shell=bash
# ips-admin-functions.sh
#
# Every IPS manages itself through its own ctrl-exec (owner rulings
# 2026-11-11: "using inside c-e is better representation of how it would be
# normally used - inside clusters are not aware of the outside world";
# "inside cluster should be fractal of outside"). See docs/OPERATOR.md.
#
#   - ce_ips_agent_bring_up: the IPS's own ctrl-exec agent, ips.<cluster
#     domain>, installed from the same tarball as the dispatcher, reachable
#     from 127.0.0.1 only, paired with the IPS's own dispatcher by the IPS
#     itself (_ce_approve_local_agent: only that name from 127.0.0.1), with
#     the ips-admin allowlist (ips-admin/ in hps-system);
#   - ce_operator_api_configure: the ctrl-exec API's TLS listener for remote
#     operators on the cluster key operator_api_listen (empty: no listener);
#     the HPS auth hook lets an operator credential (hps-operator) run only
#     ips-admin scripts on ips.<domain>; ce_operator_api_apply applies a new
#     operator_api_listen without an IPS restart;
#   - ips_syslog_forward: the optional operator action that forwards this
#     IPS's syslog to a collector (cluster keys syslog_forward_host/_prefix).
#
# Callers: scripts/run-hps.sh (bring-up, root), ce_api_bring_up,
# bin/hps-syslog-forward and bin/hps-operator-api-apply.

# The agent's paths (ctrl-exec defaults) and their persistent homes under /srv,
# next to the dispatcher's (CTRL_EXEC_PERSIST_CONF/STATE).
: "${CTRL_EXEC_AGENT:=ctrl-exec-agent}"
: "${CTRL_EXEC_IPS_AGENT_ETC:=/etc/ctrl-exec-agent}"
: "${CTRL_EXEC_IPS_AGENT_STATE:=/var/lib/ctrl-exec-agent}"
: "${CTRL_EXEC_PERSIST_AGENT_CONF:=/srv/ctrl-exec/agent-conf}"
: "${CTRL_EXEC_PERSIST_AGENT_STATE:=/srv/ctrl-exec/agent-state}"
# The local agent's port. Not 7443: the IPS container shares the host's
# network (network_mode: host), and the host may run its own agent on 7443.
: "${CTRL_EXEC_IPS_AGENT_PORT:=7446}"
# Seconds to wait for the pairing request to be queued and for the certificate.
: "${CE_IPS_AGENT_PAIR_WAIT:=30}"
# The operator API (TLS) port on operator_api_listen.
: "${CTRL_EXEC_OPERATOR_API_PORT:=7445}"

# The ips-admin allowlist: one wrapper per name in ips-admin/. The input=raw
# names take their stdin as confidential input (ips-admin/ips-admin-exec).
IPS_ADMIN_SCRIPTS=(hps-onboard hps-cluster-config hps-cluster-config-apply hps-bmc hps-bmc-credential
  hps-node hps-storage hps-workload hps-workload-define hps-pins hps-ips-check hps-osvc hps-monitor
  ips-syslog-forward hps-repo hps-log hps-metrics)
IPS_ADMIN_RAW_SCRIPTS=(hps-bmc-credential hps-cluster-config-apply hps-workload-define)

_ips_admin_dir() {
  printf '%s/ips-admin\n' "${HPS_SYSTEM_BASE:-${HPS_BASE:-/srv}/hps-system}"
}

# _ce_conf_dir: the dispatcher's config dir (the auth hook's own directory).
_ce_conf_dir() {
  printf '%s\n' "${CTRL_EXEC_DISPATCHER_CONF_DIR:-/etc/ctrl-exec-dispatcher}"
}

#===============================================================================
# ips_admin_agent_name
# --------------------
# The IPS's own agent name: ips.<cluster DNS domain> (the one hostname rule,
# docs/NAMING.md; IPS-06). Prints it; returns 1 (logged) when the cluster has
# no usable domain.
#===============================================================================
ips_admin_agent_name() {
  local domain
  domain=$(cluster_dns_domain 2> /dev/null) || domain=""
  if [[ -z "$domain" ]]; then
    hps_log error "ips_admin_agent_name: the cluster has no network_dns_domain; the IPS agent is ips.<domain>"
    return 1
  fi
  fqdn_join ips "$domain"
}

#===============================================================================
# ce_ips_agent_write_config <agent-name>
# --------------------------------------
# Write (every bring-up: HPS owns these files) the agent's agent.conf and the
# ips-admin scripts.conf, and the auth hook's view of them
# ($CONF_DIR/hps-operator.conf: the agent name and the script names). The
# agent listens on CTRL_EXEC_IPS_AGENT_PORT and drops any connection that is
# not from 127.0.0.1: it listens on 127.0.0.1 only (bind, ctrl-exec >= 0.14.7)
# and, as defence in depth, drops any other source before the TLS handshake
# (allowed_ips).
#===============================================================================
ce_ips_agent_write_config() {
  local name="${1:?Usage: ce_ips_agent_write_config <agent-name>}"
  local etc="$CTRL_EXEC_IPS_AGENT_ETC" dir s mode
  dir=$(_ips_admin_dir)
  mkdir -p "$etc" || return 1

  {
    printf '# HPS-managed (ce_ips_agent_write_config): the IPS'"'"'s own agent %s.\n' "$name"
    printf '# Rewritten at every IPS start. See hps-system docs/OPERATOR.md.\n'
    printf 'port = %s\n' "$CTRL_EXEC_IPS_AGENT_PORT"
    printf 'cert = %s/agent.crt\nkey  = %s/agent.key\nca   = %s/ca.crt\n' "$etc" "$etc" "$etc"
    printf '# Only the IPS'"'"'s own dispatcher, on this host, reaches the agent: it\n'
    printf '# listens on loopback only (bind; ctrl-exec 0.14.7), and allowed_ips stays\n'
    printf '# as defence in depth.\n'
    printf 'bind = 127.0.0.1\n'
    printf 'allowed_ips = 127.0.0.1\n'
    printf 'script_dirs = %s\n' "$dir"
    printf '# No executor in the IPS image: scripts run as the agent'"'"'s user (root,\n'
    printf '# program:ctrl-exec-agent) and the profiles below are declared, not applied.\n'
    printf '\n[profile default]\nrun_as = nobody\nno_new_privileges = yes\n'
    printf '\n[profile ips-admin]\nrun_as = root\nno_new_privileges = yes\n'
  } > "$etc/agent.conf.hps-tmp" || return 1
  mv -f "$etc/agent.conf.hps-tmp" "$etc/agent.conf" || return 1

  {
    printf '# HPS-managed: the ips-admin allowlist (lib/functions.d/ips-admin-functions.sh).\n'
    for s in "${IPS_ADMIN_SCRIPTS[@]}"; do
      mode=""
      if _ips_admin_is_raw "$s"; then
        mode=" input=raw"
      fi
      printf '%s = %s/%s profile=ips-admin%s\n' "$s" "$dir" "$s" "$mode"
    done
  } > "$etc/scripts.conf.hps-tmp" || return 1
  mv -f "$etc/scripts.conf.hps-tmp" "$etc/scripts.conf" || return 1
  chmod 0640 "$etc/agent.conf" "$etc/scripts.conf" 2> /dev/null || true

  local conf_dir
  conf_dir=$(_ce_conf_dir)
  if [[ -d "$conf_dir" ]]; then
    {
      printf '# HPS-managed: read by auth-hook-hps (scripts/ctrl-exec-auth-hook.sh).\n'
      printf 'ips_agent = %s\n' "$name"
      printf 'scripts = %s\n' "${IPS_ADMIN_SCRIPTS[*]}"
    } > "$conf_dir/hps-operator.conf.tmp" || return 1
    chmod 0640 "$conf_dir/hps-operator.conf.tmp" 2> /dev/null || true
    if getent group ctrl-exec > /dev/null 2>&1; then
      chgrp ctrl-exec "$conf_dir/hps-operator.conf.tmp" 2> /dev/null || true
    fi
    mv -f "$conf_dir/hps-operator.conf.tmp" "$conf_dir/hps-operator.conf" || return 1
  fi
  return 0
}

_ips_admin_is_raw() {
  local s
  for s in "${IPS_ADMIN_RAW_SCRIPTS[@]}"; do
    [[ "$s" == "$1" ]] && return 0
  done
  return 1
}

#===============================================================================
# ips_admin_read_timeout
# ----------------------
# Seconds the dispatcher waits for the IPS's own agent to answer (the cluster
# key ips_admin_read_timeout; an integer 60..3600, default 900). A value
# outside the range is logged and the default used.
#===============================================================================
: "${IPS_ADMIN_READ_TIMEOUT_DEFAULT:=900}"
ips_admin_read_timeout() {
  local cluster value=""
  if declare -f cluster_registry > /dev/null 2>&1; then
    cluster=$(hps_get_config active_cluster 2> /dev/null) || cluster=""
    if [[ -n "$cluster" ]]; then
      value=$(cluster_registry "$cluster" get ips_admin_read_timeout 2> /dev/null) || value=""
    fi
  fi
  value="${value//\"/}"
  if [[ -z "$value" ]]; then
    printf '%s\n' "$IPS_ADMIN_READ_TIMEOUT_DEFAULT"
  elif [[ "$value" =~ ^[0-9]+$ ]] && ((10#$value >= 60 && 10#$value <= 3600)); then
    printf '%s\n' "$((10#$value))"
  else
    hps_log warn "ce_ips_agent: ips_admin_read_timeout='${value}' is not an integer 60..3600; using ${IPS_ADMIN_READ_TIMEOUT_DEFAULT}"
    printf '%s\n' "$IPS_ADMIN_READ_TIMEOUT_DEFAULT"
  fi
}


#===============================================================================
# _ce_approve_local_agent <reqid> <agent-name>
# --------------------------------------------
# The IPS approves its own agent, through the same non-interactive path as a
# node's pairing (`approve <reqid>`, ce_approve_pair_request), with its own
# guard in place of the registry binding: the pending request must carry
# exactly <agent-name> and come from 127.0.0.1. Anything else is refused and
# left pending (the node approver, or a person, decides on it).
#
# Returns: 0 approved; 1 refused or failed (logged).
#===============================================================================
_ce_approve_local_agent() {
  local reqid="$1" name="$2" req host src out
  if [[ ! "$reqid" =~ ^[a-f0-9]+$ ]]; then
    hps_log error "ce_ips_agent: malformed pairing request id '${reqid}'"
    return 1
  fi
  req=$(_ce_read_pair_request "$reqid") || {
    hps_log error "ce_ips_agent: no pending request ${reqid}"
    return 1
  }
  host=$(printf '%s' "$req" | jq -r '.hostname // ""')
  src=$(printf '%s' "$req" | jq -r '.source_ip // ""')
  if [[ "${host,,}" != "$name" ]]; then
    hps_log error "ce_ips_agent: request ${reqid} is for '${host}', not ${name}; not approved"
    return 1
  fi
  if [[ "$src" != "127.0.0.1" ]]; then
    hps_log error "ce_ips_agent: request ${reqid} for ${name} came from '${src}', not 127.0.0.1; not approved"
    return 1
  fi
  local -a rt=()
  local timeout
  # The long ips-admin jobs (publish, storage) must return their output: this
  # agent alone gets a longer read timeout (the cluster key ips_admin_read_timeout);
  # node agents keep the dispatcher's global one. Needs ctrl-exec >= 0.14.7.
  if _ce_dispatcher_at_least "$CTRL_EXEC_MIN_VERSION"; then
    timeout=$(ips_admin_read_timeout)
    rt=(--read-timeout "$timeout")
  else
    hps_log error "ce_ips_agent: ctrl-exec >= ${CTRL_EXEC_MIN_VERSION} is required for the agent's read timeout; long ips-admin jobs may time out"
  fi
  out=$("$CTRL_EXEC_DISPATCHER" approve "$reqid" --ip 127.0.0.1 --lookup-by ip \
    --agent-port "$CTRL_EXEC_IPS_AGENT_PORT" "${rt[@]}" 2>&1) || {
    hps_log error "ce_ips_agent: approve ${reqid} failed: ${out}"
    return 1
  }
  hps_log info "ce_ips_agent: approved ${reqid} for ${name} @ 127.0.0.1:${CTRL_EXEC_IPS_AGENT_PORT}"
  return 0
}

#===============================================================================
# ce_ips_agent_bring_up
# ---------------------
# Idempotent, root, after ce_dispatcher_bring_up (scripts/run-hps.sh):
#   1. /etc/ctrl-exec-agent and /var/lib/ctrl-exec-agent on /srv (persisted
#      like the dispatcher's);
#   2. the agent installed from the dispatcher tarball (install.sh --agent)
#      when ctrl-exec-agent is not on PATH;
#   3. agent.conf, the ips-admin scripts.conf and the hook's hps-operator.conf
#      (ce_ips_agent_write_config);
#   4. paired, when it has no certificate or the dispatcher does not list it:
#      a short pairing window, request-pairing to 127.0.0.1 (verified against
#      the dispatcher's own CA fingerprint) under --name ips.<domain>, the
#      guarded self-approval, the wait for the certificate, the window closed;
#   5. the hook's operator hash file restored from the keysafe
#      (hps-operator export).
# program:ctrl-exec-agent (configure-supervisor.sh) then serves it.
#
# Returns: 0 ready; 1 failed (logged; the IPS starts without ips-admin).
#===============================================================================
ce_ips_agent_bring_up() {
  local name reqid fpr waited timeout registered=0
  name=$(ips_admin_agent_name) || return 1

  _ce_persist_dir "$CTRL_EXEC_PERSIST_AGENT_CONF" "$CTRL_EXEC_IPS_AGENT_ETC" || {
    hps_log error "ce_ips_agent: cannot persist $CTRL_EXEC_IPS_AGENT_ETC"
    return 1
  }
  _ce_persist_dir "$CTRL_EXEC_PERSIST_AGENT_STATE" "$CTRL_EXEC_IPS_AGENT_STATE" || {
    hps_log error "ce_ips_agent: cannot persist $CTRL_EXEC_IPS_AGENT_STATE"
    return 1
  }

  if ! command -v "$CTRL_EXEC_AGENT" > /dev/null 2>&1; then
    _ce_tarball_install --agent || return 1
    hps_log info "ce_ips_agent: ctrl-exec-agent installed"
  fi

  ce_ips_agent_write_config "$name" || {
    hps_log error "ce_ips_agent: cannot write the agent configuration"
    return 1
  }

  if [[ -s "$CTRL_EXEC_IPS_AGENT_ETC/agent.crt" ]] && ce_agent_names 2> /dev/null | grep -qxF -- "$name"; then
    registered=1
  fi
  if [[ $registered -eq 0 ]]; then
    hps_log info "ce_ips_agent: pairing ${name} with this IPS's dispatcher"
    fpr=$("$CTRL_EXEC_DISPATCHER" ca-fingerprint 2> /dev/null) || fpr=""
    if [[ ! "$fpr" =~ ^SHA256:[0-9a-f]{64}$ ]]; then
      hps_log error "ce_ips_agent: no usable CA fingerprint from the dispatcher ('${fpr}')"
      return 1
    fi
    "$CTRL_EXEC_DISPATCHER" pairing-mode start --timeout 120 > /dev/null 2>&1 \
      || hps_log warn "ce_ips_agent: pairing-mode start failed (already open?); trying the request"
    reqid=$("$CTRL_EXEC_AGENT" request-pairing --dispatcher 127.0.0.1 --dispatcher-fingerprint "$fpr" \
      --name "$name" --background --timeout 120 2> /dev/null) || reqid=""
    reqid="${reqid//[^a-f0-9]/}"
    if [[ -z "$reqid" ]]; then
      hps_log error "ce_ips_agent: request-pairing gave no request id"
      "$CTRL_EXEC_DISPATCHER" pairing-mode stop > /dev/null 2>&1 || true
      return 1
    fi
    if ! _ce_approve_local_agent "$reqid" "$name"; then
      "$CTRL_EXEC_DISPATCHER" pairing-mode stop > /dev/null 2>&1 || true
      return 1
    fi
    waited=0
    while [[ ! -s "$CTRL_EXEC_IPS_AGENT_ETC/agent.crt" ]] && ((waited < CE_IPS_AGENT_PAIR_WAIT)); do
      sleep 1
      waited=$((waited + 1))
    done
    "$CTRL_EXEC_DISPATCHER" pairing-mode stop > /dev/null 2>&1 || true
    if [[ ! -s "$CTRL_EXEC_IPS_AGENT_ETC/agent.crt" ]]; then
      hps_log error "ce_ips_agent: approved, but no certificate arrived within ${CE_IPS_AGENT_PAIR_WAIT}s"
      return 1
    fi
    hps_log info "ce_ips_agent: ${name} paired"
  elif _ce_dispatcher_at_least "$CTRL_EXEC_MIN_VERSION"; then
    # Already registered (an earlier release, or the cluster key changed): the
    # read timeout in its registry record follows the key at every start.
    timeout=$(ips_admin_read_timeout)
    "$CTRL_EXEC_DISPATCHER" edit-agent "$name" --read-timeout "$timeout" > /dev/null 2>&1 \
      || hps_log warn "ce_ips_agent: cannot set the read timeout of ${name}"
  else
    hps_log error "ce_ips_agent: ctrl-exec >= ${CTRL_EXEC_MIN_VERSION} is required for the agent's read timeout and bind; long ips-admin jobs may time out"
  fi

  local op="${HPS_SYSTEM_BASE:-${HPS_BASE:-/srv}/hps-system}/bin/hps-operator"
  if [[ -x "$op" ]]; then
    "$op" export > /dev/null 2>&1 || hps_log warn "ce_ips_agent: hps-operator export failed; operator credentials may be refused"
  fi
  hps_log info "ce_ips_agent: ${name} ready (ips-admin on 127.0.0.1:${CTRL_EXEC_IPS_AGENT_PORT})"
  return 0
}

#===============================================================================
# ctrl-exec.conf editing (HPS-owned keys only)
#===============================================================================
# _ce_conf_set <file> <key> <value>: replace every "key = ..." line with one,
# or append it. The file keeps its mode and owner (rewritten in place).
_ce_conf_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="${file}.hps-tmp.$$"
  awk -v k="$key" -v v="$value" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { if (!done) print k " = " v; done = 1; next }
    { print }
    END { if (!done) print k " = " v }' "$file" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  cat "$tmp" > "$file" || {
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
}

# _ce_conf_unset <file> <key>...: remove the keys' lines.
_ce_conf_unset() {
  local file="$1" tmp key
  shift
  tmp="${file}.hps-tmp.$$"
  cp -- "$file" "$tmp" || return 1
  for key in "$@"; do
    awk -v k="$key" '$0 !~ "^[[:space:]]*" k "[[:space:]]*="' "$tmp" > "${tmp}.2" || return 1
    mv -f "${tmp}.2" "$tmp" || return 1
  done
  cat "$tmp" > "$file" || return 1
  rm -f "$tmp"
}

# _ce_local_ipv4s: the IPv4 addresses of this host, one per line (the kernel's
# LOCAL routes; no package needed).
_ce_local_ipv4s() {
  awk '/\/32 host LOCAL/ { print prev } { prev = $2 }' /proc/net/fib_trie 2> /dev/null | sort -u
}

# _ce_operator_api_listen: the cluster key operator_api_listen, or nothing.
_ce_operator_api_listen() {
  local cluster value
  declare -f cluster_registry > /dev/null 2>&1 || return 0
  cluster=$(hps_get_config active_cluster 2> /dev/null) || return 0
  [[ -n "$cluster" ]] || return 0
  value=$(cluster_registry "$cluster" get operator_api_listen 2> /dev/null) || value=""
  value="${value//\"/}"
  printf '%s\n' "$value"
}

# _ce_operator_api_listen_ok <ip>: a specific IPv4 address of this host. A
# loopback or wildcard bind is refused: the API would be reachable from every
# local user. (The hook no longer relies on the address: ctrl-exec 0.14.7 tells
# it the caller and the listener.)
_ce_operator_api_listen_ok() {
  local ip="$1" o
  if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    hps_log warn "ce_operator_api: operator_api_listen '${ip}' is not an IPv4 address; no operator API"
    return 1
  fi
  for o in "${BASH_REMATCH[@]:1}"; do
    if ((10#$o > 255)); then
      hps_log warn "ce_operator_api: operator_api_listen '${ip}' is not an IPv4 address; no operator API"
      return 1
    fi
  done
  case "$ip" in
    127.* | 0.0.0.0 | 255.255.255.255)
      hps_log warn "ce_operator_api: operator_api_listen '${ip}' is a loopback or wildcard address; it must be one address of this IPS; no operator API"
      return 1 ;;
  esac
  if ! _ce_local_ipv4s | grep -qxF -- "$ip"; then
    hps_log warn "ce_operator_api: operator_api_listen ${ip} is not an address of this host; no operator API"
    return 1
  fi
  return 0
}

#===============================================================================
# _ce_operator_api_cert <ip>
# --------------------------
# The API's TLS certificate for <ip>: self-signed (it is its own trust
# anchor; the operator's credential carries it as the --ca), subjectAltName
# IP:<ip>, 10 years. Kept while it names <ip> and has 30 days left; made anew
# otherwise (then every operator needs `hps-operator ca` again). The key is
# root:ctrl-exec 0640 (the API runs as ctrl-exec).
#===============================================================================
_ce_operator_api_cert() {
  local ip="$1" dir crt key
  dir=$(_ce_conf_dir)
  crt="$dir/hps-api-tls.crt"
  key="$dir/hps-api-tls.key"
  if [[ -s "$crt" && -s "$key" ]] \
    && openssl x509 -in "$crt" -noout -checkend 2592000 > /dev/null 2>&1 \
    && openssl x509 -in "$crt" -noout -ext subjectAltName 2> /dev/null | grep -qE "^[[:space:]]*IP Address:${ip//./\\.}\$"; then
    return 0
  fi
  hps_log info "ce_operator_api: making the API TLS certificate for ${ip}"
  local old_umask
  old_umask=$(umask)
  umask 027
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
    -subj "/CN=hps-operator-api" -addext "subjectAltName=IP:${ip}" \
    -keyout "$key.tmp" -out "$crt.tmp" > /dev/null 2>&1; then
    umask "$old_umask"
    rm -f "$key.tmp" "$crt.tmp"
    hps_log error "ce_operator_api: openssl could not make the certificate"
    return 1
  fi
  umask "$old_umask"
  chmod 0640 "$key.tmp"
  chmod 0644 "$crt.tmp"
  if getent group ctrl-exec > /dev/null 2>&1; then
    chgrp ctrl-exec "$key.tmp" 2> /dev/null || true
  fi
  mv -f "$key.tmp" "$key"
  mv -f "$crt.tmp" "$crt"
  return 0
}

#===============================================================================
# ce_operator_api_configure <ctrl-exec.conf>
# -----------------------------------------
# Called by ce_api_bring_up. With operator_api_listen set to an address of
# this IPS: api_port (CTRL_EXEC_OPERATOR_API_PORT), api_bind, api_tls_cert and
# api_tls_key, so the API listens with TLS on that address only (the unix
# socket stays). Otherwise api_port = off and those keys are removed. The API
# reads its config at start: a change takes effect when ctrl-exec-api restarts
# (the next IPS start).
#===============================================================================
ce_operator_api_configure() {
  local conf="$1" listen dir
  dir=$(_ce_conf_dir)
  listen=$(_ce_operator_api_listen)
  if [[ -n "$listen" ]] && _ce_operator_api_listen_ok "$listen" && _ce_operator_api_cert "$listen"; then
    _ce_conf_set "$conf" api_port "$CTRL_EXEC_OPERATOR_API_PORT" || return 1
    _ce_conf_set "$conf" api_bind "$listen" || return 1
    _ce_conf_set "$conf" api_tls_cert "$dir/hps-api-tls.crt" || return 1
    _ce_conf_set "$conf" api_tls_key "$dir/hps-api-tls.key" || return 1
    hps_log info "ce_operator_api: operator API on https://${listen}:${CTRL_EXEC_OPERATOR_API_PORT}"
    return 0
  fi
  _ce_conf_set "$conf" api_port off || return 1
  _ce_conf_unset "$conf" api_bind api_tls_cert api_tls_key || return 1
  return 0
}

#===============================================================================
# ce_operator_api_apply
# ---------------------
# Apply operator_api_listen now instead of at the next IPS start: the start
# step (ce_api_bring_up, which configures the TLS listener and its
# certificate), a check that it left api_bind on that address, then a restart
# of program:ctrl-exec-api, which reads its config only at start. The rest of
# the IPS keeps running. Called by bin/hps-operator-api-apply (the CNH's
# cnh-ips-operator-init runs that in the IPS container).
#
# Prints the operator API URL on stdout; everything else on stderr.
# Returns: 0 the API restarted on operator_api_listen; 3 the key is unset, or
# the IPS left the listener off (not an address of this IPS, loopback or
# wildcard, ctrl-exec too old: ce_operator_api / ce_api_bring_up log why);
# 1 bring-up or the restart failed.
#===============================================================================
ce_operator_api_apply() {
  local listen conf bind sv
  listen=$(_ce_operator_api_listen)
  if [[ -z "$listen" ]]; then
    echo "hps-operator-api-apply: operator_api_listen is unset; set it first (hps-cluster-config set operator_api_listen <address>)" >&2
    return 3
  fi
  if ! ce_api_bring_up; then
    echo "hps-operator-api-apply: ce_api_bring_up failed (see the IPS syslog)" >&2
    return 1
  fi
  conf="${CTRL_EXEC_DISPATCHER_CONF:-$(_ce_conf_dir)/ctrl-exec.conf}"
  bind=$(awk '/^[[:space:]]*api_bind[[:space:]]*=/ { sub(/^[^=]*=/, ""); gsub(/[[:space:]]/, ""); print; exit }' "$conf" 2> /dev/null) || bind=""
  if [[ "$bind" != "$listen" ]]; then
    echo "hps-operator-api-apply: the IPS left the operator API off for ${listen} (see its syslog, ce_operator_api)" >&2
    return 3
  fi
  sv=$(hps_get_config supervisord_conf 2> /dev/null) || sv=""
  if [[ -z "$sv" ]]; then
    echo "hps-operator-api-apply: no supervisord_conf; the API picks the listener up at the next IPS start" >&2
    return 1
  fi
  if ! supervisorctl -c "$sv" restart ctrl-exec-api >&2; then
    echo "hps-operator-api-apply: ctrl-exec-api did not restart (supervisorctl)" >&2
    return 1
  fi
  hps_log info "ce_operator_api: applied, operator API on https://${listen}:${CTRL_EXEC_OPERATOR_API_PORT}"
  echo "operator API: https://${listen}:${CTRL_EXEC_OPERATOR_API_PORT}"
}

#===============================================================================
# ips_syslog_forward <ipv4> <prefix> | off | show
# -----------------------------------------------
# Optional operator action (ips-admin script ips-syslog-forward): forward
# every message this IPS's rsyslog receives or logs to a collector at <ipv4>
# (TCP 514), host names as <prefix>.<hostname>, so a collector holding several
# clusters tells them apart. Kept in the cluster keys syslog_forward_host and
# syslog_forward_prefix, so it survives an IPS restart; the rsyslog config is
# regenerated (create_config_rsyslog) and rsyslogd restarted. Off by default;
# `off` removes both keys.
#
# Returns: 0 done; 2 usage; 1 failed.
#===============================================================================
ips_syslog_forward() {
  local cluster ip prefix sv
  cluster=$(hps_get_config active_cluster 2> /dev/null) || cluster=""
  if [[ -z "$cluster" ]]; then
    echo "ips-syslog-forward: no active cluster" >&2
    return 1
  fi
  case "${1:-}" in
    show)
      ip=$(cluster_registry "$cluster" get syslog_forward_host 2> /dev/null) || ip=""
      prefix=$(cluster_registry "$cluster" get syslog_forward_prefix 2> /dev/null) || prefix=""
      ip="${ip//\"/}"
      prefix="${prefix//\"/}"
      if [[ -n "$ip" ]]; then
        echo "syslog forward: ${ip} (tcp 514) as ${prefix}.<host>"
      else
        echo "syslog forward: off"
      fi
      return 0 ;;
    off)
      [[ $# -eq 1 ]] || { echo "usage: ips-syslog-forward <ipv4> <prefix> | off | show" >&2; return 2; }
      cluster_registry "$cluster" delete syslog_forward_host > /dev/null 2>&1 || true
      cluster_registry "$cluster" delete syslog_forward_prefix > /dev/null 2>&1 || true
      hps_log info "ips-syslog-forward: off" ;;
    *)
      if [[ $# -ne 2 ]]; then
        echo "usage: ips-syslog-forward <ipv4> <prefix> | off | show" >&2
        return 2
      fi
      ip="$1"
      prefix="$2"
      if ! _rsyslog_forward_valid "$ip" "$prefix"; then
        echo "ips-syslog-forward: <ipv4> must be an IPv4 address other than loopback; <prefix> 1-32 of a-z 0-9 - (starting with a letter or digit)" >&2
        return 2
      fi
      cluster_registry "$cluster" set syslog_forward_host "$ip" || return 1
      cluster_registry "$cluster" set syslog_forward_prefix "$prefix" || return 1
      hps_log info "ips-syslog-forward: everything to ${ip} as ${prefix}.<host>" ;;
  esac
  create_config_rsyslog || {
    echo "ips-syslog-forward: the rsyslog config could not be regenerated" >&2
    return 1
  }
  sv=$(hps_get_config supervisord_conf 2> /dev/null) || sv=""
  if [[ -n "$sv" ]] && ! supervisorctl -c "$sv" restart rsyslogd > /dev/null 2>&1; then
    echo "ips-syslog-forward: rsyslogd did not restart (supervisorctl); the change applies at the next start" >&2
  fi
  ips_syslog_forward show
}
