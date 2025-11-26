#!/bin/bash
#===============================================================================
# Node Init Functions
# File: /srv/hps-system/lib/node-functions.d/common.d/n_init-functions.sh
#
# Functions for executing OS-specific initialization sequences on nodes.
# Init sequences are embedded in function bundles as HPS_INIT_SEQUENCE array.
#===============================================================================

#===============================================================================
# n_init_run
# ----------
# Execute the HPS initialization sequence.
#
# Behaviour:
#   - Reads HPS_INIT_SEQUENCE array (set during function bundle loading)
#   - Executes each function in sequence
#   - Logs start/completion of each action via n_remote_log
#   - Logs failures but continues to next action (non-fatal)
#   - Returns success even if individual actions fail
#
# Returns:
#   0 always (errors logged but not fatal)
#
# Example:
#   # After function bundle loaded (HPS_INIT_SEQUENCE populated)
#   n_init_run
#
#===============================================================================
n_init_run() {
  echo "[HPS] Starting initialization sequence..." >&2
  
  # Check if init sequence exists
  if [[ ! -v HPS_INIT_SEQUENCE ]]; then
    echo "[HPS] WARNING: HPS_INIT_SEQUENCE not defined" >&2
    if type n_remote_log >/dev/null 2>&1; then
      n_remote_log "WARNING: No init sequence defined"
    fi
    return 0
  fi
  
  if [[ ${#HPS_INIT_SEQUENCE[@]} -eq 0 ]]; then
    echo "[HPS] INFO: Init sequence is empty, nothing to do" >&2
    if type n_remote_log >/dev/null 2>&1; then
      n_remote_log "INFO: Init sequence empty"
    fi
    return 0
  fi
  
  local total=${#HPS_INIT_SEQUENCE[@]}
  local success=0
  local failed=0
  
  echo "[HPS] Executing $total init action(s)..." >&2
  if type n_remote_log >/dev/null 2>&1; then
    n_remote_log "Starting init sequence: $total action(s)"
  fi
  
  # Execute each action in sequence
  local i=1
  for action in "${HPS_INIT_SEQUENCE[@]}"; do
    echo "[HPS] [$i/$total] Running: $action" >&2
    
    if type n_remote_log >/dev/null 2>&1; then
      n_remote_log "Init [$i/$total]: Starting $action"
    fi
    
    # Check if function exists
    if ! type "$action" >/dev/null 2>&1; then
      echo "[HPS] ERROR: Function not found: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init ERROR: Function not found: $action"
      fi
      ((failed++))
      ((i++))
      continue
    fi
    
    # Execute the action
    if "$action" 2>&1; then
      echo "[HPS] [$i/$total] Success: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init [$i/$total]: Success: $action"
      fi
      ((success++))
    else
      local exit_code=$?
      echo "[HPS] ERROR: Action failed with exit code $exit_code: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init ERROR [$i/$total]: Failed ($exit_code): $action"
      fi
      ((failed++))
    fi
    
    ((i++))
  done
  
  echo "[HPS] Init sequence complete: $success succeeded, $failed failed" >&2
  if type n_remote_log >/dev/null 2>&1; then
    n_remote_log "Init sequence complete: $success succeeded, $failed failed"
  fi
  
  return 0
}
