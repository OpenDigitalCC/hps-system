#!/usr/bin/env bats
#
# CS-3.1: boot/hps-iscsi-name.sh (initiator name from the registry hostname)
# and hps-node-init's call of net-bridge-ensure.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-03.XXXXXX")"
  export HPS_RUN_DIR="$T/run/hps"
  NAME="$ROOT/node-manager/nixos-26/boot/hps-iscsi-name.sh"
  export HPS_CLUSTER=lab
}

teardown() {
  rm -rf "$T"
}

@test "the initiator name is iqn.2026-11.hps.<cluster>:<fqdn>, lower case" {
  HPS_HOSTNAME=Node01.lab.example run bash "$NAME"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_RUN_DIR/initiatorname.iscsi")" = "InitiatorName=iqn.2026-11.hps.lab:node01.lab.example" ]
  [ ! -e "$HPS_RUN_DIR/initiatorname.iscsi.tmp" ]
}

@test "a second run rewrites the same line" {
  HPS_HOSTNAME=sch-001 run bash "$NAME"
  HPS_HOSTNAME=sch-001 run bash "$NAME"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$HPS_RUN_DIR/initiatorname.iscsi")" -eq 1 ]
}

@test "no registry hostname yet (empty, localhost, none) writes nothing and fails" {
  local h
  for h in "" localhost "(none)"; do
    HPS_HOSTNAME="$h" run bash "$NAME"
    [ "$status" -ne 0 ] || { echo "accepted '$h'"; return 1; }
    [ ! -e "$HPS_RUN_DIR/initiatorname.iscsi" ]
  done
}

@test "a hostname with characters an IQN cannot carry is refused, not rewritten" {
  HPS_HOSTNAME='node_01' run bash "$NAME"
  [ "$status" -ne 0 ]
  [ ! -e "$HPS_RUN_DIR/initiatorname.iscsi" ]
}

@test "it reads hostname(1) when no override is given" {
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\necho sch-007.lab.example\n' > "$T/bin/hostname"
  chmod +x "$T/bin/hostname"
  PATH="$T/bin:$PATH" run bash "$NAME"
  [ "$status" -eq 0 ]
  grep -qx 'InitiatorName=iqn.2026-11.hps.lab:sch-007.lab.example' "$HPS_RUN_DIR/initiatorname.iscsi"
}

# ---- hps-node-init -----------------------------------------------------------

node_init_env() {
  export TEST_DIR="$T"
  export SHIM_LOG="$T/shim.log"
  export HPS_CMDLINE="$T/cmdline"
  export HPS_AGENT_ETC="$T/etc/ctrl-exec-agent"
  export HPS_PAIR="$T/pair"
  export PATH="$T/bin:$PATH"
  mkdir -p "$T/bin"
  echo "hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff hps.profile=converged" > "$HPS_CMDLINE"
  printf '#!/bin/bash\necho "pair $*" >> "$SHIM_LOG"\n' > "$HPS_PAIR"
  printf '#!/bin/bash\necho "curl $*" >> "$SHIM_LOG"\ncase "$*" in *host_variable*) printf node01;; *get_remote_functions*) echo "n_init_run() { :; }" > "${@: -1}";; esac\nexit 0\n' > "$T/bin/curl"
  printf '#!/bin/bash\necho "hostnamectl $*" >> "$SHIM_LOG"\n' > "$T/bin/hostnamectl"
  printf '#!/bin/bash\necho "ip $*" >> "$SHIM_LOG"\n' > "$T/bin/ip"
  chmod +x "$T"/bin/* "$HPS_PAIR"
}

@test "hps-node-init runs net-bridge-ensure after the hostname and before pairing" {
  node_init_env
  printf '#!/bin/bash\necho "ensure ran" >> "$SHIM_LOG"\n' > "$T/ensure"
  chmod +x "$T/ensure"
  HPS_NET_BRIDGE_ENSURE="$T/ensure" run bash "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  [ "$status" -eq 0 ]
  run grep -nE 'hostnamectl set-hostname|^ensure ran|^pair ' "$SHIM_LOG"
  [[ "${lines[0]}" == *hostnamectl* ]]
  [[ "${lines[1]}" == *"ensure ran"* ]]
  [[ "${lines[2]}" == *pair* ]]
}

@test "hps-node-init goes on to pairing when net-bridge-ensure fails or is absent" {
  node_init_env
  printf '#!/bin/bash\nexit 3\n' > "$T/ensure"
  chmod +x "$T/ensure"
  HPS_NET_BRIDGE_ENSURE="$T/ensure" run bash "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"net-bridge-ensure exited 3"* ]]
  grep -q '^pair ' "$SHIM_LOG"
  : > "$SHIM_LOG"
  HPS_NET_BRIDGE_ENSURE="$T/missing" run bash "$ROOT/node-manager/nixos-26/boot/hps-node-init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not present; no bridges built"* ]]
  grep -q '^pair ' "$SHIM_LOG"
}
