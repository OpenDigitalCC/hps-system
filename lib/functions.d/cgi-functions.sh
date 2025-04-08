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

cgi_fail() {
  cgi_header_plain
  echo "#!ipxe"
  echo "echo [✗] $1"
  echo "sleep 5"
  echo "reboot"
}


