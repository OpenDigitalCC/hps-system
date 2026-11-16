# shellcheck shell=bash
#===============================================================================
# The node bundle, served by the IPS (plan step 2, docs/BUNDLE.md).
#
# A node booted from the stock starter runs nothing of HPS until it asks. It
# fetches one bootstrap script and one archive, the bundle, from the IPS
# (boot_manager.sh cmd=node_bootstrap, cmd=node_bundle), plus its package list
# and its sysadmin key (cmd=node_packages, cmd=node_sysadmin_keys). All of it is
# plain HTTP on the provisioning network; nothing here is secret.
#
# The archive is built from the tree on every request: a tar of node-manager/bundle
# (init, adapter, allowlist, bootstrap.sh) with the node scripts of the tree
# beside it, so a script changed on the IPS is in the next bundle a node fetches.
# The build is deterministic (sorted, fixed time and owner), so the same tree gives
# the same bytes and the same bundle id.
#===============================================================================

# One OpenSSH public key per line, no options in front of it. The node checks
# the same shape (node-manager/bundle/init, KEY_RE).
NODE_KEY_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?$'

# _node_tree_base [base]: the tree to build from (default: this system).
_node_tree_base() {
  local base="${1:-}"
  [[ -n "$base" ]] || base="$(hps_get_config system_base)" || return 1
  printf '%s\n' "$base"
}

# node_bundle_tar [base]
# The node bundle, a gzip-compressed tar, on stdout.
#   bundle/*                       as they are (init, role, adapter/, allowlist, bootstrap.sh, actions/)
#   nixos-26/scripts/*             as actions/*       (the node actions, not forked)
#   nixos-26/plugins/*             as plugins/*       (the monitoring checks, as they are)
#   apparmor/*                     as apparmor/*      (the libvirt profile texts the pinned
#                                  images' nix module reads as well)
#   plugins/hps-node/hps-node.sh   as actions/hps-node
#   nixos-26/boot/hps-pair.sh      as lib/hps-pair   (the existing pairing flow)
#   nixos-26/boot/hps-{time,iscsi-name,osvc-config,md-event,shutdown-storage}.sh
#                                  as lib/hps-*      (what the pinned images run as units; the
#                                  starter node runs the same files, docs/BUNDLE.md)
# Returns 1 with a log line when the tree has no bundle.
node_bundle_tar() {
  local base nm
  base="$(_node_tree_base "${1:-}")" || return 1
  nm="${base}/node-manager"
  if [[ ! -x "${nm}/bundle/init" || ! -f "${nm}/bundle/allowlist" ]]; then
    hps_log error "node_bundle_tar: ${nm}/bundle has no init or allowlist"
    return 1
  fi
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode='go-w,a-s' -cf - \
    --transform='s,^scripts\(/\|$\),actions\1,' \
    --transform='s,^hps-node\.sh$,actions/hps-node,' \
    --transform='s,^\(hps-[a-z-]*\)\.sh$,lib/\1,' \
    -C "${nm}/bundle" . \
    -C "${nm}/nixos-26" scripts plugins \
    -C "${nm}" apparmor \
    -C "${nm}/nixos-26/boot" hps-pair.sh hps-time.sh hps-iscsi-name.sh hps-osvc-config.sh hps-md-event.sh hps-shutdown-storage.sh \
    -C "${nm}/plugins/hps-node" hps-node.sh \
    | gzip -n
}

# node_bootstrap_script [base]: the bootstrap script, on stdout.
node_bootstrap_script() {
  local base
  base="$(_node_tree_base "${1:-}")" || return 1
  if [[ ! -r "${base}/node-manager/bundle/bootstrap.sh" ]]; then
    hps_log error "node_bootstrap_script: ${base}/node-manager/bundle/bootstrap.sh is missing"
    return 1
  fi
  cat "${base}/node-manager/bundle/bootstrap.sh"
}

# node_role_packages <os_id> <type> [base] [resources]
# The store paths of the packages a node of this OS and role gets, one per line.
# <type> is the registry TYPE (a comma list such as SCH,TCH). The names come
# from lib/starter/<os>.roles (plain data: ROLE: name name; the role * is every
# node), each resolved to a store path through the repository's own manifest
# (packages/<os>/<version>/manifest.json, "roots"), so the answer is exactly
# what the repository holds. A name the repository does not hold is an error
# naming it, never a silent omission.
node_role_packages() {
  local os_id="${1:-}" type="${2:-}" base res os ver roles manifest
  [[ "$os_id" =~ ^[^:]+:([a-z]+):([0-9][0-9A-Za-z.-]*)$ ]] || {
    hps_log error "node_role_packages: os_id '${os_id}' is not arch:os:version"
    return 1
  }
  os="${BASH_REMATCH[1]}"
  ver="${BASH_REMATCH[2]}"
  base="$(_node_tree_base "${3:-}")" || return 1
  res="${4:-}"
  [[ -n "$res" ]] || res="$(hps_get_config resources)" || return 1
  roles="${base}/lib/starter/${os}.roles"
  manifest="${res}/packages/${os}/${ver}/manifest.json"
  if [[ ! -r "$roles" ]]; then
    hps_log error "node_role_packages: no role list ${roles}"
    return 1
  fi
  if [[ ! -r "$manifest" ]]; then
    hps_log error "node_role_packages: no package repository for ${os} ${ver} (${manifest}): run hps-starter sync ${os}"
    return 1
  fi
  local names name path missing=""
  names="$(awk -v types=",${type}," '
    { sub(/#.*/, ""); }
    /^[A-Za-z*][A-Za-z0-9_]*:/ {
      role = $1; sub(/:$/, "", role)
      if (role == "*" || index(types, "," role ",") > 0) for (i = 2; i <= NF; i++) print $i
    }' "$roles" | awk '!seen[$0]++')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    path="$(jq -r --arg n "$name" '.roots[$n] // empty' "$manifest")" || return 1
    if [[ -z "$path" ]]; then
      missing="${missing:+$missing }${name}"
      continue
    fi
    printf '%s\n' "$path"
  done <<< "$names"
  if [[ -n "$missing" ]]; then
    hps_log error "node_role_packages: the ${os} ${ver} repository does not hold: ${missing} (hps-starter sync ${os}; the package list lib/starter/${os}.packages)"
    return 1
  fi
  return 0
}

# node_sysadmin_keys [config_base]
# The public keys of the installation's sysadmin, from <config>/sysadmin_authorized_keys
# (OpenSSH authorized_keys lines, written by the installer or the operator).
# Only well-formed lines without options are given. Returns 1 when there is
# none; a public key is not a secret.
node_sysadmin_keys() {
  local cfg="${1:-}" f out
  [[ -n "$cfg" ]] || cfg="$(hps_get_config config_base)" || return 1
  f="${cfg}/sysadmin_authorized_keys"
  [[ -r "$f" ]] || return 1
  out="$(grep -E "$NODE_KEY_RE" "$f")" || return 1
  printf '%s\n' "$out"
}
