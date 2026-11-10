# shellcheck shell=bash
# jobs-functions.sh
#
# The IPS privileged-action queue, caller side (ADR 0006). The web user cannot
# run the ctrl-exec dispatcher or read the keysafe; it submits a job instead and
# the root runner (bin/hps-jobs) executes it. File shapes and per-kind argument
# patterns match lib/perl/HPS/Jobs.pm.
#
#   hps_job_submit <kind> [args...]   print the job id
#   hps_job_wait <id> [timeout]       wait for the result; print its stdout (and
#                                     its stderr on stderr); return its exit
#   hps_job_result <id>               print the result JSON; 1 if not finished
#
# Queue: ${HPS_JOBS_DIR:-<cluster dir>/jobs}/{new,run,done,failed}, created with
# hps_state_mkdir (group hps, setgid, group-writable).

#===============================================================================
# hps_jobs_dir
# ------------
# Print the queue directory: HPS_JOBS_DIR, else <cluster_base>/jobs.
#===============================================================================
hps_jobs_dir() {
  if [[ -n "${HPS_JOBS_DIR:-}" ]]; then
    printf '%s\n' "$HPS_JOBS_DIR"
    return 0
  fi
  local base
  base=$(hps_get_config cluster_base 2>/dev/null) || return 1
  [[ -n "$base" ]] || return 1
  printf '%s\n' "${base}/jobs"
}

#===============================================================================
# hps_jobs_ensure_dirs
# --------------------
# Create new/ run/ done/ failed/ if missing (idempotent).
#===============================================================================
hps_jobs_ensure_dirs() {
  local dir
  dir=$(hps_jobs_dir) || return 1
  hps_state_mkdir "$dir/new" "$dir/run" "$dir/done" "$dir/failed"
}

#===============================================================================
# hps_job_validate <kind> [args...]
# ---------------------------------
# The allowlist. Returns 0 if the kind and its arguments are allowed; otherwise
# 1 with the reason on stderr.
#===============================================================================
hps_job_validate() {
  local kind="${1:-}"
  shift || true
  case "$kind" in
    pairing-window-open)
      (( $# <= 1 )) || { echo "$kind: takes at most one argument (seconds)" >&2; return 1; }
      if (( $# == 1 )); then
        [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 600 )) \
          || { echo "$kind: seconds must be 1-600" >&2; return 1; }
      fi
      ;;
    pairing-window-close | pairing-list)
      (( $# == 0 )) || { echo "$kind: takes no arguments" >&2; return 1; }
      ;;
    pairing-approve)
      (( $# >= 1 && $# <= 2 )) || { echo "$kind: needs <reqid> [--replace]" >&2; return 1; }
      [[ "$1" =~ ^[a-f0-9]{1,64}$ ]] || { echo "$kind: reqid must be lowercase hex (1-64 characters)" >&2; return 1; }
      if (( $# == 2 )) && [[ "$2" != "--replace" ]]; then
        echo "$kind: second argument can only be --replace" >&2
        return 1
      fi
      ;;
    storage-up | storage-down | storage-trim-check | storage-status)
      [[ $# -eq 1 && "$1" =~ ^[0-9a-f]{12}$ ]] \
        || { echo "$kind: needs exactly <mac> (12 lowercase hex digits)" >&2; return 1; }
      ;;
    workload-create)
      local wl_re='^[a-z][a-z0-9-]{0,31}$'
      if (( $# == 1 )) || { (( $# == 2 )) && [[ "$2" == "--resume" ]]; }; then
        [[ "$1" =~ $wl_re ]] || { echo "$kind: workload must match $wl_re" >&2; return 1; }
      else
        echo "$kind: needs <workload> [--resume]" >&2
        return 1
      fi
      ;;
    workload-start | workload-stop | workload-status)
      local wl_re='^[a-z][a-z0-9-]{0,31}$'
      if (( $# == 1 )) || { (( $# == 3 )) && [[ "$2" == "--vm" && "$3" =~ $wl_re ]]; }; then
        [[ "$1" =~ $wl_re ]] || { echo "$kind: workload must match $wl_re" >&2; return 1; }
      else
        echo "$kind: needs <workload> [--vm <vm>]" >&2
        return 1
      fi
      ;;
    workload-destroy)
      [[ $# -eq 1 && "$1" =~ ^[a-z][a-z0-9-]{0,31}$ ]] \
        || { echo "$kind: needs exactly <workload>" >&2; return 1; }
      ;;
    "")
      echo "hps_job_submit: no kind" >&2
      return 1
      ;;
    *)
      echo "unknown job kind '$kind'" >&2
      return 1
      ;;
  esac
  return 0
}

# _hps_job_new_id: 8 lowercase hex digits.
_hps_job_new_id() {
  printf '%04x%04x\n' "$RANDOM" "$RANDOM"
}

#===============================================================================
# hps_job_submit <kind> [args...]
# -------------------------------
# Validate, write new/<epoch>-<pid>-<id>.json atomically, print the id.
# Returns 1 on a refused kind/argument, 2 when the queue is unavailable.
#===============================================================================
hps_job_submit() {
  local kind="${1:-}"
  hps_job_validate "$@" || return 1
  shift
  local dir
  dir=$(hps_jobs_dir) || {
    hps_log error "hps_job_submit: cannot locate the job queue"
    return 2
  }
  if [[ ! -d "$dir/new" ]]; then
    hps_jobs_ensure_dirs 2>/dev/null || true
  fi
  if [[ ! -d "$dir/new" || ! -w "$dir/new" ]]; then
    hps_log error "hps_job_submit: job queue $dir/new is not writable"
    return 2
  fi
  local id now prog name json
  id=$(_hps_job_new_id)
  now=$(date +%s)
  prog="${0##*/}"
  name="${now}-$$-${id}.json"
  json=$(jq -cn --arg id "$id" --arg kind "$kind" \
    --arg by "$(id -u)/${prog}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: $id, kind: $kind, args: $ARGS.positional, requested_by: $by, requested_at: $at}' \
    --args -- "$@") || return 2
  (
    umask 002
    printf '%s\n' "$json" > "$dir/new/.tmp-${name}"
    mv -- "$dir/new/.tmp-${name}" "$dir/new/${name}"
  ) || {
    hps_log error "hps_job_submit: cannot write $dir/new/${name}"
    return 2
  }
  hps_log info "hps_job_submit: queued ${kind} as ${id}"
  printf '%s\n' "$id"
}

# _hps_job_result_file <id>: print the path of the finished result, else 1.
_hps_job_result_file() {
  local id="$1" dir d
  [[ "$id" =~ ^[0-9a-f]{8}$ ]] || return 1
  dir=$(hps_jobs_dir) || return 1
  for d in 'done' failed; do
    if [[ -f "$dir/$d/$id.result.json" ]]; then
      printf '%s\n' "$dir/$d/$id.result.json"
      return 0
    fi
  done
  return 1
}

#===============================================================================
# hps_job_result <id>
# -------------------
# Print the result JSON of a finished job; 1 if there is none yet.
#===============================================================================
hps_job_result() {
  local f
  f=$(_hps_job_result_file "${1:-}") || return 1
  cat -- "$f"
}

#===============================================================================
# hps_job_wait <id> [timeout seconds, default 30]
# -----------------------------------------------
# Poll for the result. Prints the job's stdout on stdout and its stderr on
# stderr. Returns the job's exit status (capped to 255); 124 when the timeout
# passes first.
#===============================================================================
hps_job_wait() {
  local id="${1:?Usage: hps_job_wait <id> [timeout]}"
  local timeout="${2:-30}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=30
  local waited=0 f=""
  while true; do
    if f=$(_hps_job_result_file "$id"); then
      break
    fi
    if (( waited >= timeout * 5 )); then
      hps_log error "hps_job_wait: job ${id} did not finish within ${timeout}s"
      echo "job ${id} did not finish within ${timeout}s (is hps-jobs running?)" >&2
      return 124
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  local rc out err
  rc=$(jq -r '.exit // 1' "$f") || return 1
  out=$(jq -r '.stdout // ""' "$f")
  err=$(jq -r '.stderr // ""' "$f")
  [[ -z "$out" ]] || printf '%s\n' "$out"
  [[ -z "$err" ]] || printf '%s\n' "$err" >&2
  if (( rc > 255 )); then
    rc=255
  fi
  return "$rc"
}
