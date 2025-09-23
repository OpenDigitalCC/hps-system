__guard_source || return
# Define your functions below

## HPS Functions

#:name: create_config_opensvc
#:group: opensvc
#:synopsis: Write /etc/opensvc/opensvc.conf and enforce a single cluster OPENSVC_AGENT_KEY (no silent overwrite).
#:usage: create_config_opensvc [<ips_role>]
#:description:
#  - Atomically writes opensvc.conf from generate_opensvc_conf.
#  - Ensures /etc/opensvc/agent.key matches the cluster key policy:
#      * If OPENSVC_AGENT_KEY exists in cluster_config:
#          - If /etc/opensvc/agent.key exists and DIFFERS -> REFUSE and return non-zero.
#          - Else write/normalize /etc/opensvc/agent.key to the cluster value.
#      * If OPENSVC_AGENT_KEY is NOT set:
#          - If /etc/opensvc/agent.key exists and is non-empty -> ADOPT it into cluster_config.
#          - Else generate a new key, store to cluster_config, then write to disk.
#  - Calls osvc_apply_identity_from_hps (sets node.name for IPS, cluster.name for all).
# Write /etc/opensvc/opensvc.conf and enforce agent key.
# This is Phase 1: runs BEFORE supervisord starts opensvc service.
#
# Behaviour:
#   - Generates opensvc.conf from cluster config
#   - Enforces OPENSVC_AGENT_KEY policy
#   - Does NOT start daemon or configure cluster (no daemon running yet)
#   - Only prepares files for when supervisord starts the service
create_config_opensvc() {
  local ips_role="${1:-}"

  local conf_dir="/etc/opensvc"
  local conf_file="${conf_dir}/opensvc.conf"
  local log_dir="/var/log/opensvc"
  local var_dir="/var/lib/opensvc"
  local key_file="${conf_dir}/agent.key"

  mkdir -p "${conf_dir}" "${log_dir}" "${var_dir}"

  # Generate opensvc.conf to temp then atomic move
  local tmp; tmp="$(mktemp "${conf_file}.XXXXXX")" || { hps_log error "mktemp failed"; return 1; }
  if ! generate_opensvc_conf "${ips_role}" > "${tmp}"; then
    hps_log error "generate_opensvc_conf failed"; rm -f "${tmp}"; return 1
  fi
  if [[ -s "${conf_file}" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; cp -a "${conf_file}" "${conf_file}.bak-${ts}" || true
  fi
  mv -f "${tmp}" "${conf_file}"
  chmod 0644 "${conf_file}"; chown root:root "${conf_file}"

  # --- Enforce single cluster agent key policy ---
  # Read cluster key (if any)
  local cluster_key
  cluster_key="$(cluster_config get OPENSVC_AGENT_KEY 2>/dev/null || true)"
  cluster_key="${cluster_key//$'\r'/}"           # strip CR
  cluster_key="${cluster_key## }"; cluster_key="${cluster_key%% }"  # trim spaces

  # Read existing on-disk key (if any)
  local disk_key=""
  if [[ -s "${key_file}" ]]; then
    disk_key="$(head -n1 "${key_file}" 2>/dev/null || true)"
    disk_key="${disk_key//$'\r'/}"
    disk_key="${disk_key## }"; disk_key="${disk_key%% }"
  fi

  if [[ -n "${cluster_key}" ]]; then
    # Cluster has a canonical key → disk must match or we refuse.
    if [[ -n "${disk_key}" && "${disk_key}" != "${cluster_key}" ]]; then
      hps_log error "Refusing to overwrite ${key_file}: differs from cluster OPENSVC_AGENT_KEY"
      hps_log error "disk_key=$(printf '%.8s' "${disk_key}")… cluster_key=$(printf '%.8s' "${cluster_key}")…"
      hps_log error "Resolve mismatch: update cluster_config or replace ${key_file} manually, then rerun."
      return 2
    fi
    # Write/normalize the disk key to the cluster value
    printf '%s\n' "${cluster_key}" > "${key_file}"
    chmod 0600 "${key_file}"; chown root:root "${key_file}"
    hps_log info "Applied cluster OPENSVC_AGENT_KEY to ${key_file}"
  else
    # No cluster key yet → adopt or generate, then persist to cluster_config
    if [[ -n "${disk_key}" ]]; then
      cluster_config set OPENSVC_AGENT_KEY "${disk_key}"
      hps_log info "Adopted existing ${key_file} into cluster_config OPENSVC_AGENT_KEY"
    else
      local new_key
      if command -v openssl >/dev/null 2>&1; then
        new_key="$(openssl rand -hex 32)"
      else
        new_key="$(tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 64 || true)"
        [[ -z "${new_key}" ]] && new_key="generated-fallback-key"
      fi
      cluster_config set OPENSVC_AGENT_KEY "${new_key}"
      printf '%s\n' "${new_key}" > "${key_file}"
      chmod 0600 "${key_file}"; chown root:root "${key_file}"
      hps_log info "Generated and stored new OPENSVC_AGENT_KEY; wrote ${key_file}"
    fi
  fi

  # Apply node/cluster identity (v3)
  osvc_apply_identity_from_hps || true

  hps_log info "wrote ${conf_file}; key policy enforced"
}










