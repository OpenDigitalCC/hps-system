
## NODE Functions
#
n_osvc_start() {

  # prevent the default rc from running
  rc-update del opensvc-server default
  n_remote_log "Starting OpenSVC"
  nohup sh -c 'om daemon run 2>&1 | logger -t opensvc -p daemon.debug' >/dev/null 2>&1 &
#  _n_launch_osvc &
  n_osvc_wait_for_socket
  n_remote_log "OpenSVC daemon started (logging to syslog)"
}

_n_launch_osvc () {
  om daemon run 2>&1 | logger -t opensvc -p daemon.debug
}


# Initialise OpenSVC cluster settings on this node from HPS configs
n_initialise_opensvc_cluster() {
  local node_tags rc unit cluster_secret ips_addr

#  n_osvc_wait_for_socket

  local cluster_name="$(n_remote_cluster_variable CLUSTER_NAME)"
  local osvc_node_name="$(n_remote_host_variable HOSTNAME).$(n_remote_cluster_variable DNS_DOMAIN)"

  n_remote_log "Initialising $osvc_node_name on OpenSVC cluster $cluster_name"

  om cluster set --kw "node.name=${osvc_node_name}"

  # Get and set heartbeat type
  local hb_type
  hb_type="$(n_remote_cluster_variable OSVC_HB_TYPE 2>/dev/null || true)"
  om cluster set --kw "hb#1.type=${hb_type}" || return 1

  # Get node type for tags
  node_tags="$(n_remote_host_variable TYPE 2>/dev/null || true)"
  [[ -n "$node_tags" ]] && node_tags="$(echo "$node_tags" | tr '[:upper:]' '[:lower:]')"#

  if [[ -n "$node_tags" ]]; then
    om node set --kw "tags=${node_tags}" || return 1
  else
    n_remote_log "No TYPE in host_config; skipping node tags"
  fi
  
  n_opensvc_join

  n_remote_log "OpenSVC cluster initialisation complete: cluster='${cluster_name}' tags='${node_tags:-none}'"
}


n_opensvc_join() {
  local osvc_node="ips.$(n_remote_cluster_variable DNS_DOMAIN)"
  local osvc_token="$(n_ips_command osvc_cmd "osvc_cmd=get_auth_token")"
  n_remote_log "Joining cluster node: $osvc_node"
  if ! om cluster join --token "$osvc_token" --node "$osvc_node" --timeout 4s --debug; then
    n_remote_log "Failed to join cluster"
    return 1
  else
    n_remote_log "Join command completed"
    n_remote_host_variable cluster_joined "$(date +%s)"
    return 0
  fi
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
  return 1
}



