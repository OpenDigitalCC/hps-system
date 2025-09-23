
## NODE Functions

# Initialise OpenSVC cluster settings on this node from HPS configs
initialise_opensvc_cluster() {
  local cluster_name node_tags rc unit

  remote_log "Initialising OpenSVC cluster"

  # --- 1) Read desired values from HPS configs ---
  cluster_name="$(remote_cluster_variable CLUSTER_NAME 2>/dev/null || true)"
  if [[ -z "$cluster_name" ]]; then
    remote_log "CLUSTER_NAME not found in cluster_config; aborting."
    return 1
  fi
  # TYPE -> tags (leave as-is if you already store proper tags)
  node_tags="$(remote_host_variable TYPE 2>/dev/null || true)"
  [[ -n "$node_tags" ]] && node_tags="$(echo "$node_tags" | tr '[:upper:]' '[:lower:]')"

  # --- 2) Apply cluster name (idempotent-friendly: just set; agent handles no-op) ---
  _osvc_run "set cluster.name=${cluster_name}" \
    om cluster set --kw "cluster.name=${cluster_name}" || return 1

  # --- 3) Apply node tags (optional) ---
  if [[ -n "$node_tags" ]]; then
    _osvc_run "set node tags=${node_tags}" \
      om node set --kw "tags=${node_tags}" || return 1
  else
    remote_log "No TYPE in host_config; skipping node tags"
  fi

  # --- 4) Restart OpenSVC daemon (try systemd units first, then 'om daemon') ---
  rc=1
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opensvc-server opensvc opensvc-agent; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${unit}.service"; then
        if _osvc_run "restart ${unit}.service" systemctl restart "${unit}.service"; then
          rc=0; break
        fi
      fi
    done
  fi
  if (( rc != 0 )); then
    if om daemon running >/dev/null 2>&1; then
      _osvc_run "restart opensvc daemon" om daemon restart || \
      _osvc_run "start opensvc daemon"   om daemon start
      rc=$?
    else
      _osvc_run "start opensvc daemon" om daemon start
      rc=$?
    fi
  fi
  (( rc == 0 )) || { remote_log "Warning: failed to restart OpenSVC daemon"; return 1; }

  remote_log "OpenSVC cluster initialisation complete: cluster='${cluster_name}' tags='${node_tags:-none}'"
}



# Fetch opensvc.conf from boot_manager and apply safely
load_opensvc_conf() {
  local conf_dir="/etc/opensvc"
  local conf_file="${conf_dir}/opensvc.conf"
  local gateway tmp rc unit

  # Resolve provisioning node
  gateway="$(get_provisioning_node 2>/dev/null)" || gateway=""
  if [[ -z "$gateway" ]]; then
    remote_log "load_opensvc_conf: no provisioning gateway detected"
    return 1
  fi

  mkdir -p "$conf_dir" || { remote_log "mkdir ${conf_dir} failed"; return 1; }

  # Fetch to a temp file
  tmp="$(mktemp "${conf_file}.XXXXXX")" || return 1
  if ! _osvc_run "fetch opensvc.conf from ${gateway}" \
        curl -fsS --connect-timeout 3 --retry 3 --retry-connrefused \
        "http://${gateway}/cgi-bin/boot_manager.sh?cmd=generate_opensvc_conf" \
        -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Minimal sanity check
  if [[ ! -s "$tmp" ]] || ! grep -q '^\[agent\]' "$tmp"; then
    remote_log "Downloaded opensvc.conf invalid or missing [agent] section"
    rm -f "$tmp"
    return 1
  fi

  # If unchanged, skip
  if [[ -f "$conf_file" ]] && cmp -s "$tmp" "$conf_file"; then
    rm -f "$tmp"
    remote_log "OpenSVC config unchanged; no restart required"
    echo "Unchanged ${conf_file}"
    return 0
  fi

  # Backup and install
  if [[ -f "$conf_file" ]]; then
    cp -a "$conf_file" "${conf_file}.$(date -u +%Y%m%dT%H%M%SZ).bak" || true
  fi
  chmod 0644 "$tmp"
  mv -f "$tmp" "$conf_file"
  command -v restorecon >/dev/null 2>&1 && restorecon -q "$conf_file" || true

  remote_log "OpenSVC config updated"
  echo "Updated ${conf_file}, restarting…"

  # Restart daemon with _osvc_run logging
  rc=1
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opensvc-server opensvc opensvc-agent; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${unit}.service"; then
        if _osvc_run "restart ${unit}.service" systemctl restart "${unit}.service"; then
          rc=0; break
        fi
      fi
    done
  fi
  if (( rc != 0 )); then
    if om daemon running >/dev/null 2>&1; then
      _osvc_run "restart opensvc daemon" om daemon restart || \
      _osvc_run "start opensvc daemon"   om daemon start
      rc=$?
    else
      _osvc_run "start opensvc daemon" om daemon start
      rc=$?
    fi
  fi

  (( rc == 0 )) && remote_log "OpenSVC daemon restarted" || {
    remote_log "Warning: failed to restart OpenSVC daemon"
    return 1
  }
}




# helper: run a command, log stdout+stderr, return code intact
_osvc_run() {
  local desc="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  remote_log "[osvc] ${desc} rc=${rc}\n${out}"
  return $rc
}

