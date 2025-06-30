__guard_source || return
# Define your functions below

cgi_log() {
  local msg="$1"
  local timestamp
  timestamp=$(date +"%F %T")
  echo "[${timestamp}] ${msg}" >> /var/log/ipxe/cgi.log
}



cgi_header_plain() {
  echo "Content-Type: text/plain"
  echo
}

cgi_success () {
  cgi_header_plain
  echo "$1"
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
      decoded_val=$(printf '%b' "${rawval//+/ }" | sed 's/%/\\x/g')

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


