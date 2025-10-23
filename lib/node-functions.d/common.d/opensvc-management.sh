
## NODE Functions


n_opensvc_join () {
  osvc_node="ips.$(n_remote_cluster_variable DNS_DOMAIN)"
  osvc_token="$(n_ips_command osvc_cmd "osvc_cmd=get_auth_token")"
  n_remote_log "joining node $osvc_node"
  om cluster set -
  om cluster join --token "$osvc_token" --node "$osvc_node"
}


n_osvc_start () {
  n_remote_log "Starting OpenSVC"
  om daemon start
  n_osvc_wait_for_socket

}


# Initialise OpenSVC cluster settings on this node from HPS configs
n_initialise_opensvc_cluster() {
  local cluster_name node_tags rc unit cluster_secret ips_addr

  n_remote_log "Initialising OpenSVC cluster"
  
  local osvc_node_name="$(n_remote_host_variable HOSTNAME).$(n_remote_cluster_variable DNS_DOMAIN)"
  om cluster set --kw "name=$osvc_node_name"
  
  # Get node type for tags
  node_tags="$(n_remote_host_variable TYPE 2>/dev/null || true)"
  [[ -n "$node_tags" ]] && node_tags="$(echo "$node_tags" | tr '[:upper:]' '[:lower:]')"

  # Get and set heartbeat type

  local hb_type
  hb_type="$(n_remote_cluster_variable OSVC_HB_TYPE 2>/dev/null || true)"
  hb_type="${hb_type// /}"
  [[ -z "$hb_type" ]] && hb_type="multicast"
  
  om cluster set --kw "hb#1.type=${hb_type}" || return 1

  if [[ -n "$node_tags" ]]; then
    om node set --kw "tags=${node_tags}" || return 1
  else
    n_remote_log "No TYPE in host_config; skipping node tags"
  fi

  n_opensvc_join
  n_remote_log "OpenSVC cluster initialisation complete: cluster='${cluster_name}' tags='${node_tags:-none}'"
}


n_osvc_wait_for_socket() {
  n_remote_log "Waiting for OpenSVC daemon socket"
  
  local i
  for i in {1..10}; do
    if [[ -S /var/lib/opensvc/lsnr/http.sock ]]; then
      n_remote_log "OpenSVC daemon socket ready"
      return 0
    fi
    sleep 1
  done
  
  n_remote_log "OpenSVC daemon socket not ready after 10 seconds"
}


# Fetch opensvc.conf from boot_manager and apply safely

#  Likely to be deprecated, or maybe required for Rocky etc

n_load_opensvc_conf() {
  local conf_dir="/etc/opensvc"
  local conf_file="${conf_dir}/opensvc.conf"
  local gateway tmp rc unit

  # Resolve provisioning node
  gateway="$(n_get_provisioning_node 2>/dev/null)" || gateway=""
  if [[ -z "$gateway" ]]; then
    n_remote_log "No provisioning gateway detected"
    return 1
  fi

  mkdir -p "$conf_dir" || { n_remote_log "mkdir ${conf_dir} failed"; return 1; }

  # Fetch to a temp file
  tmp="$(mktemp "${conf_file}.XXXXXX")" || return 1
  if ! n_osvc_run "fetch opensvc.conf from ${gateway}" \
        curl -fsS --connect-timeout 3 --retry 3 --retry-connrefused \
        "http://${gateway}/cgi-bin/boot_manager.sh?cmd=generate_opensvc_conf" \
        -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Minimal sanity check
  if [[ ! -s "$tmp" ]] || ! grep -q '^\[agent\]' "$tmp"; then
    n_remote_log "Downloaded opensvc.conf invalid or missing [agent] section"
    rm -f "$tmp"
    return 1
  fi

  # If unchanged, skip
  if [[ -f "$conf_file" ]] && cmp -s "$tmp" "$conf_file"; then
    rm -f "$tmp"
    n_remote_log "OpenSVC config unchanged; no restart required"
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

  n_remote_log "OpenSVC config updated"
  echo "Updated ${conf_file}, restarting…"

  # Restart daemon with n_osvc_run logging
  rc=1
  if command -v systemctl >/dev/null 2>&1; then
    for unit in opensvc-server opensvc opensvc-agent; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${unit}.service"; then
        if n_osvc_run "restart ${unit}.service" systemctl restart "${unit}.service"; then
          rc=0; break
        fi
      fi
    done
  fi
  if (( rc != 0 )); then
    if om daemon running >/dev/null 2>&1; then
      n_osvc_run "restart opensvc daemon" om daemon restart || \
      n_osvc_run "start opensvc daemon"   om daemon start
      rc=$?
    else
      n_osvc_run "start opensvc daemon" om daemon start
      rc=$?
    fi
  fi

  (( rc == 0 )) && n_remote_log "OpenSVC daemon restarted" || {
    n_remote_log "Warning: failed to restart OpenSVC daemon"
    return 1
  }
}




