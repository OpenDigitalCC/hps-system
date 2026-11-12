# shellcheck shell=bash
#===============================================================================
# NixOS netboot, driven by build manifests.
#
# The builder (nix/build.sh) writes, under ${resources}/nixos:
#   <pin>/<profile>/{bzImage,initrd,boot.json}      and   latest  (the pin)
#   firmware/<store hash>-<name>.cpio               (shared firmware layers)
# boot.json carries the kernel command line and init path, and for a profile
# with a firmware layer (the audit image) extra_initrds: [{path, ...}], paths
# under ${resources}/nixos; nothing about a NixOS boot is hard-coded here.
# lighttpd serves the tree at /nixos/.
#===============================================================================

# nixos_resolve_pin [mac]
# Pin to boot: the host's system_pin, else the cluster's nixos_default_pin,
# else the builder's "latest" file. Prints the pin; returns 1 if none.
nixos_resolve_pin() {
  local mac="${1:-}"
  local pin="" cluster root

  if [[ -n "$mac" ]]; then
    pin="$(host_registry "$mac" get system_pin 2>/dev/null)" || pin=""
  fi
  if [[ -z "$pin" ]]; then
    cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
    if [[ -n "$cluster" ]]; then
      pin="$(cluster_registry "$cluster" get nixos_default_pin 2>/dev/null)" || pin=""
    fi
  fi
  if [[ -z "$pin" ]]; then
    root="$(hps_get_config resources)" || return 1
    if [[ -r "${root}/nixos/latest" ]]; then
      pin="$(tr -d '[:space:]' < "${root}/nixos/latest")"
    fi
  fi
  [[ -n "$pin" ]] || return 1
  printf '%s\n' "$pin"
}

# nixos_manifest_path <profile> [pin]
# Path of boot.json for a profile. Without a pin, the cluster default or
# latest is used. Profile and pin are validated; they become path parts.
nixos_manifest_path() {
  local profile="${1:-}"
  local pin="${2:-}"
  local root

  if [[ ! "$profile" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    hps_log error "nixos_manifest_path: invalid profile '${profile}'"
    return 1
  fi
  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin)" || {
      hps_log error "nixos_manifest_path: no pin (no cluster nixos_default_pin, no latest)"
      return 1
    }
  fi
  if [[ ! "$pin" =~ ^[a-z0-9][a-z0-9.-]+$ ]]; then
    hps_log error "nixos_manifest_path: invalid pin '${pin}'"
    return 1
  fi
  root="$(hps_get_config resources)" || return 1
  printf '%s/nixos/%s/%s/boot.json\n' "$root" "$pin" "$profile"
}

# nixos_ips_address
# Address the node uses to reach the IPS (the same value ipxe_boot_alpine uses).
nixos_ips_address() {
  local cluster
  cluster="$(hps_get_config active_cluster)" || return 1
  cluster_registry "$cluster" get network_dhcp_ip
}

# nixos_zfs_hostid <host key mac>
# The node's ZFS hostid: the first 8 hex digits of the sha256 of the host key
# MAC as 12 lower-case hex digits (no separators). Deterministic, so a node has
# the same id on every boot and nothing needs storing; different for every
# host. 00000000 means "unset" to the spl module, so it is never returned
# (00000001 instead). Prints the 8 digits; returns 1 for a malformed MAC.
nixos_zfs_hostid() {
  local key id
  key="$(normalise_mac "${1:-}" 2> /dev/null)" || return 1
  id="$(printf '%s' "$key" | sha256sum | cut -c1-8)"
  [[ "$id" == 00000000 ]] && id=00000001
  printf '%s\n' "$id"
}

# nixos_boot_lines <mac> <profile> [pin]
# The iPXE kernel/initrd/boot lines for a profile, from its manifest.
# Pin: argument, else the host's system_pin, else cluster default, else latest.
# Returns 1 with a log line (no output) when the manifest is unusable.
nixos_boot_lines() {
  local mac="${1:-}"
  local profile="${2:-}"
  local pin="${3:-}"
  local manifest ips cmdline init

  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin "$mac")" || {
      hps_log error "[$mac] no NixOS pin (host system_pin, cluster nixos_default_pin, latest all unset)"
      return 1
    }
  fi
  manifest="$(nixos_manifest_path "$profile" "$pin")" || return 1
  if [[ ! -r "$manifest" ]]; then
    hps_log error "[$mac] NixOS manifest missing: ${manifest}"
    return 1
  fi
  ips="$(nixos_ips_address)" || ips=""
  if [[ -z "$ips" ]]; then
    hps_log error "[$mac] NixOS boot: IPS address (network_dhcp_ip) not set"
    return 1
  fi
  cmdline="$(jq -r '.cmdline // ""' "$manifest")" || return 1
  init="$(jq -r '.init // empty' "$manifest")" || return 1
  if [[ -z "$init" ]]; then
    hps_log error "[$mac] NixOS manifest has no init: ${manifest}"
    return 1
  fi
  local extra
  extra="$(nixos_extra_initrds "$manifest")" || {
    hps_log error "[$mac] NixOS manifest names an unusable extra initrd: ${manifest}"
    return 1
  }

  local base="http://${ips}/nixos/${pin}/${profile}"
  local args="$cmdline"
  # build.sh's cmdline may already carry init=; add it only when absent.
  if [[ " ${args} " != *" init="* ]]; then
    args="${args:+${args} }init=${init}"
  fi
  # Each extra initrd also by name for the EFI stub, beside initrd=initrd: a
  # kernel that reads initrd= from its command line (no LoadFile2 initrd from
  # iPXE) then still gets every image. iPXE names an image after the last
  # part of its URL.
  local rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && args="${args} initrd=${rel##*/}"
  done <<< "$extra"
  args="${args} hps.ips=${ips} hps.mac=${HPS_BOOT_MAC:-$mac} hps.profile=${profile} hps.pin=${pin}"
  # Per-node ZFS hostid (scale test phase 2): derived from the host key MAC
  # (mac here is the registry key, never an alias boot MAC), so every port a
  # node can boot from gives the same id. spl reads spl.spl_hostid from the
  # kernel command line when it loads and prefers it to /etc/hostid; the image
  # keeps a fixed build-time networking.hostId only to satisfy NixOS.
  local zfs_hostid
  if zfs_hostid="$(nixos_zfs_hostid "$mac")"; then
    args="${args} spl.spl_hostid=0x${zfs_hostid}"
    if [[ "$(host_registry "$mac" get zfs_hostid 2>/dev/null)" != "$zfs_hostid" ]]; then
      host_registry "$mac" set zfs_hostid "$zfs_hostid" > /dev/null 2>&1 || hps_log warn "[$mac] could not record zfs_hostid"
    fi
  else
    hps_log warn "[$mac] no ZFS hostid derived (malformed host key MAC); the image default applies"
  fi
  # Registry hostname, when assigned: lets the node name its logs from the
  # first line (hps-log-target reads it); held/audit nodes have none.
  local hostname
  hostname="$(host_registry "$mac" get HOSTNAME 2>/dev/null)" || hostname=""
  if [[ "$hostname" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]]; then
    args="${args} hps.hostname=${hostname}"
  fi
  # Cluster DNS domain: the node makes its hostname <name>.<domain> so that
  # the ctrl-exec agent registers under a well-formed FQDN (hps-pair).
  local domain cluster
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  domain=""
  if [[ -n "$cluster" ]]; then
    domain="$(cluster_registry "$cluster" get network_dns_domain 2>/dev/null)" || domain=""
  fi
  if [[ "$domain" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    args="${args} hps.domain=${domain}"
  fi
  # Boot-NIC bridge (host key boot_bridge): hps-net makes the boot NIC a
  # member of it so guests can attach to the provisioning segment itself.
  local bridge
  bridge="$(host_registry "$mac" get boot_bridge 2>/dev/null)" || bridge=""
  if [[ "$bridge" =~ ^br-[a-z0-9-]{1,12}$ ]]; then
    args="${args} hps.bridge=${bridge}"
  fi
  # Builder image only: the cluster key egress_proxy (http://<host>:<port>)
  # becomes hps.proxy=, the one way out the builder uses (docs/BUILDER.md).
  # A value of another shape is logged and left out.
  if [[ "$profile" == node-builder && -n "$cluster" ]]; then
    local proxy
    proxy="$(cluster_registry "$cluster" get egress_proxy 2>/dev/null)" || proxy=""
    if [[ "$proxy" =~ ^http://[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[0-9]{1,5}$ ]]; then
      args="${args} hps.proxy=${proxy}"
    elif [[ -n "$proxy" ]]; then
      hps_log warn "[$mac] cluster key egress_proxy '${proxy}' is not http://<host>:<port>: left off the command line"
    fi
  fi
  # Audit image only: the cluster key held_reboot_after_audit=false (IPS-14)
  # keeps it up after the audit (default: it reboots into the hold loop).
  if [[ "$profile" == audit && -n "$cluster" ]]; then
    local keep_up
    keep_up="$(cluster_registry "$cluster" get held_reboot_after_audit 2>/dev/null)" || keep_up=""
    case "$keep_up" in
      false|0|no) args="${args} hps.audit_reboot=0" ;;
    esac
  fi
  printf 'kernel %s/bzImage %s\n' "$base" "$args"
  # Extra (uncompressed) initrds BEFORE the image's own compressed one: the
  # kernel unpacks them in this order, and an uncompressed archive after a
  # compressed one relies on the decompressor reporting where its data ended
  # (chain P run 29, 2026-11-11: an uncompressed cpio after the compressed
  # stage 1 left the DL360 silent). Uncompressed first is the early-microcode
  # layout.
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && printf 'initrd http://%s/nixos/%s\n' "$ips" "$rel"
  done <<< "$extra"
  printf 'initrd %s/initrd\n' "$base"
  printf 'boot\n'
}

# nixos_extra_initrds <manifest>
# The manifest's extra_initrds paths (relative to ${resources}/nixos), one per
# line; nothing for a manifest without them (every pin built before the
# firmware layer). Returns 1, with a log line, when the list is malformed, a
# path is not firmware/<plain file name>, or the file is not published: the
# boot is refused rather than served without its firmware.
nixos_extra_initrds() {
  local manifest="$1" root paths rel
  paths="$(jq -r '(.extra_initrds // []) | if type == "array" then .[] | (if (.path | type) == "string" and .path != "" then .path else "<no path>" end) else error("not a list") end' "$manifest" 2>/dev/null)" || {
    hps_log error "NixOS manifest ${manifest}: extra_initrds is not a list of {path, ...}"
    return 1
  }
  [[ -n "$paths" ]] || return 0
  root="$(hps_get_config resources)" || return 1
  while IFS= read -r rel; do
    if [[ ! "$rel" =~ ^firmware/[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
      hps_log error "NixOS manifest ${manifest}: extra initrd '${rel}' is not firmware/<file name>"
      return 1
    fi
    if [[ ! -r "${root}/nixos/${rel}" ]]; then
      hps_log error "NixOS manifest ${manifest}: extra initrd ${root}/nixos/${rel} is missing"
      return 1
    fi
  done <<< "$paths"
  printf '%s\n' "$paths"
}

# nixos_emit_boot <mac> <profile> [pin]
# Full iPXE script for a profile; on failure sends the iPXE error screen.
nixos_emit_boot() {
  local mac="$1"
  local profile="$2"
  local pin="${3:-}"
  local lines manifest

  if [[ -z "$pin" ]]; then
    pin="$(nixos_resolve_pin "$mac")" || {
      cgi_auto_fail "No NixOS pin for ${mac}: set cluster nixos_default_pin or build an image (nixos/latest)"
      return 1
    }
  fi
  manifest="$(nixos_manifest_path "$profile" "$pin")" || {
    cgi_auto_fail "NixOS profile '${profile}' or pin '${pin}' is invalid"
    return 1
  }
  lines="$(nixos_boot_lines "$mac" "$profile" "$pin")" || {
    cgi_auto_fail "NixOS boot unavailable: manifest ${manifest} missing or invalid"
    return 1
  }
  ipxe_header
  echo "# Required to prevent corrupt initrd"
  echo "imgfree"
  echo "$lines"
}

# ipxe_boot_audit <mac>
# Held hosts boot the audit profile at the cluster default pin, else latest
# (they have no system_pin yet).
ipxe_boot_audit() {
  local mac="${1:-${mac:-}}"
  hps_log info "[$mac] held: booting audit image"
  nixos_emit_boot "$mac" audit || return 1
  # The audit image runs the ctrl-exec agent and pairs (CS-1.10), so a held
  # node needs the pairing window like an assigned one.
  nixos_open_pairing_window "$mac"
}

# ipxe_hold_retry_seconds
# Seconds a held node waits between boot requests: cluster key
# hold_retry_seconds, an integer 5..3600, default 30. A value outside that
# range is logged and replaced by the default.
ipxe_hold_retry_seconds() {
  local cluster val=""
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  if [[ -n "$cluster" ]]; then
    val="$(cluster_registry "$cluster" get hold_retry_seconds 2>/dev/null)" || val=""
  fi
  if [[ -z "$val" ]]; then
    echo 30
    return 0
  fi
  if [[ "$val" =~ ^[0-9]{1,4}$ ]] && (( 10#$val >= 5 && 10#$val <= 3600 )); then
    echo $(( 10#$val ))
    return 0
  fi
  hps_log warn "cluster key hold_retry_seconds='${val}' is not an integer 5..3600; using 30"
  echo 30
}

# ipxe_held_needs_audit <mac>
# True (0) when a held host must boot the audit image: it has no stored audit,
# or the audit is marked stale (hps-onboard reaudit; cleared when a new audit
# is stored by host_audit_intake).
ipxe_held_needs_audit() {
  local mac="$1" stale=""
  host_registry "$mac" exists audit 2>/dev/null || return 0
  stale="$(host_registry "$mac" get audit_stale 2>/dev/null)" || stale=""
  [[ "$stale" == "true" ]]
}

# ipxe_int_cluster_key <key> <min> <max> <default>
# A cluster key that must be a decimal integer in MIN..MAX; absent gives the
# default, an invalid value is logged (warn) and gives the default.
ipxe_int_cluster_key() {
  local key="$1" min="$2" max="$3" def="$4" cluster val=""
  cluster="$(hps_get_config active_cluster 2>/dev/null)" || cluster=""
  if [[ -n "$cluster" ]]; then
    val="$(cluster_registry "$cluster" get "$key" 2>/dev/null)" || val=""
  fi
  if [[ -z "$val" ]]; then
    echo "$def"
    return 0
  fi
  if [[ "$val" =~ ^[0-9]{1,6}$ ]] && (( 10#$val >= min && 10#$val <= max )); then
    echo $(( 10#$val ))
    return 0
  fi
  hps_log warn "cluster key ${key}='${val}' is not an integer ${min}..${max}; using ${def}"
  echo "$def"
}

# ipxe_audit_max_concurrent
# Cluster key audit_max_concurrent (IPS-16): how many audit boots the IPS serves
# at once. An integer 0..1000, default 2; 0 means no limit.
ipxe_audit_max_concurrent() {
  ipxe_int_cluster_key audit_max_concurrent 0 1000 2
}

# ipxe_audit_timeout_seconds
# Cluster key audit_timeout_seconds (IPS-16): how long after the IPS served the
# audit image a host counts as auditing when no audit has been stored. An
# integer 30..86400, default 900.
ipxe_audit_timeout_seconds() {
  ipxe_int_cluster_key audit_timeout_seconds 30 86400 900
}

# ipxe_host_auditing <mac> <now> <timeout>
# True (0) when the host is auditing now: the IPS served it the audit image
# (host key audit_started_at, epoch) less than <timeout> seconds ago and no
# fresh audit is stored since (host_audit_intake deletes the key).
ipxe_host_auditing() {
  local mac="$1" now="$2" timeout="$3" started=""
  started="$(host_registry "$mac" get audit_started_at 2>/dev/null)" || return 1
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  ipxe_held_needs_audit "$mac" || return 1
  (( now - 10#$started < timeout ))
}

# ipxe_first_seen <mac>
# Epoch of the host's registry creation (host key initialised_at); a host
# without a usable one sorts last.
ipxe_first_seen() {
  local v="" e=""
  v="$(host_registry "$1" get initialised_at 2>/dev/null)" || v=""
  e="$(date -d "$v" +%s 2>/dev/null)" || e=""
  [[ "$e" =~ ^[0-9]+$ ]] || e=9999999999
  echo "$e"
}

# ipxe_audit_admit <mac>
# IPS-16 audit admission. Decides, under a lock so concurrent requests cannot
# both take the last slot, whether the held host that needs an audit gets the
# audit image now. Prints "admit" or "wait <running>" and returns 0 / 1.
#
#   running  hosts (other than this one) that are auditing: audit_started_at
#            set, younger than audit_timeout_seconds, no audit stored since.
#   ahead    other held hosts waiting for an audit that were first seen
#            earlier (initialised_at, then MAC) and are still asking (their
#            last_boot_at is within 3 x hold_retry_seconds + 30 s); a host
#            that went away does not keep a slot back.
#   admit    the host is already auditing (a repeat request, e.g. after a
#            reboot of the audit image: audit_started_at is kept, so the
#            timeout counts from the first serve); or the limit is 0; or
#            limit - running > ahead (first seen, first audited).
# Admission sets audit_started_at and logs at info.
ipxe_audit_admit() {
  local mac="$1"
  local lock="${HPS_AUDIT_LOCK:-/tmp/hps-audit-admission.lock}"
  (
    local limit now timeout retry window h running=0 ahead=0 me_seen h_seen last
    limit="$(ipxe_audit_max_concurrent)"
    timeout="$(ipxe_audit_timeout_seconds)"
    retry="$(ipxe_hold_retry_seconds)"
    window=$(( 3 * retry + 30 ))
    now="$(date +%s)"
    exec 9> "$lock" || { echo "admit"; exit 0; }
    flock -w 10 9 || { hps_log warn "[$mac] audit admission lock busy; admitting"; echo "admit"; exit 0; }

    if ipxe_host_auditing "$mac" "$now" "$timeout"; then
      hps_log info "[$mac] audit image re-served (its audit is already running)"
      echo "admit"
      exit 0
    fi
    me_seen="$(ipxe_first_seen "$mac")"
    while IFS= read -r h; do
      [[ -n "$h" && "$h" != "$mac" ]] || continue
      if ipxe_host_auditing "$h" "$now" "$timeout"; then
        running=$(( running + 1 ))
        continue
      fi
      [[ "$(host_registry "$h" get STATE 2>/dev/null)" == HELD ]] || continue
      ipxe_held_needs_audit "$h" || continue
      last="$(host_registry "$h" get last_boot_at 2>/dev/null)" || last=""
      [[ "$last" =~ ^[0-9]+$ ]] || continue
      (( now - 10#$last <= window )) || continue
      h_seen="$(ipxe_first_seen "$h")"
      if (( h_seen < me_seen )) || { (( h_seen == me_seen )) && [[ "$h" < "$mac" ]]; }; then
        ahead=$(( ahead + 1 ))
      fi
    done < <(list_cluster_hosts 2>/dev/null)

    if (( limit == 0 )) || (( limit - running > ahead )); then
      host_registry "$mac" set audit_started_at "$now" > /dev/null 2>&1 || true
      hps_log info "[$mac] audit admitted: ${running} other(s) running, limit ${limit} (0 = none), ${ahead} waiting ahead"
      echo "admit"
      exit 0
    fi
    echo "wait ${running}"
    exit 1
  )
}

# ipxe_hold_script <mac> <message>
# The hold script (IPS-14): print "HPS: <mac> is held; <message>", sleep, chain
# back to the boot URL; the chain failing retries. <message> may contain
# @RETRY@, replaced by the retry interval. Nothing secret is in the script.
ipxe_hold_script() {
  local mac="$1" msg="$2" n
  n="$(ipxe_hold_retry_seconds)"
  msg="${msg//@RETRY@/${n}}"
  cgi_header_plain
  cat <<EOF
#!ipxe
echo HPS: ${mac} is held; ${msg}
sleep ${n}
:retry
chain --replace ${CGI_URL}?cmd=init || goto failed
exit
:failed
echo HPS: the IPS did not answer; retry in ${n} s
sleep ${n}
goto retry
EOF
}

# ipxe_boot_held <mac>
# A HELD host without a (fresh) audit boots the audit image when the audit
# admission (IPS-16, ipxe_audit_admit) has a slot for it; otherwise it gets the
# hold script with the reason. One with its audit stored waits at iPXE: a
# script that prints the hold message, sleeps, then chains back to the boot
# URL the DHCP boot option points at (boot_manager.sh?cmd=init). The next
# request after hps-onboard assign finds the host assigned and boots its role
# (assigned hosts never come here, so audits never delay a role boot); no power
# action is involved. If the IPS is down the chain fails, iPXE shows its error
# and the script retries.
ipxe_boot_held() {
  local mac="${1:-${mac:-}}"
  local verdict running
  if ipxe_held_needs_audit "$mac"; then
    if verdict="$(ipxe_audit_admit "$mac")"; then
      if ! ipxe_boot_audit "$mac"; then
        host_registry "$mac" delete audit_started_at > /dev/null 2>&1 || true
        return 1
      fi
      return 0
    fi
    running="${verdict#wait }"
    hps_log debug "[$mac] held, no audit slot free (${running} running): hold script"
    ipxe_hold_script "$mac" "waiting for an audit slot (${running} running, retry in @RETRY@ s)"
    return 0
  fi
  hps_log debug "[$mac] held with audit stored: hold script, retry in $(ipxe_hold_retry_seconds)s"
  ipxe_hold_script "$mac" "waiting for a role (retry in @RETRY@ s)"
}

# nixos_image_profile <host profile>
# Map a registry HOST_PROFILE to a built image profile.
nixos_image_profile() {
  case "${1:-}" in
    CONVERGED) echo node-converged ;;
    CONTAINER_HOST) echo node-cnh ;;
    BUILDER)   echo node-builder ;;
    DEFAULT)   echo node-base ;;
    *)         return 1 ;;
  esac
}

# ipxe_boot_nixos <mac>
# Network boot of an assigned NixOS host: image profile from HOST_PROFILE.
ipxe_boot_nixos() {
  local mac="${1:-${mac:-}}"
  local host_profile image
  host_profile="$(host_registry "$mac" get HOST_PROFILE 2>/dev/null)" || host_profile=""
  image="$(nixos_image_profile "$host_profile")" || {
    cgi_auto_fail "No NixOS image profile for host profile '${host_profile}' (known: CONVERGED, CONTAINER_HOST, BUILDER, DEFAULT)"
    return 1
  }
  hps_log info "[$mac] NixOS network boot: host profile ${host_profile} -> image ${image}"
  nixos_emit_boot "$mac" "$image" || return 1
  nixos_open_pairing_window "$mac"
}

# nixos_open_pairing_window <mac>
# A RAM-booted node pairs with ctrl-exec on every boot: clear the previous
# pairing record and open the dispatcher's pairing window (ADR 0002). The
# window is single and shared; a failure to open is logged, never fatal.
nixos_open_pairing_window() {
  local mac="$1"
  host_registry "$mac" delete ctrl_exec_paired_at > /dev/null 2>&1 || true
  host_registry "$mac" delete ctrl_exec_paired > /dev/null 2>&1 || true
  if ! ce_pairing_window_open "${CTRL_EXEC_PAIR_WINDOW:-300}" > /dev/null 2>&1 < /dev/null; then
    hps_log warn "[$mac] pairing window not opened (already open, or dispatcher error)"
  fi
  return 0
}
