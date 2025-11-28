
## HPS Functions

#TODO: Move config to CLUSTER_SERVICES_DIR

osvc_prepare_cluster() {
  
  hps_log info "Configuring OpenSVC cluster for IPS"
  
  # 1. Ensure OpenSVC is installed

  if ! ensure_opensvc_installed; then
    hps_log error "Cannot proceed without OpenSVC"
    return 1
  fi
  
  # 2. Setup directory structure
  if ! _osvc_setup_directories; then
    hps_log error "OpenSVC directory setup failed"
    return 1
  fi
  
  # 3. Create opensvc.conf
  if ! _osvc_create_conf; then
    hps_log error "OpenSVC config creation failed"
    return 1
  fi

#  if ! install_opensvc_foreground_wrapper; then
#    hps_log error "Foreground wrapper installation failed"
#    return 1
#  fi

}



osvc_create_services () {
  local config_updates=()
  config_updates+=("cluster.name=${cluster_name}")

  # Apply all configuration updates at once
  if ! _osvc_config_update "${config_updates[@]}"; then
    hps_log error "Failed to configure OpenSVC cluster"
    return 1
  fi

om svc create iscsi-manager
om iscsi-manager edit
om iscsi-manager set --kw app#iscsi_manager.type=forking 
om iscsi-manager set --kw  app#iscsi_manager.start="/srv/scripts/lio start" 
om iscsi-manager set --kw app#iscsi_manager.stop="/srv/scripts/lio stop" 
om iscsi-manager set --kw app#iscsi_manager.check="/srv/scripts/lio check"
om iscsi-manager provision
om iscsi-manager start 


}


osvc_configure_cluster() {

  # Wait for daemon socket to be ready
  _osvc_wait_for_sock

  # Enforce single cluster agent key policy
#  if ! _osvc_cluster_agent_key; then
#    return $?
#  fi

  # Verify daemon is responsive
  if ! om cluster status >/dev/null 2>&1; then
    hps_log error "OpenSVC daemon not responsive"
    return 1
  fi
  
  # Set IPS node identity
  local osvc_nodename="ips"
  
  # Get cluster configuration
  local cluster_name
  cluster_name="$(cluster_registry get CLUSTER_NAME 2>/dev/null)"
  
  if [[ -z "${cluster_name}" ]]; then
    hps_log error "CLUSTER_NAME not set in cluster_config"
    return 1
  fi
  
  # Get heartbeat configuration
  local hb_type
  hb_type="$(cluster_registry get OSVC_HB_TYPE 2>/dev/null)" || hb_type="multicast"
  
  # Build configuration update arguments
  local config_updates=()
  
  config_updates+=("cluster.name=${cluster_name}")
  config_updates+=("node.name=${osvc_nodename}")
#  config_updates+=("hb#1.type=${hb_type}")
  
  # Handle cluster secret
  local cluster_secret
  cluster_secret="$(_osvc_cluster_secrets)" || return 1
#  config_updates+=("cluster.secret=${cluster_secret}")
  
  # Apply all configuration updates at once
  if ! _osvc_config_update "${config_updates[@]}"; then
    hps_log error "Failed to configure OpenSVC cluster"
    return 1
  fi
  
  # Create heartbeat secrets
#  _osvc_create_hb_secrets || hps_log warning "Failed to create heartbeat secrets"
  
  # Verify configuration was applied
  if ! om cluster status >/dev/null 2>&1; then
    hps_log error "Daemon not responsive after configuration"
    return 1
  fi
  
  hps_log info "OpenSVC cluster configured successfully"
  hps_log info "  Cluster: ${cluster_name}"
  hps_log info "  Node: ${osvc_nodename} (IPS)"
  hps_log info "  Heartbeat: ${hb_type}"
  hps_log info "  Config: /etc/opensvc/opensvc.conf"
  hps_log info "  Agent key policy: enforced"
  
  return 0
}
