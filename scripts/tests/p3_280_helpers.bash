# Helpers for the paused-guest tests (test_p3_280_*): vm-resume, vm-status and
# vm-stop on a paused guest, and check_vms. Load after p2_30_helpers,
# p3_10_helpers and p3_20_helpers.
#
# p3_280_setup wraps the virsh shim of p3_20_helpers (renamed virsh.base) and adds:
#   domstate --reason   "<state> (<reason>)" with the reason from $STATE/reason.<vm>
#                       (no such file: the state alone, as an older libvirt prints it)
#   resume              the guest becomes running, unless
#                         $STATE/resume-fails   virsh resume exits 1
#                         $STATE/stays-paused   resume succeeds but the guest stays paused
#                         $STATE/repause        the guest runs for one poll, then is paused again
#   domblklist          the text of $STATE/blk.<vm> when it exists
#   $STATE/domstate-fails: domstate exits 1 for every guest; domblklist-fails: domblklist does
# and a zpool shim: `zpool list -H -o health <pool>` prints $STATE/pool.<pool>
# (absent: exit 1, the pool is not imported).

p3_280_setup() {
  p3_20_setup
  p3_shims
  mv "$TEST_DIR/bin/virsh" "$TEST_DIR/bin/virsh.base"
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
args=("$@")
[[ "$1" == "-c" ]] && shift 2
cmd=$1
vm=${*: -1}
base="$(dirname "$0")/virsh.base"
case "$cmd" in
  domstate)
    if [[ -e "$STATE/domstate-fails" ]]; then echo "virsh $*" >> "$SHIM_LOG"; echo "error: cannot read the state" >&2; exit 1; fi
    if [[ " $* " == *" --reason "* ]]; then
      plain=()
      for a in "${args[@]}"; do [[ "$a" == --reason ]] || plain+=("$a"); done
      out=$("$base" "${plain[@]}") || exit 1
      echo "virsh $*" >> "$SHIM_LOG"
      if [[ -e "$STATE/reason.$vm" ]]; then echo "$out ($(cat "$STATE/reason.$vm"))"; else echo "$out"; fi
      exit 0
    fi ;;
  resume)
    echo "virsh $*" >> "$SHIM_LOG"
    [[ -e "$STATE/resume-fails" ]] && { echo "error: cannot resume" >&2; exit 1; }
    [[ -e "$STATE/dom.$vm" ]] || { echo "error: failed to get domain '$vm'" >&2; exit 1; }
    if [[ -e "$STATE/stays-paused" ]]; then :
    elif [[ -e "$STATE/repause" ]]; then echo running > "$STATE/dom.$vm"; echo "1 paused" > "$STATE/pending.$vm"
    else echo running > "$STATE/dom.$vm"; fi
    echo "Domain '$vm' resumed"
    exit 0 ;;
  domblklist)
    if [[ -e "$STATE/domblklist-fails" ]]; then echo "virsh $*" >> "$SHIM_LOG"; exit 1; fi
    if [[ -e "$STATE/blk.$vm" ]]; then echo "virsh $*" >> "$SHIM_LOG"; cat "$STATE/blk.$vm"; exit 0; fi ;;
esac
exec "$base" "${args[@]}"
SHIM
  cat > "$TEST_DIR/bin/zpool" <<'SHIM'
#!/usr/bin/env bash
echo "zpool $*" >> "$SHIM_LOG"
[[ "$1" == list ]] || exit 0
pool=${*: -1}
[[ -e "$STATE/pool.$pool" ]] || exit 1
cat "$STATE/pool.$pool"
SHIM
  chmod +x "$TEST_DIR/bin/virsh" "$TEST_DIR/bin/zpool"
}

# p3_280_paused <vm> <reason text>: a defined guest paused for that reason
# ("I/O error", "ioerror", "user", ...).
p3_280_paused() {
  p3_20_fake_dom "$1" paused
  echo "$2" > "$STATE/reason.$1"
  echo '<domain/>' > "$STATE/xml.$1"
}

# p3_280_blk <vm> <source>...: what virsh domblklist prints, one disk per source
# (vda, vdb, ...); "-" is an empty drive.
p3_280_blk() {
  local vm=$1 n=0 src
  local targets=(vda vdb vdc vdd vde)
  shift
  {
    printf ' Target   Source\n------------------------\n'
    for src in "$@"; do
      printf ' %s      %s\n' "${targets[$n]}" "$src"
      n=$((n + 1))
    done
  } > "$STATE/blk.$vm"
}

# p3_280_md <name> <state> <active devices>: what mdadm --detail prints for the mirror.
p3_280_md() {
  printf '           State : %s\n   Active Devices : %s\n' "$2" "$3" > "$STATE/detail.$1"
}

# p3_280_calls: the logged commands, one per line.
p3_280_calls() {
  grep -v '^curl' "$SHIM_LOG" || true
}
