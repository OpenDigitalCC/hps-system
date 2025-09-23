__guard_source || return

## HPS Functions



#===============================================================================
# hps_configure_opensvc_cluster
# ------------------------------
# Configure OpenSVC cluster identity after services have started.
#
# Behaviour:
#   - Waits for OpenSVC daemon socket to be ready
#   - Calls osvc_configure_cluster_identity if daemon is responsive
#   - Logs warning if configuration fails (non-fatal)
#
# Returns:
#   0 always (failures are logged but don't block service startup)
#===============================================================================
hps_configure_opensvc_cluster() {
  # Wait for daemon socket (more reliable than process check)
  local i
  for i in {1..15}; do
    if [[ -S /var/lib/opensvc/lsnr/http.sock ]] && om cluster status >/dev/null 2>&1; then
      hps_log info "OpenSVC daemon responsive, configuring cluster identity"
      osvc_configure_cluster_identity || {
        hps_log warn "OpenSVC cluster identity configuration failed"
      }
      return 0
    fi
    sleep 1
  done
  
  hps_log info "OpenSVC daemon not ready after 15s, skipping cluster configuration"
  return 0
}


#===============================================================================
# osvc_configure_cluster_identity
# --------------------------------
# Configure cluster identity after OpenSVC daemon is running.
# Called by hps_services_restart after supervisord starts opensvc service.
#
# Behaviour:
#   - Waits for daemon socket to be ready
#   - Sets cluster.name from CLUSTER_NAME
#   - Sets node.name=ips
#   - Configures heartbeat type
#   - Generates and sets cluster.secret
#   - Stores cluster.secret to cluster_config
#
# Returns:
#   0 on success
#   1 if configuration fails
#===============================================================================
osvc_configure_cluster_identity() {
  hps_log info "Configuring OpenSVC cluster identity"
  
  # Wait for socket to be ready (already done by caller, but belt-and-suspenders)
  local i
  for i in {1..10}; do
    if [[ -S /var/lib/opensvc/lsnr/http.sock ]]; then
      break
    fi
    sleep 1
  done
  
  # Verify daemon is responsive (use om command, not pgrep)
  if ! om cluster status >/dev/null 2>&1; then
    hps_log error "Daemon not responsive"
    return 1
  fi
  
  # Get cluster name
  local cluster_name
  cluster_name="$(cluster_config get CLUSTER_NAME 2>/dev/null)"
  
  if [[ -z "${cluster_name}" ]]; then
    hps_log error "CLUSTER_NAME not set in cluster_config"
    return 1
  fi
  
  # Set cluster name
  om cluster set --kw "cluster.name=${cluster_name}" || {
    hps_log error "Failed to set cluster.name"
    return 1
  }
  
  # Set node name (IPS-specific)
  om node set --kw "node.name=ips" || {
    hps_log error "Failed to set node.name"
    return 1
  }
  
  # Configure heartbeat
  local hb_type
  hb_type="$(cluster_config get OSVC_HB_TYPE 2>/dev/null || echo multicast)"
  
  om cluster set --kw "hb#1.type=${hb_type}" || {
    hps_log error "Failed to set hb type"
    return 1
  }
  
  # Get or generate cluster secret
  local cluster_secret
  cluster_secret="$(cluster_config get OPENSVC_CLUSTER_SECRET 2>/dev/null || true)"
  
  if [[ -z "${cluster_secret}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      cluster_secret="$(openssl rand -hex 16)"
    else
      cluster_secret="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    fi
    
    cluster_config set OPENSVC_CLUSTER_SECRET "${cluster_secret}"
    hps_log info "Generated and stored OPENSVC_CLUSTER_SECRET"
  fi
  
  # Set cluster secret
  om cluster set --kw "cluster.secret=${cluster_secret}" || {
    hps_log error "Failed to set cluster.secret"
    return 1
  }
  
  hps_log info "Cluster identity configured: name=${cluster_name}, node=ips, hb=${hb_type}"
  return 0
}




#===============================================================================
# osvc_bootstrap_cluster_on_ips
# ------------------------------
# Initialize OpenSVC cluster on IPS provisioning node (cluster founder).
#
# Behaviour:
#   - Calls create_config_opensvc to generate opensvc.conf and enforce agent.key
#   - Starts OpenSVC daemon via supervisord
#   - Creates initial cluster configuration:
#     * Sets cluster.name from CLUSTER_NAME
#     * Sets node.name=ips
#     * Configures heartbeat (multicast by default)
#     * Sets cluster.secret for node authentication
#   - Stores cluster.secret to cluster_config as OPENSVC_CLUSTER_SECRET
#
# Returns:
#   0 on success
#   1 if configuration fails
#   2 if daemon not running after setup
#===============================================================================
osvc_bootstrap_cluster_on_ips() {
  hps_log info "[opensvc] Bootstrapping cluster on IPS"
  
  # 1. Generate config and enforce key
  local ips_role
  ips_role="$(cluster_config get OSVC_IPS_ROLE 2>/dev/null || echo provisioning)"
  
  if ! create_config_opensvc "${ips_role}"; then
    hps_log error "[opensvc] create_config_opensvc failed"
    return 1
  fi
  
  # 2. Start daemon via supervisord
  supervisorctl -c /srv/hps-config/services/supervisord.conf start opensvc
  sleep 3
  
  if ! pgrep -f "om daemon run" >/dev/null 2>&1; then
    hps_log error "[opensvc] Daemon failed to start"
    return 2
  fi
  
  # 3. Configure cluster settings
  local cluster_name
  cluster_name="$(cluster_config get CLUSTER_NAME 2>/dev/null)"
  
  if [[ -z "${cluster_name}" ]]; then
    hps_log error "[opensvc] CLUSTER_NAME not set in cluster_config"
    return 1
  fi
  
  # Set cluster name
  om cluster set --kw "cluster.name=${cluster_name}" || {
    hps_log error "[opensvc] Failed to set cluster.name"
    return 1
  }
  
  # Set node name (IPS-specific)
  om node set --kw "node.name=ips" || {
    hps_log error "[opensvc] Failed to set node.name"
    return 1
  }
  
  # Configure heartbeat
  local hb_type
  hb_type="$(cluster_config get OSVC_HB_TYPE 2>/dev/null || echo multicast)"
  
  om cluster set --kw "hb#1.type=${hb_type}" || {
    hps_log error "[opensvc] Failed to set hb type"
    return 1
  }
  
  # Get or generate cluster secret
  local cluster_secret
  cluster_secret="$(cluster_config get OPENSVC_CLUSTER_SECRET 2>/dev/null || true)"
  
  if [[ -z "${cluster_secret}" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      cluster_secret="$(openssl rand -hex 16)"
    else
      cluster_secret="$(tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
    fi
    
    cluster_config set OPENSVC_CLUSTER_SECRET "${cluster_secret}"
    hps_log info "[opensvc] Generated and stored OPENSVC_CLUSTER_SECRET"
  fi
  
  # Set cluster secret
  om cluster set --kw "cluster.secret=${cluster_secret}" || {
    hps_log error "[opensvc] Failed to set cluster.secret"
    return 1
  }
  
  # Verify daemon is responsive
  if ! om cluster status >/dev/null 2>&1; then
    hps_log error "[opensvc] Daemon not responsive after bootstrap"
    return 2
  fi
  
  hps_log info "[opensvc] Cluster bootstrapped: name=${cluster_name}, node=ips"
  return 0
}

#:name: _ini_get_agent_nodename
#:group: opensvc
#:synopsis: Extract [agent] nodename from an opensvc.conf
#:usage: _ini_get_agent_nodename /etc/opensvc/opensvc.conf
_ini_get_agent_nodename() {
  local f="${1:?usage: _ini_get_agent_nodename <file>}"
  awk -F= '
    /^\[agent\]/ { agent_section=1; next }
    agent_section && $1 ~ /^[ \t]*nodename[ \t]*$/ {
      v=$2; sub(/^[ \t]*/,"",v); sub(/[ \t]*$/,"",v); print v; exit
    }
    /^\[/ { agent_section=0 }
  ' "$f"
}

#:name: _osvc_kv_set
#:group: opensvc
#:synopsis: Set an OpenSVC v3 key using om config set key=value
#:usage: _osvc_kv_set key value
_osvc_kv_set() {
  local k="${1:?key}" v="${2:?value}"
  om config set "${k}=${v}"
}




#:name: _osvc_kv_set
#:group: opensvc
#:synopsis: Set an OpenSVC v3 key using om config set --kw key=value
#:usage: _osvc_kv_set key value
_osvc_kv_set() {
  local k="${1:?key}" v="${2:?value}"
  om config set --kw "${k}=${v}"
}

#:name: generate_opensvc_conf
#:group: opensvc
#:synopsis: Emit an OpenSVC v3 opensvc.conf to STDOUT (does NOT write to disk).
#:usage: generate_opensvc_conf [<ips_role>]
#:description:
#  Origin identity is $(hps_origin_tag). IPS is container-resident and not in host_config:
#    - TYPE forced to IPS
#    - nodename forced to "ips"
#  Non-IPS: nodename from host_config "<origin>" HOSTNAME; fallback to sanitized origin.
#  Cluster-scope options read from cluster_config.
generate_opensvc_conf() {
  local ips_role="${1:-}"

  local origin; origin="$(hps_origin_tag)"

  # Host-scoped
  local osvc_nodename osvc_type osvc_tags
  osvc_type="$(host_config "$origin" get TYPE 2>/dev/null || true)"

  if [[ "${osvc_type^^}" == "IPS" || -z "$osvc_type" && "${origin,,}" == "ips" ]]; then
    osvc_type="IPS"
    osvc_nodename="ips"   # stable in-container name
  else
    osvc_nodename="$(host_config "$origin" get HOSTNAME 2>/dev/null || true)"
    [[ -z "$osvc_nodename" ]] && osvc_nodename="$(echo "$origin" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  fi

  # IPS role: CLI > host_config > cluster_config > default
  [[ -z "$ips_role" ]] && ips_role="$(host_config "$origin" get IPS_ROLE 2>/dev/null || true)"
  [[ -z "$ips_role" ]] && ips_role="$(cluster_config get OSVC_IPS_ROLE 2>/dev/null || true)"
  [[ -z "$ips_role" ]] && ips_role="provisioning"

  case "${osvc_type^^}" in
    IPS)     osvc_tags="ips ${ips_role,,}" ;;  # controller/dispatcher only
    SCH)     osvc_tags="storage zfs" ;;
    TCH|CCH) osvc_tags="compute" ;;
    "")      osvc_tags="" ;;
    *)       osvc_tags="$(echo "$osvc_type" | tr '[:upper:]' '[:lower:]')" ;;
  esac

  # Cluster-scoped
  local osvc_log_level osvc_listener_port osvc_web_ui osvc_web_port osvc_hb_interval osvc_hb_timeout
  local osvc_templates_url osvc_packages_url
  osvc_log_level="$(cluster_config get OSVC_LOG_LEVEL 2>/dev/null || echo info)"
  osvc_listener_port="$(cluster_config get OSVC_LISTENER_PORT 2>/dev/null || echo 7024)"
  osvc_web_ui="$(cluster_config get OSVC_WEB_UI 2>/dev/null || echo yes)"
  osvc_web_port="$(cluster_config get OSVC_WEB_PORT 2>/dev/null || echo 7023)"
  osvc_hb_interval="$(cluster_config get OSVC_HB_INTERVAL 2>/dev/null || echo 5)"
  osvc_hb_timeout="$(cluster_config get OSVC_HB_TIMEOUT 2>/dev/null || echo 15)"
  osvc_templates_url="$(cluster_config get OSVC_TEMPLATES_URL 2>/dev/null || echo)"
  osvc_packages_url="$(cluster_config get OSVC_PACKAGES_URL 2>/dev/null || echo)"

  # Static paths
  local conf_dir="/etc/opensvc"
  local var_dir="/var/lib/opensvc"
  local log_file="/var/log/opensvc/agent.log"
  local auth_key_file="/etc/opensvc/agent.key"

  cat <<EOF
# OpenSVC v3 Agent Node Configuration (generated by HPS)

[agent]
nodename = ${osvc_nodename}
tags = ${osvc_tags}
conf_dir = ${conf_dir}
var_dir = ${var_dir}
log_file = ${log_file}
log_level = ${osvc_log_level}
listener_port = ${osvc_listener_port}
web_ui = ${osvc_web_ui}
web_ui_port = ${osvc_web_port}
hb_interval = ${osvc_hb_interval}
hb_timeout  = ${osvc_hb_timeout}
auth_key_file = ${auth_key_file}

[repo]
templates_url = ${osvc_templates_url}
packages_url  = ${osvc_packages_url}

[stats]
enable = yes
push_interval = 60
EOF
install_opensvc_foreground_wrapper
}



#===============================================================================
# osvc_apply_identity_from_hps
# -----------------------------
# Enforce IPS node.name and set cluster.name from HPS CLUSTER_NAME (OpenSVC v3).
#
# Behaviour:
#   - If /etc/opensvc/opensvc.conf nodename == "ips", set node.name=ips in v3 KV.
#   - Always set cluster.name=<CLUSTER_NAME> from HPS cluster_config.
#   - Skips silently if daemon is not running (will be configured post-start)
#
# Returns:
#   0 on success or if daemon not running
#   1 on error
#===============================================================================
osvc_apply_identity_from_hps() {
  local conf="/etc/opensvc/opensvc.conf"
  [[ -r "$conf" ]] || { hps_log error "missing $conf"; return 1; }

  local nn; nn="$(_ini_get_agent_nodename "$conf")"
  if [[ -z "$nn" ]]; then
    hps_log error "nodename not found in $conf [agent]"; return 1
  fi

  # Only try to set if daemon is running
  if ! om cluster status >/dev/null 2>&1; then
    hps_log debug "Daemon not running, identity will be configured post-start"
    return 0
  fi

  if [[ "$nn" == "ips" ]]; then
    _osvc_kv_set "node.name" "$nn" || hps_log warn "failed to set node.name=${nn}"
  fi

  local cn; cn="$(cluster_config get CLUSTER_NAME 2>/dev/null || true)"
  if [[ -n "$cn" ]]; then
    _osvc_kv_set "cluster.name" "$cn" || hps_log warn "failed to set cluster.name=${cn}"
  else
    hps_log warn "CLUSTER_NAME not found; cluster.name not set"
  fi
}





#:name: install_opensvc_foreground_wrapper
#:group: opensvc
#:synopsis: Install /usr/local/sbin/opensvc-foreground to run the OpenSVC v3 daemon in foreground with clean logs.
#:usage: install_opensvc_foreground_wrapper
#:description:
#  Writes an exec wrapper that:
#    - ensures runtime dirs (/run/opensvc, /var/log/opensvc, /var/lib/opensvc, ${HPS_LOG_DIR}) exist
#    - verifies /etc/opensvc/agent.key exists and is non-empty (fails fast otherwise)
#    - execs 'om daemon run' (OpenSVC v3) in the foreground
#    - funnels agent stdout/stderr to ${HPS_LOG_DIR}/opensvc.{out,err}.log
#    - filters the noisy "zerolog … journal/socket" lines from stderr (no journald in container)
#  Notes:
#    - Idempotent: only rewrites the file if content changed.
#    - No supervisorctl calls; service control is handled elsewhere.
install_opensvc_foreground_wrapper() {
  local target="/usr/local/sbin/opensvc-foreground"
  local logdir="${HPS_LOG_DIR:-/srv/hps-system/log}"

  mkdir -p "$(dirname "$target")" "$logdir"

  # Desired wrapper content
  local tmp
  tmp="$(mktemp "${target}.XXXXXX")" || { hps_log error "[opensvc] mktemp failed"; return 1; }
  cat >"$tmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Use HPS log dir if provided, fallback otherwise.
LOGDIR="${HPS_LOG_DIR:-/srv/hps-system/log}"

# Preflight: required directories (ok if already exist)
mkdir -p /run/opensvc /var/log/opensvc /var/lib/opensvc "${LOGDIR}"

# Preflight: agent key must exist and be non-empty
if [[ ! -s /etc/opensvc/agent.key ]]; then
  echo "[opensvc] FATAL: /etc/opensvc/agent.key missing or empty" >&2
  exit 2
fi

# Run the v3 daemon in foreground so a supervisor can manage it if desired.
# Filter the noisy journald error lines from stderr; keep everything else.
# Agent also writes its own file log as configured in /etc/opensvc/opensvc.conf.
exec /usr/bin/om daemon run \
  1>>"${LOGDIR}/opensvc.out.log" \
  2> >(stdbuf -o0 awk '!/zerolog: could not write event: write unixgram .*journal\/socket/' >> "${LOGDIR}/opensvc.err.log")
EOF

  chmod 0755 "$tmp"

  # Idempotent install: only replace if content differs
  if [[ -f "$target" ]]; then
    if cmp -s "$tmp" "$target"; then
      rm -f "$tmp"
      hps_log info "[opensvc] Wrapper already current: ${target}"
      return 0
    fi
  fi

  mv -f "$tmp" "$target"
  hps_log info "[opensvc] Installed wrapper: ${target}"
}








