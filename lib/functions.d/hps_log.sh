__guard_source || return

hps_log() {
  local level="$1"; shift
  local msg="$*"
  local ident="${HPS_LOG_IDENT:-hps}"
  local logfile="${HPS_LOG_DIR:-/var/log}/hps-system.log"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # Send to syslog
  logger -t "$ident" -p "user.${level,,}" "$msg"

  # Attempt to log to file
  if [[ -w "$logfile" || ( ! -e "$logfile" && -w "$(dirname "$logfile")" ) ]]; then
    echo "[${ts}] [$ident] [$level] $msg" >> "$logfile"
  else
    logger -t "$ident" -p "user.err" "Failed to write to $logfile"
  fi
}

