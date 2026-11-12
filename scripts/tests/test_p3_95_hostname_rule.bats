#!/usr/bin/env bats
#
# IPS-06: one hostname rule (docs/NAMING.md). Every identity is the FQDN
# <label>.<cluster dns domain>: kernel hostname, om3 node names, ctrl-exec
# agent names, iSCSI initiator name. Helpers, producers and comparers, the
# 63-character cap, the LIO IQN rule, and the Nix wiring (no nix on this host:
# source greps).

bats_require_minimum_version 1.5.0

LIO_RE='^iqn\.[0-9]{4}-[0-1][0-9]\..*\..*'

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-95.XXXXXX")"
  export T
  BOOT="$ROOT/node-manager/nixos-26/boot"
  mkdir -p "$T/bin"
  export SHIM_LOG="$T/shim.log"
  : > "$SHIM_LOG"
  export HPS_CMDLINE="$T/cmdline"
  export HPS_RUN_DIR="$T/run"
  export HPS_AGENT_ETC="$T/etc"
  mkdir -p "$HPS_AGENT_ETC"
}

teardown() {
  rm -rf "$T"
}

# ---- helpers ------------------------------------------------------------------

@test "n_fqdn and n_shortname: lower-case label.domain, the one join" {
  source "$ROOT/node-manager/base/n_configure-hostname.sh"
  run -0 n_fqdn SCH-001.old.example Lab.HPS
  [ "$output" = "sch-001.lab.hps" ]
  run -0 n_fqdn sch-001 ""
  [ "$output" = "sch-001" ]
  run -0 n_shortname Sch-001.lab.hps
  [ "$output" = "sch-001" ]
}

@test "n_fqdn refuses an FQDN over 63 characters and a bad domain" {
  source "$ROOT/node-manager/base/n_configure-hostname.sh"
  run -1 n_fqdn sch-001 "$(printf 'd%.0s' {1..60})"
  [[ "$output" == *"limit is 63"* ]]
  run -0 n_fqdn sch-001 "$(printf 'd%.0s' {1..55})"
  run -1 n_fqdn sch-001 "bad domain"
}

@test "fqdn_join, cluster_dns_domain and host_fqdn on the IPS" {
  source "$ROOT/lib/functions.d/host-functions.sh"
  hps_get_config() { echo lab; }
  cluster_registry() { echo '"Lab.HPS"'; }
  host_registry() { [[ "$2" == get && "$3" == HOSTNAME ]] && echo "TCH-002"; return 0; }
  run -0 fqdn_join Tch-001.x lab.hps
  [ "$output" = "tch-001.lab.hps" ]
  run -0 cluster_dns_domain
  [ "$output" = "lab.hps" ]
  run -0 host_fqdn aabbccddeeff
  [ "$output" = "tch-002.lab.hps" ]
  run -1 fqdn_join tch-001 "$(printf 'd%.0s' {1..60})"
  run -1 fqdn_join 'bad_label' lab.hps
  cluster_registry() { echo "$(printf 'd%.0s' {1..60})"; }
  run -1 host_fqdn aabbccddeeff
}

# ---- node side ------------------------------------------------------------------

node_shims() {
  local s
  for s in hostnamectl hostname systemctl getent; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$SHIM_LOG"\nexit "${FAKE_%s_RC:-0}"\n' "$s" "${s^^}" > "$T/bin/$s"
    chmod +x "$T/bin/$s"
  done
  # the API answers 200 (approved) as an HTTP code (curl -w)
  printf '#!/usr/bin/env bash\ncase "$*" in *host_variable*) printf "%%s" "${FAKE_HOSTNAME:-node01}" ;; *api.sh*) printf 200 ;; esac\n' > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  printf '#!/usr/bin/env bash\necho abc123\necho cert > "$HPS_AGENT_ETC/agent.crt"\n' > "$T/bin/ctrl-exec-agent"
  chmod +x "$T/bin/ctrl-exec-agent"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/pair"
  chmod +x "$T/pair"
  export HPS_PAIR="$T/pair" HPS_PAIR_TIMEOUT=5 HPS_PAIR_POLL=1
  export PATH="$T/bin:$PATH"
}

@test "hps-node-init sets the FQDN as the transient name only (IPS-11: /etc is read-only on a node)" {
  node_shims
  echo "hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:ff hps.domain=lab.hps" > "$HPS_CMDLINE"
  run -0 timeout 30 bash "$BOOT/hps-node-init.sh"
  grep -qx 'hostnamectl set-hostname --transient node01.lab.hps' "$SHIM_LOG"
  [ "$(grep -c '^hostnamectl' "$SHIM_LOG")" -eq 1 ]
}

@test "hps-node-init falls back to hostname(1) when the transient name cannot be set" {
  node_shims
  printf '#!/usr/bin/env bash\nprintf "hostnamectl %%s\\n" "$*" >> "$SHIM_LOG"\nexit 1\n' > "$T/bin/hostnamectl"
  echo "hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:ff hps.domain=lab.hps" > "$HPS_CMDLINE"
  run -0 timeout 30 bash "$BOOT/hps-node-init.sh"
  grep -qx 'hostnamectl set-hostname --transient node01.lab.hps' "$SHIM_LOG"
  grep -qx 'hostname node01.lab.hps' "$SHIM_LOG"
}

@test "hps-node-init and hps-pair refuse a domain that makes the FQDN exceed 63 characters" {
  node_shims
  echo "hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:ff hps.domain=$(printf 'd%.0s' {1..60})" > "$HPS_CMDLINE"
  run -1 timeout 30 bash "$BOOT/hps-node-init.sh"
  [[ "$output" == *"limit is 63"* ]]
  ! grep -q '^hostnamectl' "$SHIM_LOG"
  run -1 timeout 30 bash "$BOOT/hps-pair.sh"
  [[ "$output" == *"limit is 63"* ]]
  ! grep -q '^hostnamectl' "$SHIM_LOG"
}

@test "hps-pair --no-hostname registers the agent under the kernel hostname (the FQDN)" {
  node_shims
  printf '#!/usr/bin/env bash\nprintf "hostname\\n" >> "$SHIM_LOG"\necho Node01.Lab.HPS\n' > "$T/bin/hostname"
  printf '#!/usr/bin/env bash\necho "agent $*" >> "$SHIM_LOG"\ncase "$*" in *--help*) echo "usage: --name" ;; *) echo abc123; echo cert > "$HPS_AGENT_ETC/agent.crt" ;; esac\n' > "$T/bin/ctrl-exec-agent"
  echo "hps.ips=10.0.0.1 hps.mac=aa:bb:cc:dd:ee:ff hps.domain=lab.hps" > "$HPS_CMDLINE"
  run -0 timeout 30 bash "$BOOT/hps-pair.sh" --no-hostname
  grep -q 'agent request-pairing --background .* --name node01.lab.hps' "$SHIM_LOG"
}

@test "the bundle's hostname step sets the FQDN (the lab cause of the short kernel name)" {
  source "$ROOT/node-manager/base/n_configure-hostname.sh"
  n_os_is_nixos() { return 0; }
  n_nixos_skip() { :; }
  n_remote_log() { :; }
  n_remote_host_variable() { [[ "$1" == HOSTNAME ]] && echo node-01 || echo 10.0.0.50; }
  n_remote_cluster_variable() { echo '"lab.hps"'; }
  node_shims
  run -0 n_set_hostname_and_hosts
  grep -qxE 'hostnamectl set-hostname (--transient )?node-01.lab.hps' "$SHIM_LOG"
  ! grep -q 'hostnamectl set-hostname node-01$' "$SHIM_LOG"
}

# ---- om3 names ---------------------------------------------------------------------

@test "hps-osvc-config matches the FQDN exactly and writes the FQDNs as listed" {
  export OSVC_ETC="$T/osvc" HPS_HOSTNAME=sch-001.lab.hps
  mkdir -p "$HPS_RUN_DIR"
  echo "hps.ips=192.0.2.1" > "$HPS_CMDLINE"
  printf '%s\n' "$(printf 'ab%.0s' {1..16})" > "$HPS_RUN_DIR/osvc-cluster-secret"
  printf '#!/usr/bin/env bash\ncase "${*: -1}" in *cmd=cluster_nodes*) printf "cluster lab\\nnode sch-001.lab.hps 192.0.2.11\\nnode tch-002.lab.hps 192.0.2.12\\n" ;; *) exit 22 ;; esac\n' > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  PATH="$T/bin:$PATH" run -0 bash "$BOOT/hps-osvc-config.sh"
  grep -qx 'nodes = sch-001.lab.hps tch-002.lab.hps' "$OSVC_ETC/cluster.conf"
  HPS_HOSTNAME=sch-001 PATH="$T/bin:$PATH" run -3 bash "$BOOT/hps-osvc-config.sh"
  ! grep -q 'first label' "$BOOT/hps-osvc-config.sh" || grep -q 'No first-label match' "$BOOT/hps-osvc-config.sh"
}

# ---- iSCSI names ----------------------------------------------------------------------

@test "the initiator name matches the LIO rule, for a short label and for an FQDN" {
  local h
  for h in sch-001 sch-001.lab.hps; do
    HPS_HOSTNAME=$h HPS_CLUSTER=lab run -0 bash "$BOOT/hps-iscsi-name.sh"
    line=$(cat "$HPS_RUN_DIR/initiatorname.iscsi")
    name=${line#InitiatorName=}
    [[ "$name" =~ $LIO_RE ]] || { echo "LIO would refuse $name"; return 1; }
    [ "$name" = "iqn.2026-11.hps.lab:$h" ]
  done
}

@test "the initiator name carries the cluster from the IPS when HPS_CLUSTER is not given" {
  echo "hps.ips=10.0.0.1" > "$HPS_CMDLINE"
  printf '#!/usr/bin/env bash\ncase "${*: -1}" in *CLUSTER_NAME*) printf "Lab" ;; esac\n' > "$T/bin/curl"
  chmod +x "$T/bin/curl"
  HPS_HOSTNAME=sch-001.lab.hps PATH="$T/bin:$PATH" run -0 bash "$BOOT/hps-iscsi-name.sh"
  grep -qx 'InitiatorName=iqn.2026-11.hps.lab:sch-001.lab.hps' "$HPS_RUN_DIR/initiatorname.iscsi"
}

@test "an unusable cluster name is refused and nothing is written" {
  HPS_HOSTNAME=sch-001 HPS_CLUSTER='bad_name' run -1 bash "$BOOT/hps-iscsi-name.sh"
  HPS_HOSTNAME=sch-001 HPS_CLUSTER='' run -1 bash "$BOOT/hps-iscsi-name.sh"
  [ ! -e "$HPS_RUN_DIR/initiatorname.iscsi" ]
}

@test "the target IQN form iqn.2026-11.hps.<cluster>:<host>:<name> matches the LIO rule; the old initiator form does not" {
  [[ "iqn.2026-11.hps.lab:sch-001:t0-root" =~ $LIO_RE ]]
  [[ "iqn.2026-11.hps.lab:sch-001.lab.hps" =~ $LIO_RE ]]
  ! [[ "iqn.2026-11.hps:tch-005" =~ $LIO_RE ]]
}

@test "iscsi-export refuses a target or initiator LIO would refuse (exit 3) before touching anything" {
  local good=iqn.2026-11.hps.lab:sch-001.lab.hps tgt=iqn.2026-11.hps.lab:sch-001:t0
  run -3 bash "$ROOT/node-manager/nixos-26/scripts/iscsi-export" lab/enc/t0 --iqn "$tgt" --initiator iqn.2026-11.hps:tch-005 --portal 10.0.0.1
  [[ "$output" == *"initiator"*"refused by LIO"* ]]
  run -3 bash "$ROOT/node-manager/nixos-26/scripts/iscsi-export" lab/enc/t0 --iqn iqn.2026-11.example:t0 --initiator "$good" --portal 10.0.0.1
  [[ "$output" == *"target"*"refused by LIO"* ]]
}

@test "HPS::Storage refuses --initiator and --iqn that LIO would refuse (refused, exit 3 at the CLI)" {
  grep -q 'LIO_IQN_RE' "$ROOT/lib/perl/HPS/Storage.pm"
  grep -q "_fail('refused', \"--initiator" "$ROOT/lib/perl/HPS/Storage.pm"
}

# ---- IPS: ctrl-exec agents and forgetting ----------------------------------------------

ce_stubs() {
  export CTRL_EXEC_DISPATCHER="$T/ced"
  cat > "$CTRL_EXEC_DISPATCHER" <<'EOT'
#!/usr/bin/env bash
echo "$*" >> "$CED_LOG"
case "$1" in
  list-agents) printf '[{"hostname":"a.lab.hps"},{"hostname":"stale-x"}]\n' ;;
  unpair) [[ "$2" == gone ]] && { echo "No registry entry for 'gone'" >&2; exit 1; }; echo "Unregistered '$2'." ;;
esac
EOT
  chmod +x "$CTRL_EXEC_DISPATCHER"
  export CED_LOG="$T/ced.log"
  hps_log() { :; }
  id() { if [[ "${1:-}" == -u ]]; then echo 0; else command id "$@"; fi; }
  source "$ROOT/lib/functions.d/ctrl-exec-functions.sh"
}

@test "ce_agent_names lists the registered agents; ce_unpair_agent removes one, reports an absent one (4)" {
  ce_stubs
  run -0 ce_agent_names
  [ "${lines[0]}" = "a.lab.hps" ]
  [ "${lines[1]}" = "stale-x" ]
  run -0 ce_unpair_agent a.lab.hps
  grep -qx 'unpair a.lab.hps' "$CED_LOG"
  run -4 ce_unpair_agent gone
  run -1 ce_unpair_agent '../etc'
  run -1 ce_unpair_agent
}

@test "ce_unpair_agent is for root: another user is refused without calling the dispatcher" {
  ce_stubs
  id() { echo 1000; }
  run -1 ce_unpair_agent a.lab.hps
  [ ! -e "$CED_LOG" ]
}

@test "hps-forget-hook: agents, agent <name>, dns-dhcp call the function layer; bad verbs are usage (2)" {
  mkdir -p "$T/sys/lib"
  cat > "$T/sys/lib/functions.sh" <<EOT
hps_log() { :; }
ce_agent_names() { echo agents-called; }
ce_unpair_agent() { echo "unpair \$1"; return 4; }
update_dns_dhcp_files() { echo dns-dhcp-called; }
EOT
  export HPS_SYSTEM_PATH="$T/sys"
  run -0 bash "$ROOT/scripts/hps-forget-hook.sh" agents
  [ "$output" = "agents-called" ]
  run -4 bash "$ROOT/scripts/hps-forget-hook.sh" agent x.lab.hps
  [ "$output" = "unpair x.lab.hps" ]
  run -0 bash "$ROOT/scripts/hps-forget-hook.sh" dns-dhcp
  [ "$output" = "dns-dhcp-called" ]
  run -2 bash "$ROOT/scripts/hps-forget-hook.sh" bogus
  run -2 bash "$ROOT/scripts/hps-forget-hook.sh"
}

@test "hps-onboard forget and prune-agents are wired to the hook, with no approval" {
  grep -q 'hps-forget-hook.sh' "$ROOT/bin/hps-onboard"
  grep -q "'forget'" "$ROOT/bin/hps-onboard"
  run ! grep -qi 'approv' "$ROOT/bin/hps-onboard" "$ROOT/lib/perl/HPS/Onboard.pm"
  [ -x "$ROOT/scripts/hps-forget-hook.sh" ]
}

# ---- Nix wiring (no nix here: the supervisor runs the flake check) --------------------------

@test "nix wiring: DHCP gives no hostname, hostName stays empty, hps-node-init is the only namer" {
  grep -q 'UseHostname=false' "$BOOT/hps-net.sh"
  grep -q 'networking.hostName = ""' "$ROOT/nix/modules/hps-common.nix"
  grep -q 'hostnamectl set-hostname --transient "\$name" && return 0' "$BOOT/hps-node-init.sh"
  grep -q 'hostnamectl set-hostname --transient "\$name" && return 0' "$BOOT/hps-pair.sh"
}

@test "nix wiring: the initiator-name unit can reach the IPS (curl, jq, ip on its path)" {
  grep -q 'path = with pkgs; \[ bash coreutils hostname curl jq iproute2 \];' "$ROOT/nix/modules/profiles/compute.nix"
}

@test "docs/NAMING.md exists and states the rule" {
  grep -q 'iqn.2026-11.hps.<cluster>:<fqdn>' "$ROOT/docs/NAMING.md"
  grep -q '63' "$ROOT/docs/NAMING.md"
}
