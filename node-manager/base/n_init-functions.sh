#!/bin/bash
#===============================================================================
# Node Init Functions
# File: /srv/hps-system/lib/node-functions.d/common.d/n_init-functions.sh
#
# Functions for executing OS-specific initialization sequences on nodes.
# Init sequences are embedded in function bundles as HPS_INIT_SEQUENCE array.
#===============================================================================


#===============================================================================
# n_init_step_message
# -------------------
# The tail of a step's own stderr: last 3 lines, at most 300 characters. Reads
# the file the step's stderr was written to, never a global.
#
# Usage:
#   n_init_step_message <stderr-file>
#===============================================================================
n_init_step_message() {
  local file="${1:?Usage: n_init_step_message <stderr-file>}"
  [[ -s "$file" ]] || return 0
  tail -n 3 "$file" | tail -c 300
}

#===============================================================================
# n_init_step_append
# ------------------
# Append one step to the JSON steps array and print the new array.
#
# Usage:
#   steps=$(n_init_step_append "$steps" <name> <rc> <seconds> <message>)
#===============================================================================
n_init_step_append() {
  local steps="${1:?}" name="${2:?}" rc="${3:?}" secs="${4:?}" msg="${5-}"
  jq -c --arg n "$name" --argjson rc "$rc" --argjson s "$secs" --arg m "$msg" \
    '. + [{name: $n, rc: $rc, seconds: $s, message: $m}]' <<< "$steps"
}

#===============================================================================
# n_init_report
# -------------
# Report the init result to the IPS: one POST of cmd=host_init_result with a
# JSON body {boot_id, pin, started_at, finished_at, steps[]} and the X-HPS-MAC
# header. Never blocks boot: 10 s timeout; any failure is logged and ignored.
#
# Usage:
#   n_init_report <started_at> <finished_at> <steps-json>
#
# Pin: HPS_PIN, else hps.pin= on the kernel command line, else empty (the IPS
# then records the host's system_pin).
#
# Returns:
#   0 always
#===============================================================================
n_init_report() {
  local started="${1-}" finished="${2-}" steps="${3:-[]}"
  local ips mac boot_id pin body url code

  command -v jq >/dev/null 2>&1 || {
    echo "[HPS] WARNING: jq missing, init result not reported" >&2
    n_remote_log "WARNING: init result not reported: jq missing" auto warning
    return 0
  }
  ips="$(n_get_provisioning_node 2>/dev/null)" || ips=""
  if [[ -z "$ips" ]]; then
    echo "[HPS] WARNING: no IPS address, init result not reported" >&2
    n_remote_log "WARNING: init result not reported: no IPS address" auto warning
    return 0
  fi
  mac=""
  if type get_mac >/dev/null 2>&1; then
    mac="$(get_mac 2>/dev/null)" || mac=""
  fi
  boot_id=""
  [[ -r /proc/sys/kernel/random/boot_id ]] && boot_id="$(cat /proc/sys/kernel/random/boot_id)"
  pin="${HPS_PIN:-}"
  if [[ -z "$pin" && -r /proc/cmdline ]]; then
    pin="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^hps\.pin=//p' | head -n 1)"
  fi

  body="$(jq -n -c --arg b "$boot_id" --arg p "$pin" --arg s "$started" --arg f "$finished" \
    --argjson steps "$steps" '{boot_id: $b, pin: $p, started_at: $s, finished_at: $f, steps: $steps}')" || {
    echo "[HPS] WARNING: could not build the init result" >&2
    n_remote_log "WARNING: init result not reported: could not build the body" auto warning
    return 0
  }

  url="http://${ips}/cgi-bin/boot_manager.sh?cmd=host_init_result"
  echo "[HPS] + curl POST $url" >&2
  if [[ -n "$mac" ]]; then
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' -H "X-HPS-MAC: ${mac}" \
      --data-binary "$body" "$url" 2>&1)" || code="curl-failed:${code}"
  else
    code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
      -H 'Content-Type: application/json' \
      --data-binary "$body" "$url" 2>&1)" || code="curl-failed:${code}"
  fi
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    n_remote_log "Init result reported to the IPS (HTTP $code)"
  else
    echo "[HPS] WARNING: init result not accepted: $code" >&2
    n_remote_log "WARNING: init result not reported: $code" auto warning
  fi
  return 0
}

#===============================================================================
# n_init_run
# ----------
# Execute the HPS initialization sequence and report the result to the IPS.
#
# Behaviour:
#   - Reads HPS_INIT_SEQUENCE array (set during function bundle loading)
#   - Executes each function in sequence; each step's stderr goes to a file so
#     the report carries that step's own last lines
#   - Logs start/completion of each action via n_remote_log; a failed step
#     logs at err severity
#   - Logs failures but continues to next action (non-fatal)
#   - At the end, n_init_report sends {boot_id, pin, started_at, finished_at,
#     steps[{name, rc, seconds, message}]} to the IPS (never blocks boot)
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
  local steps="[]"
  local have_jq=0
  command -v jq >/dev/null 2>&1 && have_jq=1
  local started finished errf t0 secs msg
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  errf="/tmp/hps-init-step-$$"

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

    # Split "func arg..." into the function name and its arguments
    local -a words=()
    read -r -a words <<< "$action"

    # Check if function exists (first word)
    if [[ ${#words[@]} -eq 0 ]] || ! type "${words[0]}" >/dev/null 2>&1; then
      echo "[HPS] ERROR: Function not found: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init ERROR: Function not found: $action" auto err
      fi
      failed=$((failed + 1))
      if (( have_jq )); then
        steps="$(n_init_step_append "$steps" "$action" 127 0 "function not found")"
      fi
      i=$((i + 1))
      continue
    fi

    # Execute the action; its stderr is kept in a file, then replayed on stdout
    # (as the former 2>&1 did) so the caller's output is unchanged.
    t0=$SECONDS
    local exit_code=0
    "${words[@]}" 2>"$errf" || exit_code=$?
    secs=$((SECONDS - t0))
    msg="$(n_init_step_message "$errf")"
    cat "$errf"
    rm -f "$errf"

    if (( have_jq )); then
      steps="$(n_init_step_append "$steps" "$action" "$exit_code" "$secs" "$msg")"
    fi
    if [[ $exit_code -eq 0 ]]; then
      echo "[HPS] [$i/$total] Success: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init [$i/$total]: Success: $action"
      fi
      success=$((success + 1))
    else
      echo "[HPS] ERROR: Action failed with exit code $exit_code: $action" >&2
      if type n_remote_log >/dev/null 2>&1; then
        n_remote_log "Init ERROR [$i/$total]: Failed ($exit_code): $action" auto err
      fi
      failed=$((failed + 1))
    fi

    i=$((i + 1))
  done

  echo "[HPS] Init sequence complete: $success succeeded, $failed failed" >&2
  if type n_remote_log >/dev/null 2>&1; then
    n_remote_log "Init sequence complete: $success succeeded, $failed failed"
  fi

  finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if type n_init_report >/dev/null 2>&1; then
    n_init_report "$started" "$finished" "$steps"
  fi

  return 0
}
