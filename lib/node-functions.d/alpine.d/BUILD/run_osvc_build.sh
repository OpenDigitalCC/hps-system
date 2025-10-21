#!/bin/bash

n_remote_log () {
  logger -t osvc-build "$1"
  echo " osvc build: $1"
}

get_src_dir () {
  echo "/srv/build/opensvc-om3-src"
#/srv/hps-resources/packages/src/opensvc-om3"
}

get_dst_dir () {
  echo "/srv/build/opensvc-om3"
#/srv/hps-resources/packages/src/opensvc-om3"
}


run_function_list() {
  local func
  
  for func in "$@"; do
    echo ""
    n_remote_log " --- Running: $func"
    "$func"
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
      n_remote_log "Function failed: $func (exit code: $exit_code)"
      echo ""
      return $exit_code
    fi
    n_remote_log "Completed: $func"
  done
  n_remote_log "All functions completed successfully"
  return 0
}
export forceroot=1
source ./01-install-build-files.sh  
source ./05-install-utils.sh  
source ./10-build_opensvc.sh
#n_install_base_services \

run_function_list n_build_opensvc_package



