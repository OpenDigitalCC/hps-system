__guard_source || return
# Define your functions below


# cgi_auto_fail
# -------------
# Fail helper that auto-selects the correct fail function based on client type.
#
# Detects client type with detect_client_type(), then calls:
#   - ipxe_cgi_fail <msg>   if client is ipxe
#   - cgi_fail <msg>        otherwise (cli, browser, unknown)
#
# Usage:
#   cgi_auto_fail "Missing required parameter"
cgi_auto_fail() {
  local msg="${1:?Usage: cgi_auto_fail <message>}"
  local client_type
  client_type="$(detect_client_type)"

  case "$client_type" in
    ipxe)
      ipxe_cgi_fail "$msg"
      ;;
    cli|browser|script|unknown)
      cgi_fail "$msg"
      ;;
    *)
      hps_log error "$msg"
      echo "$msg"
      ;;    
  esac
}



cgi_log() {
  local msg="$1"
  local timestamp
  timestamp=$(date +"%F %T")
  echo "[${timestamp}] ${msg}" >> /var/log/ipxe/cgi.log
}



cgi_header_plain() {
  echo "Content-Type: text/plain"
  echo ""
}

cgi_success () {
  cgi_header_plain
  echo -n "$1"
}


cgi_fail () {
  local cfmsg="$1"
  cgi_header_plain
  hps_log error "$cfmsg"
  echo -n "$cfmsg"
}





#===============================================================================
# cgi_require_param
# -----------------
# Require a CGI parameter exists and is non-empty, returning its value.
#
# Behaviour:
#   - Checks parameter exists via cgi_param
#   - Checks parameter value is non-empty
#   - If missing or empty, calls cgi_auto_fail and exits
#   - If valid, outputs value to stdout
#
# Arguments:
#   $1: Parameter name
#
# Returns:
#   Value on stdout, or exits with failure
#
# Example usage:
#   var_name="$(cgi_require_param name)"
#   os_id="$(cgi_require_param os_id)"
#
#===============================================================================
cgi_require_param() {
  local param_name="$1"
  local param_value
  
  if ! cgi_param exists "$param_name"; then
    cgi_auto_fail "Param '$param_name' is required"
    exit 1
  fi
  
  param_value="$(cgi_param get "$param_name")"
  
  if [[ -z "$param_value" ]]; then
    cgi_auto_fail "Param '$param_name' cannot be empty"
    exit 1
  fi
  
  printf '%s' "$param_value"
}



# Internal associative map (populated once)
declare -gA CGI_PARAMS
declare -g __CGI_PARAMS_PARSED=0

cgi_param() {
  local cmd="$1"
  local key="$2"
  local value="${3:-}"

  # Internal: parse QUERY_STRING once
  if [[ $__CGI_PARAMS_PARSED -eq 0 ]]; then
    local query="${QUERY_STRING:-}"
    local pair rawkey rawval decoded_key decoded_val
    IFS='&' read -ra pairs <<< "$query"

    for pair in "${pairs[@]}"; do
      IFS='=' read -r rawkey rawval <<< "$pair"
      decoded_key=$(printf '%b' "${rawkey//+/ }" | sed 's/%/\\x/g')
      decoded_val=$(printf '%b' "$(sed 's/%/\\x/g' <<< "${rawval//+/ }")")
#      decoded_val=$(printf '%b' "${rawval//+/ }" | sed 's/%/\\x/g')

      if [[ "$decoded_key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        CGI_PARAMS["$decoded_key"]="$decoded_val"
      fi
    done

    __CGI_PARAMS_PARSED=1
  fi

  # Dispatch logic
  case "$cmd" in
    get)
      [[ ${CGI_PARAMS[$key]+_} ]] && printf '%s\n' "${CGI_PARAMS[$key]}"
      return
      ;;
    exists)
      [[ ${CGI_PARAMS[$key]+_} ]]
      return
      ;;
    equals)
      [[ ${CGI_PARAMS[$key]+_} && "${CGI_PARAMS[$key]}" == "$value" ]]
      return
      ;;
    *)
      echo "[x] Invalid cgi_param command: $cmd" >&2
      return 2
      ;;
  esac
}

urlencode() {
  local s="$1"
  local out=""
  for (( i=0; i<${#s}; i++ )); do
    local c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s\n' "$out"
}


