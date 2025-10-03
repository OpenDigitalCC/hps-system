__guard_source || return

#:name: hps_log
#:group: logging
#:synopsis: Log messages to syslog and file with context information.
#:usage: hps_log <level> <message>
#:description:
#  Logs messages with timestamp, level, function name, and origin context.
#  If the current host has a configured hostname, displays hostname instead of origin tag.
#  URL-decodes messages and detects client type (script/ipxe/cli).
#:parameters:
#  level   - Log level (info, warn, error, debug)
#  message - Message to log (will be URL-decoded)
#:returns:
#  0 always
hps_log() {
  local level="$1"; shift
  local raw_msg="$*"
  local ident="${HPS_LOG_IDENT:-hps}"
  local logfile="${HPS_LOG_DIR}/hps-system.log"
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  
  # URL decode function
  url_decode() {
    local data="${1//+/ }"
    printf '%b' "${data//%/\\x}"
  }
  
  # Get origin identifier - use hostname if configured, otherwise origin tag
  local origin_id
  local origin_tag
  origin_tag=$(hps_origin_tag)
  
  if host_config "$origin_tag" exists HOSTNAME 2>/dev/null; then
    origin_id=$(host_config "$origin_tag" get HOSTNAME 2>/dev/null)
    [[ -z "$origin_id" ]] && origin_id="$origin_tag"
  else
    origin_id="$origin_tag"
  fi
  
  # Decode the message
  local msg
  msg="[$origin_id] ($(detect_client_type)) $(url_decode "$raw_msg")"
  
  # Send to syslog
  logger -t "$ident" -p "user.${level,,}" "[${FUNCNAME[1]}] $msg"
  
  # Write to file if possible
  if [[ -w "$logfile" || ( ! -e "$logfile" && -w "$(dirname "$logfile")" ) ]]; then
    echo "[${ts}] [$ident] [$level] [${FUNCNAME[1]}] $msg" >> "$logfile"
  else
    logger -t "$ident" -p "user.err" "Failed to write to $logfile"
  fi
}


