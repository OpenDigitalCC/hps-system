#!/usr/bin/env bash
#
# hps-audit - read-only hardware audit of an unknown node, reported to the IPS.
#
# Runs once from the audit image (nix/modules/hps-audit.nix, oneshot after
# network-online). Collects CPU, memory, NUMA, PCI, storage-controller mode,
# block devices by id, existing filesystems and pools, NICs and DMI, assembles
# one JSON document and POSTs it to
#   http://<ips>/cgi-bin/boot_manager.sh?cmd=node_audit
# where <ips> is hps.ips= on the kernel command line (fallback: the default
# gateway). Then prints a banner to the consoles and exits 0; the system idles.
#
# STRICTLY READ-ONLY: every command here only reads. `zpool import` with no
# pool name and no -f lists importable pools and imports nothing. Never add a
# command that writes to a disk (mdadm, wipefs, dd, zpool create/import <pool>,
# parted, mkfs) - test_p1_41 asserts their absence from the command log.
#
# Overrides for tests: HPS_CMDLINE (file, default /proc/cmdline), HPS_SYS
# (default /sys), HPS_PROC (default /proc), HPS_CONSOLES (space list of
# console devices), HPS_AUDIT_OUT (keep the JSON here), HPS_IPS (skip
# discovery).

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_SYS:=/sys}"
: "${HPS_PROC:=/proc}"
: "${HPS_CONSOLES:=/dev/console /dev/tty0 /dev/ttyS0}"
: "${HPS_AUDIT_OUT:=/run/hps/audit.json}"

WORK="/tmp/hps-audit-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log() {
  printf '[hps-audit] %s\n' "$*" >&2
}

# capture <name> <command...>: log the command, run it, keep stdout in
# $WORK/<name>; a failing command leaves an empty file (partial output is not
# trusted) and is logged, never fatal: an audit with gaps is still an audit.
capture() {
  local name="$1"
  shift
  log "+ $*"
  set +e
  "$@" > "$WORK/$name" 2>> "$WORK/$name.err"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    log "  rc=$rc (continuing; output discarded)"
    : > "$WORK/$name"
    printf '%s\n' "$rc" > "$WORK/$name.rc"
  fi
}

# json_or_null <file>: the file's content if it parses as JSON, else null.
json_or_null() {
  local file="$1"
  if [[ -s "$file" ]] && jq -e . "$file" > /dev/null 2>&1; then
    cat "$file"
  else
    printf 'null\n'
  fi
}

cmdline_value() {
  local key="$1"
  local word
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

discover_ips() {
  if [[ -n "${HPS_IPS:-}" ]]; then
    printf '%s\n' "$HPS_IPS"
    return 0
  fi
  if cmdline_value hps.ips; then
    return 0
  fi
  log "+ ip -j route (hps.ips absent from the command line; using the default gateway)"
  ip -j route | jq -r '[.[] | select(.dst == "default")][0].gateway // empty'
}

# read_sys <path>: file content or empty, one line, never fatal.
read_sys() {
  local path="$1"
  if [[ -r "$path" ]]; then
    tr -d '\n' < "$path"
  fi
}

collect_dmi() {
  local base="$HPS_SYS/class/dmi/id"
  jq -n \
    --arg sys_vendor "$(read_sys "$base/sys_vendor")" \
    --arg product_name "$(read_sys "$base/product_name")" \
    --arg product_serial "$(read_sys "$base/product_serial")" \
    --arg board_name "$(read_sys "$base/board_name")" \
    --arg bios_version "$(read_sys "$base/bios_version")" \
    '$ARGS.named' > "$WORK/dmi.json"
}

collect_memory() {
  log "+ awk on $HPS_PROC/meminfo"
  awk '/^(MemTotal|MemFree|MemAvailable|SwapTotal|HugePages_Total|Hugepagesize):/ {
         gsub(":", "", $1); printf "%s%s\"%s\":%s", sep, "", $1, $2; sep="," }
       BEGIN { printf "{" } END { printf "}\n" }' "$HPS_PROC/meminfo" > "$WORK/meminfo.json"
}

# hpsa (and smartpqi) expose hba_mode_enabled per SCSI host when the driver is
# loaded; 1 = HBA mode, 0 = RAID mode. Absent on other controllers.
collect_controller_mode() {
  local host file
  log "+ reading $HPS_SYS/class/scsi_host/*/hba_mode_enabled"
  : > "$WORK/hosts.txt"
  for host in "$HPS_SYS"/class/scsi_host/*; do
    [[ -d "$host" ]] || continue
    file="$host/hba_mode_enabled"
    if [[ -r "$file" ]]; then
      printf '%s\t%s\t%s\n' "$(basename "$host")" "$(read_sys "$host/proc_name")" "$(read_sys "$file")" >> "$WORK/hosts.txt"
    fi
  done
  jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
            | {host: .[0], driver: .[1], hba_mode_enabled: (.[2] | tonumber? // .[2])})' \
    "$WORK/hosts.txt" > "$WORK/hosts.json"
}

assemble() {
  local raid_indicator
  # Any disk whose model says "LOGICAL VOLUME" is a Smart Array logical drive:
  # the controller is still in RAID mode for that disk.
  raid_indicator=$(json_or_null "$WORK/lsblk" \
    | jq '[.. | objects | .model? // empty | tostring] | any(test("LOGICAL VOLUME"))')
  jq -n \
    --arg schema "hps-audit/1" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hostname "$(hostname 2>/dev/null || true)" \
    --slurpfile dmi "$WORK/dmi.json" \
    --argjson cpu "$(json_or_null "$WORK/lscpu")" \
    --slurpfile memory "$WORK/meminfo.json" \
    --rawfile numa "$WORK/numactl" \
    --rawfile pci "$WORK/lspci" \
    --slurpfile hosts "$WORK/hosts.json" \
    --argjson raid "$raid_indicator" \
    --argjson block "$(json_or_null "$WORK/lsblk")" \
    --rawfile disk_by_id "$WORK/by-id" \
    --rawfile blkid "$WORK/blkid" \
    --rawfile zpool_import "$WORK/zpool" \
    --argjson link "$(json_or_null "$WORK/iplink")" \
    --argjson addr "$(json_or_null "$WORK/ipaddr")" \
    '{
      schema: $schema,
      collected_at: $collected_at,
      hostname: $hostname,
      dmi: $dmi[0],
      cpu: $cpu,
      memory: $memory[0],
      numa: $numa,
      pci: $pci,
      storage_controllers: { scsi_hosts: $hosts[0], raid_mode_indicator: $raid },
      block: $block,
      disk_by_id: $disk_by_id,
      blkid: $blkid,
      zpool_import: $zpool_import,
      net: { link: $link, addr: $addr }
    }' > "$HPS_AUDIT_OUT"
}

post_audit() {
  local ips="$1"
  local url="http://${ips}/cgi-bin/boot_manager.sh?cmd=node_audit"
  log "+ curl POST $url"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    --data-binary "@$HPS_AUDIT_OUT" "$url"
}

banner() {
  local status="$1"
  local ips="$2"
  local text con
  printf -v text '\n==================== HPS AUDIT ====================\n%s\nIPS: %s\nThis node is held for onboarding. Nothing was written to any disk.\nThe system stays up; the IPS decides what happens next.\n===================================================\n' \
    "$status" "$ips"
  printf '%s' "$text"
  for con in $HPS_CONSOLES; do
    if [[ -w "$con" ]]; then
      printf '%s' "$text" > "$con" 2>/dev/null || true
    fi
  done
}

main() {
  local ips status
  mkdir -p "$(dirname "$HPS_AUDIT_OUT")"
  ips=$(discover_ips || true)
  log "IPS: ${ips:-<none>}"

  collect_dmi
  capture lscpu lscpu -J
  collect_memory
  capture numactl numactl -H
  capture lspci lspci -k -mm
  collect_controller_mode
  capture lsblk lsblk -O -J
  capture by-id ls -l /dev/disk/by-id
  capture blkid blkid
  capture zpool zpool import
  capture iplink ip -j link
  capture ipaddr ip -j addr

  assemble
  log "audit JSON: $HPS_AUDIT_OUT ($(wc -c < "$HPS_AUDIT_OUT") bytes)"

  if [[ -z "$ips" ]]; then
    status="NOT SENT: no IPS address (hps.ips= missing and no default gateway)"
  elif post_audit "$ips"; then
    status="Audit sent to the IPS."
  else
    status="SEND FAILED: the IPS did not accept the audit (see journal)."
  fi
  banner "$status" "${ips:-unknown}"
  return 0
}

main "$@"
