__guard_source || return



hps_log() {
  local level="$1"; shift
  local raw_msg="$*"
  local ident="${HPS_LOG_IDENT:-hps}"
  local logfile="${HPS_LOG_DIR:-/var/log}/hps-system.log"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  # URL decode function
  url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
  }

  # Decode the message
  local msg
  msg="$(url_decode "$raw_msg")"

  # Send to syslog
  logger -t "$ident" -p "user.${level,,}" "$msg"

  # Write to file if possible
  if [[ -w "$logfile" || ( ! -e "$logfile" && -w "$(dirname "$logfile")" ) ]]; then
    echo "[${ts}] [$ident] [$level] [${FUNCNAME[1]}] $msg" >> "$logfile"
  else
    logger -t "$ident" -p "user.err" "Failed to write to $logfile"
  fi
}

