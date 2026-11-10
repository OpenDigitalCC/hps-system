# Helpers for the CS-3.3 VM-lifecycle tests (test_p3_20_* .. test_p3_29_*).
# Load after p2_30_helpers. A stateful virsh shim logs every call (the
# "-c qemu:///system" prefix is dropped) to $SHIM_LOG; fake state is in $STATE:
#   dom.<vm>      the guest's state text ("shut off", "running", ...); absent = not defined
#   xml.<vm>      the XML virsh define received (virsh dumpxml prints it back)
#   pending.<vm>  "<n> <state>": domstate prints the old state n times, then <state>
#   startdelay / stopdelay   n polls before start / shutdown takes effect
#   never-running / stubborn start never completes / shutdown is ignored
#   caps          space-separated security models virsh capabilities lists
#   curl-body     what the curl shim "downloads"

p3_20_setup() {
  p2_setup_dirs
  export HPS_DEV="$TEST_DIR/dev"
  export HPS_LIBVIRT_LOGDIR="$TEST_DIR/log"
  export HPS_VM_STEP=0.01
  export HPS_VM_WAIT=3
  mkdir -p "$HPS_DEV/md" "$HPS_LIBVIRT_LOGDIR"
  DISK="$HPS_DEV/md/vm1-disk0"
  head -c 4096 /dev/zero > "$DISK"
  IMG="$TEST_DIR/images/base.qcow2"
  mkdir -p "$TEST_DIR/images"
  printf 'QFI\373fake-qcow2' > "$IMG"
  S="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/scripts"
  p3_20_shims
}

p3_20_shims() {
  cat > "$TEST_DIR/bin/virsh" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "-c" ]] && shift 2
echo "virsh $*" >> "$SHIM_LOG"
cmd=$1; shift
vm=""
for a in "$@"; do [[ "$a" != -* ]] && vm=$a; done
state() { cat "$STATE/dom.$1"; }
case "$cmd" in
  dominfo)
    [[ -e "$STATE/dom.$vm" ]] || { echo "error: failed to get domain '$vm'" >&2; exit 1; }
    printf 'Name:           %s\nState:          %s\nSecurity model: %s\nSecurity DOI:   0\n' "$vm" "$(state "$vm")" "${FAKE_SECMODEL:-apparmor}" ;;
  domstate)
    [[ -e "$STATE/dom.$vm" ]] || { echo "error: failed to get domain '$vm'" >&2; exit 1; }
    if [[ -e "$STATE/pending.$vm" ]]; then
      n=$(cut -d' ' -f1 "$STATE/pending.$vm"); target=$(cut -d' ' -f2- "$STATE/pending.$vm")
      if [[ "$n" -le 0 ]]; then echo "$target" > "$STATE/dom.$vm"; rm -f "$STATE/pending.$vm"
      else echo "$((n - 1)) $target" > "$STATE/pending.$vm"; fi
    fi
    state "$vm" ;;
  domuuid) echo "11111111-2222-3333-4444-555555555555" ;;
  dumpxml)
    [[ -e "$STATE/xml.$vm" ]] || exit 1
    cat "$STATE/xml.$vm" ;;
  define)
    n=$(sed -n -E "s/.*<name>([^<]*)<\/name>.*/\1/p" "$1" | head -n 1)
    cp "$1" "$STATE/xml.$n"
    cp "$1" "$STATE/define-count.$n.$(date +%s%N)"
    [[ -e "$STATE/dom.$n" ]] || echo "shut off" > "$STATE/dom.$n"
    echo "Domain '$n' defined from $1" ;;
  start)
    [[ -e "$STATE/never-running" ]] && exit 0
    d=0; [[ -e "$STATE/startdelay" ]] && d=$(cat "$STATE/startdelay")
    if [[ "$d" -gt 0 ]]; then echo "$d running" > "$STATE/pending.$vm"; else echo running > "$STATE/dom.$vm"; fi
    echo "Domain '$vm' started" ;;
  shutdown)
    [[ -e "$STATE/stubborn" ]] && exit 0
    d=0; [[ -e "$STATE/stopdelay" ]] && d=$(cat "$STATE/stopdelay")
    if [[ "$d" -gt 0 ]]; then echo "$d shut off" > "$STATE/pending.$vm"; else echo "shut off" > "$STATE/dom.$vm"; fi
    echo "Domain '$vm' is being shutdown" ;;
  destroy) rm -f "$STATE/pending.$vm"; echo "shut off" > "$STATE/dom.$vm"; echo "Domain '$vm' destroyed" ;;
  undefine) rm -f "$STATE/dom.$vm" "$STATE/xml.$vm"; echo "Domain '$vm' has been undefined" ;;
  domiflist)
    [[ -e "$STATE/xml.$vm" ]] || { echo "error: failed to get domain '$vm'" >&2; exit 1; }
    printf ' Interface   Type     Source   Model    MAC\n-------------------------------------------\n'
    awk -v q="'" 'BEGIN{n=0}
      /<interface/ {inif=1; mac=""; src=""}
      inif && /<mac address=/ {mac=$0; sub(".*<mac address=" q,"",mac); sub(q ".*","",mac)}
      inif && /<source bridge=/ {src=$0; sub(".*<source bridge=" q,"",src); sub(q ".*","",src)}
      /<\/interface>/ {n++; if (mac=="") mac=sprintf("52:54:00:00:00:%02x", n); printf " vnet%d   bridge   %s   virtio   %s\n", n, src, mac; inif=0}' "$STATE/xml.$vm" ;;
  domblklist) printf ' Target   Source\n------------------\n vda      /dev/md/%s-disk0\n' "$vm" ;;
  list)
    all=0; name=0
    for a in "$@"; do [[ "$a" == --all ]] && all=1; [[ "$a" == --name ]] && name=1; done
    if [[ "$name" -eq 1 ]]; then
      for f in "$STATE"/dom.*; do
        [[ -e "$f" ]] || continue
        v=${f##*/dom.}
        if [[ "$all" -eq 1 || "$(cat "$f")" == running ]]; then echo "$v"; fi
      done
      echo
    else
      printf ' Id   Name   State\n---------------------\n'
      for f in "$STATE"/dom.*; do [[ -e "$f" ]] && echo " -    ${f##*/dom.}   $(cat "$f")"; done
    fi ;;
  capabilities)
    echo "<capabilities><host>"
    echo "  <cpu><arch>x86_64</arch><model>Haswell-v4</model></cpu>"
    for m in ${FAKE_CAPS:-apparmor dac}; do echo "  <secmodel>"; echo "    <model>$m</model>"; echo "    <doi>0</doi>"; echo "  </secmodel>"; done
    echo "</host></capabilities>" ;;
esac
exit 0
SHIM
  cat > "$TEST_DIR/bin/qemu-img" <<'SHIM'
#!/usr/bin/env bash
echo "qemu-img $*" >> "$SHIM_LOG"
[[ "${FAKE_QEMU_RC:-0}" -ne 0 ]] && exit "$FAKE_QEMU_RC"
printf 'RAWIMAGE' | dd of="${*: -1}" conv=notrunc status=none
SHIM
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >> "$SHIM_LOG"
[[ "${FAKE_CURL_RC:-0}" -ne 0 ]] && exit "$FAKE_CURL_RC"
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == --output ]] && out=$2; shift; done
cp "$STATE/curl-body" "$out"
SHIM
  cat > "$TEST_DIR/bin/sha256sum" <<'SHIM'
#!/usr/bin/env bash
echo "sha256sum $*" >> "$SHIM_LOG"
exec /usr/bin/sha256sum "$@"
SHIM
  cat > "$TEST_DIR/bin/getent" <<'SHIM'
#!/usr/bin/env bash
echo "getent $*" >> "$SHIM_LOG"
[[ "$2" == 1000 ]] && { echo "qemu-libvirtd:x:1000:1000::/var/empty:/bin/false"; exit 0; }
exit 2
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

# p3_20_define_args: the standard vm-define arguments for vm1.
p3_20_define_args() {
  printf '%s\n' vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --net br-store --image "$IMG"
}

# p3_20_define: run vm-define with the standard arguments (extra args appended).
p3_20_define() {
  bash "$S/vm-define" vm1 --memory 2048 --vcpus 2 --disk "$DISK" --net br-work --net br-store --image "$IMG" "$@"
}

# p3_20_fake_dom <vm> <state>
p3_20_fake_dom() { echo "$2" > "$STATE/dom.$1"; }

# p3_20_virsh_lines: the logged virsh sub-commands, one per line (no arguments).
p3_20_virsh_cmds() {
  awk '$1 == "virsh" {print $2}' "$SHIM_LOG"
}

# p3_20_proc <pid> <vm> <uid> <capeff> <seccomp> <label>: a fake QEMU in $HPS_PROC.
p3_20_proc() {
  mkdir -p "$HPS_PROC/$1/attr"
  printf '/run/current-system/sw/bin/qemu-system-x86_64\0-name\0guest=%s,debug-threads=on\0-sandbox\0on\0' "$2" > "$HPS_PROC/$1/cmdline"
  printf 'Name:\tqemu-system-x86\nUid:\t%s\t%s\t%s\t%s\nCapPrm:\t%s\nCapEff:\t%s\nNoNewPrivs:\t1\nSeccomp:\t%s\n' "$3" "$3" "$3" "$3" "$4" "$4" "$5" > "$HPS_PROC/$1/status"
  printf '%s\n' "$6" > "$HPS_PROC/$1/attr/current"
}
