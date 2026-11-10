#!/usr/bin/env bash
#
# hps-iscsi-name - write the iSCSI initiator name for this boot.
#
# Runs as a oneshot (nix/modules/profiles/compute.nix) after hps-node-init has
# set the kernel hostname from the registry, and before iscsid starts.
# /etc/iscsi/initiatorname.iscsi is a symlink to $HPS_RUN_DIR/initiatorname.iscsi
# (the image holds no per-node value).
#
#   name = iqn.2026-11.hps.<cluster>:<fqdn>
#
# <fqdn> is the kernel hostname (docs/NAMING.md: one identity per node,
# <label>.<cluster dns domain>, set by hps-node-init), lowercased; <cluster> is
# the cluster name from the IPS (cmd=cluster_variable&name=CLUSTER_NAME). The
# naming authority is hps.<cluster>, the same form as the target IQNs
# (iqn.2026-11.hps.<cluster>:<host>:<name>). LIO (rtslib-fb) only accepts an IQN
# with a second dot after the date, iqn.YYYY-MM.<authority-with-a-dot>[:x]
# (^iqn\.[0-9]{4}-[0-1][0-9]\..*\..*); hps.<cluster> supplies it, and the name
# is checked against that rule before it is written. Anything outside
# [a-z0-9.-] in the hostname, or [a-z0-9-] in the cluster, is refused rather
# than rewritten, so two nodes cannot collapse to one name.
#
# Overrides for tests: HPS_RUN_DIR, HPS_HOSTNAME (instead of hostname(1)),
# HPS_CLUSTER (instead of asking the IPS), HPS_CMDLINE (file, for hps.ips).

set -euo pipefail

: "${HPS_RUN_DIR:=/run/hps}"
: "${HPS_CMDLINE:=/proc/cmdline}"

log() {
  printf '[hps-iscsi-name] %s\n' "$*" >&2
}

current_hostname() {
  if [[ -v HPS_HOSTNAME ]]; then
    printf '%s\n' "$HPS_HOSTNAME"
    return 0
  fi
  log "+ hostname"
  hostname
}

cmdline_value() {
  local key="$1" word
  # shellcheck disable=SC2013  # words of a one-line file
  for word in $(cat "$HPS_CMDLINE"); do
    if [[ "$word" == "$key="* ]]; then
      printf '%s\n' "${word#"$key"=}"
      return 0
    fi
  done
  return 1
}

# cluster_name: the cluster name, from HPS_CLUSTER or the IPS.
cluster_name() {
  local ips
  if [[ -v HPS_CLUSTER ]]; then
    printf '%s\n' "$HPS_CLUSTER"
    return 0
  fi
  ips=$(cmdline_value hps.ips || true)
  if [[ -z "$ips" ]]; then
    log "+ ip -j route (hps.ips absent: using the default gateway)"
    ips=$(ip -j route | jq -r '[.[] | select(.dst == "default")][0].gateway // empty')
  fi
  [[ -n "$ips" ]] || return 1
  log "+ curl http://${ips}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=CLUSTER_NAME"
  curl -fsS "http://${ips}/cgi-bin/boot_manager.sh?cmd=cluster_variable&name=CLUSTER_NAME"
}

main() {
  local full cluster name target
  full=$(current_hostname)
  full="${full,,}"
  if [[ -z "$full" || "$full" == "localhost" || "$full" == "(none)" ]]; then
    log "no registry hostname yet ('${full}'): not writing an initiator name"
    exit 1
  fi
  if [[ ! "$full" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
    log "hostname '${full}' is not usable in an IQN"
    exit 1
  fi
  cluster=$(cluster_name || true)
  cluster="${cluster,,}"
  if [[ ! "$cluster" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    log "cluster name '${cluster}' (from the IPS) is not usable in an IQN"
    exit 1
  fi
  name="iqn.2026-11.hps.${cluster}:${full}"
  if [[ ! "$name" =~ ^iqn\.[0-9]{4}-[0-1][0-9]\..*\..* ]]; then
    log "'${name}' would be refused by LIO (needs iqn.YYYY-MM.<authority with a dot>)"
    exit 1
  fi
  target="$HPS_RUN_DIR/initiatorname.iscsi"
  log "+ mkdir -p $HPS_RUN_DIR"
  mkdir -p "$HPS_RUN_DIR"
  log "+ write $target (InitiatorName=${name})"
  printf 'InitiatorName=%s\n' "$name" > "$target.tmp"
  mv -f "$target.tmp" "$target"
}

main "$@"
