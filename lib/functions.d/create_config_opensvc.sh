__guard_source || return
# Define your functions below


#:name: create_config_opensvc
#:group: opensvc
#:synopsis: Create /etc/opensvc/opensvc.conf on disk using generate_opensvc_conf.
#:usage: create_config_opensvc [<ips_role>]
#:description:
#  Writes /etc/opensvc/opensvc.conf atomically from generate_opensvc_conf output.
#  Ensures /etc/opensvc/agent.key exists:
#    - IPS nodes => static "ips-default-key" (placeholder; replace later).
#    - Others    => cluster_config OSVC_AUTH_KEY or a random fallback.
#  Reloads OpenSVC via supervisor if present.
create_config_opensvc() {
  local ips_role="${1:-}"

  local conf_dir="/etc/opensvc"
  local conf_file="${conf_dir}/opensvc.conf"
  local log_dir="/var/log/opensvc"
  local var_dir="/var/lib/opensvc"
  local key_file="${conf_dir}/agent.key"

  mkdir -p "${conf_dir}" "${log_dir}" "${var_dir}"

  # Generate to temp file
  local tmp
  tmp="$(mktemp "${conf_file}.XXXXXX")" || { hps_log error "[opensvc] mktemp failed"; return 1; }
  if ! generate_opensvc_conf "${ips_role}" > "${tmp}"; then
    hps_log error "[opensvc] generate_opensvc_conf failed"
    rm -f "${tmp}"
    return 1
  fi

  # Backup existing file if present
  if [[ -s "${conf_file}" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "${conf_file}" "${conf_file}.bak-${ts}" || true
  fi

  mv -f "${tmp}" "${conf_file}"
  chmod 0644 "${conf_file}"
  chown root:root "${conf_file}"

  # --- Decide IPS vs non-IPS by inspecting the generated config ---
  local is_ips=0
  if grep -qE '^[[:space:]]*tags[[:space:]]*=[[:space:]]*ips(\b|[[:space:]])' "${conf_file}"; then
    is_ips=1
  elif grep -qE '^[[:space:]]*nodename[[:space:]]*=[[:space:]]*ips[[:space:]]*$' "${conf_file}"; then
    is_ips=1
  fi

  # --- Write auth key ---
  local osvc_key=""
  if (( is_ips )); then
    # IPS nodes: static placeholder for now (replace later with real generator/assignment).
    osvc_key="ips-default-key"
  else
    osvc_key="$(cluster_config get OSVC_AUTH_KEY 2>/dev/null || true)"
    if [[ -z "${osvc_key}" ]]; then
      # Generate a key to allow agent startup when cluster doesn't provide one.
      if command -v openssl >/dev/null 2>&1; then
        osvc_key="$(openssl rand -hex 32)"
      else
        osvc_key="$(tr -dc 'A-Fa-f0-9' </dev/urandom | head -c 64 || true)"
        [[ -z "${osvc_key}" ]] && osvc_key="generated-fallback-key"
      fi
      hps_log warn "[opensvc] OSVC_AUTH_KEY not set in cluster; generated a local key."
    fi
  fi

  printf '%s\n' "${osvc_key}" > "${key_file}"
  chmod 0600 "${key_file}"
  chown root:root "${key_file}"

  hps_log info "[opensvc] Wrote ${conf_file} and ${key_file}"
}








