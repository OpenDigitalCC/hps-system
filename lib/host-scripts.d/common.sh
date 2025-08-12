# /srv/hps/functions.d/common.sh

# Logging helpers
log() {
  echo "[HPS:$(date +%H:%M:%S)] $*"
  remote_log "$*"
}

# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process."
  return 1
}

get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}

load_remote_host_config() {
  local conf
  local gateway="$(get_provisioning_node)"
  conf="$(curl -fsSL "http://${gateway}/cgi-bin/boot_manager.sh?mac=@macid@&cmd=host_get_config")" || {
    remote_log "Failed to load host config"
    return 1
  }
  # Optional debug
  remote_log "Remote config: $conf"
  eval "$conf"
}

remote_log() {
  local message="$1"
  local encoded
  local gateway="$(get_provisioning_node)"
  # URL-encode the message
  local c
  encoded=""
  for (( i=0; i<${#message}; i++ )); do
    c="${message:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) printf -v encoded '%s%%%02X' "$encoded" "'$c" ;;
    esac
  done

  # Send log message
  curl -s -X POST "http://${gateway}/cgi-bin/boot_manager.sh?cmd=log_message&message=${encoded}"
}
