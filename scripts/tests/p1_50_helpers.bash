# Shared stubs for the CS-1.5 bats files (test_p1_50 .. test_p1_54).
# Source the HPS libraries first, then call p1_50_stubs: it replaces the
# helpers the code under test would call with file-backed fakes.
#
#   host registry   $TEST_DIR/hosts/<mac>/<KEY>      (value as plain text)
#   cluster keys    $TEST_DIR/cluster/<KEY>
#   resources       $TEST_DIR/res  (nixos manifests go in $TEST_DIR/res/nixos)

p1_50_stubs() {
  export CALL_LOG="$TEST_DIR/calls.log"
  : > "$CALL_LOG"
  mkdir -p "$TEST_DIR/hosts" "$TEST_DIR/cluster" "$TEST_DIR/res/nixos"

  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  cgi_header_plain() { printf 'Content-Type: text/plain\n\n'; }
  cgi_fail() { cgi_header_plain; printf '%s' "$1"; }
  cgi_success() { cgi_header_plain; printf '%s' "$1"; }
  cgi_auto_fail() { cgi_header_plain; printf 'FAIL: %s\n' "$1"; }
  ipxe_cgi_fail() { cgi_header_plain; printf 'FAIL: %s\n' "$1"; }
  make_timestamp() { echo "2026-11-09 12:00:00 UTC"; }
  hps_get_config() {
    case "$1" in
      active_cluster) echo "c1" ;;
      resources)      echo "$TEST_DIR/res" ;;
      *)              return 1 ;;
    esac
  }
  cluster_registry() {
    local key=$3
    if [[ "$2" == get && -f "$TEST_DIR/cluster/$key" ]]; then
      cat "$TEST_DIR/cluster/$key"
      return 0
    fi
    return 1
  }
  host_registry() {
    local mac=$1 op=$2 key=${3:-} val=${4:-}
    local d="$TEST_DIR/hosts/${mac//:/}"
    case "$op" in
      exists)
        if [[ -z "$key" ]]; then [[ -d "$d" ]]; else [[ -f "$d/$key" ]]; fi
        return $? ;;
      get)   [[ -f "$d/$key" ]] || return 1
             cat "$d/$key" ;;
      set)   mkdir -p "$d"
             printf '%s' "$val" > "$d/$key"
             echo "set $mac $key" >> "$CALL_LOG" ;;
    esac
    return 0
  }
  export -f hps_log cgi_header_plain cgi_fail cgi_success cgi_auto_fail ipxe_cgi_fail
  export -f make_timestamp hps_get_config cluster_registry host_registry
  export CGI_URL="http://ips/cgi-bin/boot_manager.sh"
}

# p1_50_host <mac> <KEY> <value>
p1_50_host() {
  mkdir -p "$TEST_DIR/hosts/${1//:/}"
  printf '%s' "$3" > "$TEST_DIR/hosts/${1//:/}/$2"
}

# p1_50_manifest <pin> <profile> [cmdline]
p1_50_manifest() {
  local dir="$TEST_DIR/res/nixos/$1/$2"
  mkdir -p "$dir"
  printf '{"kernel":"bzImage","initrd":"initrd","init":"/nix/store/abc-system/init","cmdline":"%s","profile":"%s","pin":"%s"}\n' \
    "${3:-console=ttyS0 loglevel=4}" "$2" "$1" > "$dir/boot.json"
}
