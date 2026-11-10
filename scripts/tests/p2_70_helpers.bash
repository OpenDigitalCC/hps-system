# Helpers for the CS-2.5 zvol tests (test_p2_70_* .. test_p2_79_*). Load after
# p2_30_helpers (load p2_30_helpers; load p2_70_helpers), call p2_setup_dirs
# first.

# zfs for zvols. State files under $STATE: keystatus (value for <pool>/enc),
# zvols (lines "<name> <bytes>"), datasets (names of plain filesystems).
# FAKE_ZFS_CREATE_RC / FAKE_ZFS_DESTROY_RC set the exit status of those verbs.
p2_shim_zfs_zvol() {
  cat > "$TEST_DIR/bin/zfs" <<'SHIM'
#!/usr/bin/env bash
echo "zfs $*" >> "$SHIM_LOG"
verb="$1"
last="${@: -1}"
bytes_of() {
  local n="${1%?}" u="${1: -1}"
  case "$u" in K) echo $((n << 10)) ;; M) echo $((n << 20)) ;; G) echo $((n << 30)) ;; T) echo $((n << 40)) ;; esac
}
case "$verb" in
  get)
    case "$*" in
      *keystatus*)
        v=$(cat "$STATE/keystatus" 2> /dev/null || echo unavailable)
        if [[ "$*" == *"-o value"* ]]; then echo "$v"; else printf '%s\tkeystatus\t%s\t-\n' "$last" "$v"; fi ;;
      *volsize*) awk -v n="$last" '$1 == n { print $2 }' "$STATE/zvols" ;;
    esac
    exit 0 ;;
  list)
    if [[ "$*" == *"-o type"* ]]; then
      if awk -v n="$last" '$1 == n { f = 1 } END { exit !f }' "$STATE/zvols" 2> /dev/null; then echo volume; exit 0; fi
      grep -qxF "$last" "$STATE/datasets" 2> /dev/null && { echo filesystem; exit 0; }
      exit 1
    fi
    echo "NAME VOLSIZE USED REFER"
    cat "$STATE/zvols" 2> /dev/null
    exit 0 ;;
  create)
    [[ "${FAKE_ZFS_CREATE_RC:-0}" -ne 0 ]] && exit "$FAKE_ZFS_CREATE_RC"
    size=""
    for ((i = 1; i <= $#; i++)); do
      if [[ "${!i}" == "-V" ]]; then j=$((i + 1)); size="${!j}"; fi
    done
    if [[ -z "$size" ]]; then echo "$last" >> "$STATE/datasets"; exit 0; fi
    echo "$last $(bytes_of "$size")" >> "$STATE/zvols"
    exit 0 ;;
  destroy)
    [[ "${FAKE_ZFS_DESTROY_RC:-0}" -ne 0 ]] && exit "$FAKE_ZFS_DESTROY_RC"
    grep -v "^$last " "$STATE/zvols" > "$STATE/zvols.new" || true
    mv "$STATE/zvols.new" "$STATE/zvols"
    exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/zfs"
}

# p2_zvol_payload <dataset> [action] [expires] [mac]: the stdin document for
# storage-zvol-destroy, correctly signed, 'pool' carrying the dataset.
p2_zvol_payload() {
  p2_payload "$(p2_approval "${2:-zvol-destroy}" "$1" 0 "${3:-4102444800}" "${4:-aabbccddeeff}" '[]')"
}
