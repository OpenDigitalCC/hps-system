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
# gateway). Besides the hardware inventory it keeps the evidence needed to
# explain a missing or mis-reported drive: the kernel log (capped), the SCSI
# host and device attributes, /proc/scsi/scsi and the hpsa/smartpqi driver
# bindings. The JSON is kept under HPS_AUDIT_TRIM_BYTES (the intake refuses
# more than HPS_AUDIT_MAX_BYTES, 256 KiB) by dropping the oldest dmesg lines.
# Then prints a banner to the consoles and exits 0; the system idles.
#
# STRICTLY READ-ONLY: every command here only reads. `zpool import` with no
# pool name and no -f lists importable pools and imports nothing. Never add a
# command that writes to a disk (mdadm, wipefs, dd, zpool create/import <pool>,
# parted, mkfs) - test_p1_41 asserts their absence from the command log.
#
# Overrides for tests: HPS_CMDLINE (file, default /proc/cmdline), HPS_SYS
# (default /sys), HPS_PROC (default /proc), HPS_CONSOLES (space list of
# console devices), HPS_AUDIT_OUT (keep the JSON here), HPS_IPS (skip
# discovery), HPS_AUDIT_TRIM_BYTES
# (default 204800), HPS_DMESG_LINES (default 2000).
#
# BMC identity (IPS-08): `ipmitool lan print` and `ipmitool mc info` when a local
# IPMI (KCS) device node exists under HPS_DEV (read-only queries), and the DMI
# types 38 (IPMI device) and 42 (management controller host interface, i.e. a
# Redfish host interface) from $HPS_SYS/firmware/dmi/entries. The controller maps
# this, with dmi.sys_vendor and dmi.product_name, to a BMC driver
# (lib/bmc/drivers.map).

set -euo pipefail

: "${HPS_CMDLINE:=/proc/cmdline}"
: "${HPS_SYS:=/sys}"
: "${HPS_PROC:=/proc}"
: "${HPS_CONSOLES:=/dev/console /dev/tty0 /dev/ttyS0}"
: "${HPS_AUDIT_OUT:=/run/hps/audit.json}"
: "${HPS_AUDIT_TRIM_BYTES:=204800}"
: "${HPS_DMESG_LINES:=2000}"
: "${HPS_DEV:=/dev}"

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

# ipmi_device_present: a local IPMI interface node exists (needs ipmi_si and
# ipmi_devintf loaded; hps-audit.nix loads them).
ipmi_device_present() {
  local n
  for n in "$HPS_DEV/ipmi0" "$HPS_DEV/ipmi/0" "$HPS_DEV/ipmidev/0"; do
    [[ -e "$n" ]] && return 0
  done
  return 1
}

# dmi_entry_count <type>: number of DMI entries of that type (0 when none).
dmi_entry_count() {
  local type="$1" n=0 e
  for e in "$HPS_SYS/firmware/dmi/entries/$type-"*; do
    [[ -e "$e" ]] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# collect_bmc: bmc.json {ipmi_device, lan:{mac,ip_source,ip}, mc:{manufacturer_id,
# product_id, firmware}, dmi38, dmi42}. The ipmitool calls only read.
collect_bmc() {
  local present=false
  if ipmi_device_present; then
    present=true
    capture bmc-lan ipmitool lan print
    capture bmc-mc ipmitool mc info
  else
    log "no local IPMI device node; skipping ipmitool"
    : > "$WORK/bmc-lan"
    : > "$WORK/bmc-mc"
  fi
  jq -n \
    --argjson present "$present" \
    --rawfile lan "$WORK/bmc-lan" \
    --rawfile mc "$WORK/bmc-mc" \
    --argjson dmi38 "$(dmi_entry_count 38)" \
    --argjson dmi42 "$(dmi_entry_count 42)" \
    'def val($txt; $k): ($txt | split("\n") | map(select(test("^" + $k + "\\s*:"))) | .[0] // "" | sub("^[^:]*:\\s*"; "") | sub("\\s+$"; ""));
     {
       ipmi_device: $present,
       lan: { mac: val($lan; "MAC Address"), ip_source: val($lan; "IP Address Source"), ip: val($lan; "IP Address") },
       mc: { manufacturer_id: (val($mc; "Manufacturer ID")), product_id: (val($mc; "Product ID") | sub("\\s.*$"; "")), firmware: val($mc; "Firmware Revision") },
       dmi38: $dmi38,
       dmi42: $dmi42
     }' > "$WORK/bmc.json"
}

collect_memory() {
  log "+ awk on $HPS_PROC/meminfo"
  awk '/^(MemTotal|MemFree|MemAvailable|SwapTotal|HugePages_Total|Hugepagesize):/ {
         gsub(":", "", $1); printf "%s%s\"%s\":%s", sep, "", $1, $2; sep="," }
       BEGIN { printf "{" } END { printf "}\n" }' "$HPS_PROC/meminfo" > "$WORK/meminfo.json"
}

# read_attr <path>: file content, trailing blanks trimmed (SCSI vendor/model
# are space padded), empty if unreadable. Never fatal.
read_attr() {
  local path="$1" v=""
  if [[ -r "$path" ]]; then
    v=$(tr -d '\n' < "$path" 2>/dev/null || true)
  fi
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# Every SCSI host, whatever attributes it has: proc_name (driver), and when
# the driver provides them hba_mode_enabled (hpsa: 1 = HBA, 0 = RAID),
# transport_mode, firmware_revision. A missing attribute is left out of that
# host's object; the host is never skipped.
collect_scsi_hosts() {
  local host
  log "+ reading $HPS_SYS/class/scsi_host/*/{proc_name,hba_mode_enabled,transport_mode,firmware_revision}"
  : > "$WORK/hosts.ndjson"
  for host in "$HPS_SYS"/class/scsi_host/*; do
    [[ -d "$host" ]] || continue
    jq -nc \
      --arg host "$(basename "$host")" \
      --arg driver "$(read_attr "$host/proc_name")" \
      --arg hba "$(read_attr "$host/hba_mode_enabled")" \
      --arg transport_mode "$(read_attr "$host/transport_mode")" \
      --arg firmware_revision "$(read_attr "$host/firmware_revision")" \
      '{host: $host}
       + (if $driver != "" then {driver: $driver} else {} end)
       + (if $hba != "" then {hba_mode_enabled: ($hba | tonumber? // $hba)} else {} end)
       + (if $transport_mode != "" then {transport_mode: $transport_mode} else {} end)
       + (if $firmware_revision != "" then {firmware_revision: $firmware_revision} else {} end)' \
      >> "$WORK/hosts.ndjson"
  done
  jq -s '.' "$WORK/hosts.ndjson" > "$WORK/hosts.json"
}

# Every SCSI device (the layer that names a drive the controller exposes, with
# or without a block device): vendor, model, state, type.
collect_scsi_devices() {
  local dev
  log "+ reading $HPS_SYS/class/scsi_device/*/device/{vendor,model,state,type}"
  : > "$WORK/scsidev.ndjson"
  for dev in "$HPS_SYS"/class/scsi_device/*; do
    [[ -d "$dev" ]] || continue
    jq -nc \
      --arg id "$(basename "$dev")" \
      --arg vendor "$(read_attr "$dev/device/vendor")" \
      --arg model "$(read_attr "$dev/device/model")" \
      --arg state "$(read_attr "$dev/device/state")" \
      --arg type "$(read_attr "$dev/device/type")" \
      '{id: $id}
       + (if $vendor != "" then {vendor: $vendor} else {} end)
       + (if $model != "" then {model: $model} else {} end)
       + (if $state != "" then {state: $state} else {} end)
       + (if $type != "" then {type: $type} else {} end)' \
      >> "$WORK/scsidev.ndjson"
  done
  jq -s '.' "$WORK/scsidev.ndjson" > "$WORK/scsidev.json"
}

# Driver binding: the directory listing of /sys/bus/pci/drivers/<driver>/ for
# the Smart Array drivers; PCI addresses in it are the bound controllers. null
# when the driver is not loaded.
collect_pci_drivers() {
  local drv dir
  log "+ ls $HPS_SYS/bus/pci/drivers/{hpsa,smartpqi}/"
  : > "$WORK/pcidrv.ndjson"
  for drv in hpsa smartpqi; do
    dir="$HPS_SYS/bus/pci/drivers/$drv"
    if [[ -d "$dir" ]]; then
      ls -1 "$dir" > "$WORK/pcidrv.list" 2>/dev/null || : > "$WORK/pcidrv.list"
      jq -nc --arg drv "$drv" --rawfile list "$WORK/pcidrv.list" \
        '{($drv): ($list | split("\n") | map(select(length > 0)))}' >> "$WORK/pcidrv.ndjson"
    else
      jq -nc --arg drv "$drv" '{($drv): null}' >> "$WORK/pcidrv.ndjson"
    fi
  done
  jq -s 'add' "$WORK/pcidrv.ndjson" > "$WORK/pcidrv.json"
}

collect_proc_scsi() {
  log "+ cat $HPS_PROC/scsi/scsi"
  if [[ -r "$HPS_PROC/scsi/scsi" ]]; then
    cat "$HPS_PROC/scsi/scsi" > "$WORK/procscsi" 2>/dev/null || : > "$WORK/procscsi"
  else
    : > "$WORK/procscsi"
  fi
}

# The kernel log: dmesg --json when the installed dmesg has it, else plain
# text; kept as one line per message, newest HPS_DMESG_LINES only. This is how
# a drive the OS cannot see gets explained (hpsa logs what it masks/skips).
collect_dmesg() {
  capture dmesg-json dmesg --json
  if [[ ! -f "$WORK/dmesg-json.rc" ]] && jq -e '.dmesg | type == "array"' "$WORK/dmesg-json" > /dev/null 2>&1; then
    jq -r '.dmesg[] | "[\(.time // 0)] \(.msg)"' "$WORK/dmesg-json" > "$WORK/dmesg-all"
  else
    capture dmesg-text dmesg
    cp "$WORK/dmesg-text" "$WORK/dmesg-all"
  fi
  tail -n "$HPS_DMESG_LINES" "$WORK/dmesg-all" > "$WORK/dmesg.lines"
  rm -f "$WORK/dmesg-json" "$WORK/dmesg-text" "$WORK/dmesg-all"
}

# assemble <dmesg-line-count>: the audit JSON with the last N dmesg lines.
assemble() {
  local keep="$1"
  local raid_indicator
  # Any disk whose model says "LOGICAL VOLUME" is a Smart Array logical drive:
  # the controller is still in RAID mode for that disk.
  raid_indicator=$(json_or_null "$WORK/lsblk" \
    | jq '[.. | objects | .model? // empty | tostring] | any(test("LOGICAL VOLUME"))')
  tail -n "$keep" "$WORK/dmesg.lines" > "$WORK/dmesg.keep"
  jq -n \
    --arg schema "hps-audit/1" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hostname "$(hostname 2>/dev/null || true)" \
    --slurpfile dmi "$WORK/dmi.json" \
    --slurpfile bmc "$WORK/bmc.json" \
    --argjson cpu "$(json_or_null "$WORK/lscpu")" \
    --slurpfile memory "$WORK/meminfo.json" \
    --rawfile numa "$WORK/numactl" \
    --rawfile pci "$WORK/lspci" \
    --slurpfile hosts "$WORK/hosts.json" \
    --slurpfile scsidev "$WORK/scsidev.json" \
    --slurpfile pcidrv "$WORK/pcidrv.json" \
    --rawfile proc_scsi "$WORK/procscsi" \
    --rawfile dmesg_text "$WORK/dmesg.keep" \
    --argjson dmesg_total "$(wc -l < "$WORK/dmesg.lines")" \
    --argjson raid "$raid_indicator" \
    --argjson block "$(json_or_null "$WORK/lsblk")" \
    --rawfile disk_by_id "$WORK/by-id" \
    --rawfile blkid "$WORK/blkid" \
    --rawfile zpool_import "$WORK/zpool" \
    --argjson link "$(json_or_null "$WORK/iplink")" \
    --argjson addr "$(json_or_null "$WORK/ipaddr")" \
    '($dmesg_text | split("\n") | map(select(length > 0))) as $dm
    | {
      schema: $schema,
      collected_at: $collected_at,
      hostname: $hostname,
      dmi: $dmi[0],
      bmc: $bmc[0],
      cpu: $cpu,
      memory: $memory[0],
      numa: $numa,
      pci: $pci,
      storage_controllers: {
        scsi_hosts: $hosts[0],
        pci_drivers: $pcidrv[0],
        raid_mode_indicator: $raid
      },
      scsi_devices: $scsidev[0],
      proc_scsi: $proc_scsi,
      dmesg: $dm,
      dmesg_trimmed: (($dm | length) < $dmesg_total),
      block: $block,
      disk_by_id: $disk_by_id,
      blkid: $blkid,
      zpool_import: $zpool_import,
      net: { link: $link, addr: $addr }
    }' > "$HPS_AUDIT_OUT"
}

# assemble_capped: assemble with all kept dmesg lines, then halve them until
# the JSON fits HPS_AUDIT_TRIM_BYTES (the intake limit is 256 KiB).
assemble_capped() {
  local keep size
  keep=$(wc -l < "$WORK/dmesg.lines")
  assemble "$keep"
  size=$(wc -c < "$HPS_AUDIT_OUT")
  while [[ "$size" -gt "$HPS_AUDIT_TRIM_BYTES" && "$keep" -gt 0 ]]; do
    keep=$((keep / 2))
    log "audit JSON is $size bytes (> $HPS_AUDIT_TRIM_BYTES); keeping the last $keep dmesg lines"
    assemble "$keep"
    size=$(wc -c < "$HPS_AUDIT_OUT")
  done
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
  collect_bmc
  capture lscpu lscpu -J
  collect_memory
  capture numactl numactl -H
  capture lspci lspci -k -mm
  collect_scsi_hosts
  collect_scsi_devices
  collect_pci_drivers
  collect_proc_scsi
  capture lsblk lsblk -O -J
  capture by-id ls -l /dev/disk/by-id
  capture blkid blkid
  capture zpool zpool import
  capture iplink ip -j link
  capture ipaddr ip -j addr
  collect_dmesg

  assemble_capped
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
