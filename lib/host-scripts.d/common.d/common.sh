# /srv/hps/functions.d/common.sh

## NODE Functions


# Logging helpers
log() {
  echo "[HPS:$(date +%H:%M:%S)] $*"
  remote_log "$*"
}



# Default implementation (fallback)
build_zfs_source() {
  log "Running default build_zfs_source (not distro-specific)"
  echo "This system must implement its own ZFS build process through the local system config file."
  return 1
}

get_provisioning_node() {
  # Returns the default gateway IP (provisioning node)
  ip route | awk '/^default/ { print $3; exit }'
}

load_remote_host_config() {
  local conf
  local gateway="$(get_provisioning_node)"
  conf="$(curl -fsSL "http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_get_config")" || {
    remote_log "Failed to load host config"
    return 1
  }
  # Optional debug
  remote_log "Remote config: $conf"
  eval "$conf"
}

# url_encode
# ----------
# Percent-encode a string for safe inclusion in URL query parameters.
# Encodes all non [A-Za-z0-9.~_-] bytes, including spaces and newlines.
#
# Usage:
#   enc="$(url_encode "value with spaces & symbols")"
#
# Inputs:
#   $1  Unencoded string
#
# Outputs:
#   stdout: encoded string
#
# Returns:
#   0 on success
url_encode() {
  # shellcheck disable=SC2039
  local s="${1-}" out="" c i
  # Process as bytes; ensure predictable classification
  LC_ALL=C
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ')              out+="%20" ;;  # fast-path for spaces
      *)                printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}


# remote_host_variable
# --------------------
# Get or set a host variable on the provisioning node.
# Uses cmd=host_variable&name=<name>[&value=<value>]
#
# Usage:
#   remote_host_variable <name> <value>   # set
#   remote_host_variable <name>           # get
#
# Inputs:
#   $1  name   (string; required)
#   $2  value  (string; optional; if provided, will set)
#
# Env/Deps:
#   get_provisioning_node  -> returns <ip-or-hostname> of provisioning node
#   url_encode             -> percent-encodes parameters
#
# Outputs:
#   stdout: server response (get: raw value; set: success/fail message)
#
# Returns:
#   curl exit status (0 on success)
remote_host_variable() {
  local name="${1:?Usage: remote_host_variable <name> [<value>]}"
  local value="${2-}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1

  local enc_name enc_value url
  enc_name="$(url_encode "$name")"

  if [[ -n "$2" ]]; then
    enc_value="$(url_encode "$value")"
    url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_variable&name=${enc_name}&value=${enc_value}"
  else
    url="http://${gateway}/cgi-bin/boot_manager.sh?cmd=host_variable&name=${enc_name}"
  fi

  curl -fsS -X POST "$url"
}


# remote_cluster_variable
# -----------------------
# Get or set a cluster variable on the provisioning node.
# Uses cmd=cluster_variable&name=<name>[&value=<value>]
#
# Usage:
#   remote_cluster_variable <name> <value>   # set
#   remote_cluster_variable <name>           # get
#
# Outputs: server response to stdout
# Returns: curl exit status (0 on success)
remote_cluster_variable() {
  local name="${1:?Usage: remote_cluster_variable <name> [<value>]}"
  local value="${2-}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1

  local enc_name enc_value
  enc_name="$(url_encode "$name")"

  if [[ $# -ge 2 ]]; then
    # SET: POST with value
    enc_value="$(url_encode "$value")"
    curl -fsS -X POST \
      "http://${gateway}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=${enc_name}&value=${enc_value}"
  else
    # GET: GET without value param
    curl -fsS -X GET \
      "http://${gateway}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=${enc_name}"
  fi
}



# remote_log (refactor to reuse url_encode) — optional
remote_log() {
  local message="${1:?Usage: remote_log <message>}"
  local gateway
  gateway="$(get_provisioning_node)" || return 1
  local enc_msg
  enc_msg="$(url_encode "$message")"
  curl -fsS -X POST "http://${gateway}/cgi-bin/boot_manager.sh?cmd=log_message&message=${enc_msg}"
}




