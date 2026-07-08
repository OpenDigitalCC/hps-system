#!/bin/bash
#
# hps-node - ctrl-exec agent plugin: the single allowlisted entry point through
# which the IPS drives node-manager operations over mTLS.
#
# Installed on every provisioned node as /usr/local/sbin/hps-node and listed in
# /etc/ctrl-exec-agent/scripts.conf as:
#
#     hps-node = /usr/local/sbin/hps-node
#
# ctrl-exec execs this script with no shell, arguments as a list, and the JSON
# request context on stdin. It follows the ce-agent-plugins subcommand pattern:
# the first argument selects the operation; no-args or an unknown subcommand
# prints usage to stderr and exits 2.
#
# The subcommand map below is the authorisation surface. Because the privileged
# C executor is deferred (ADR 0003), this curated allowlist - not a generic
# "run any function" bridge - is what bounds what the IPS can invoke on a node.
# Add a case here to expose a new node operation; never route an arbitrary
# caller-supplied function name.
#
# Usage (via ctrl-exec):
#   ced run <host> hps-node -- <subcommand> [args...]

set -euo pipefail

# The HPS node function bundle is fetched and installed during PXE bootstrap.
: "${HPS_BOOTSTRAP_LIB:=/usr/local/lib/hps-bootstrap-lib.sh}"

usage() {
    cat >&2 <<'EOF'
hps-node - HPS node operations over ctrl-exec

Usage: hps-node <subcommand> [args...]

Subcommands:
  ping                    Confirm the agent can load the HPS function bundle
  run-init                Run this node's HPS_INIT_SEQUENCE
  set-status <state>      Report a lifecycle STATE back to the IPS
  opensvc-join <token>    Join the OpenSVC cluster with an IPS-minted token
  vm-create <name> <spec> Create a KVM VM on this node (TCH KVM profile)

Exit codes: 0 success, 1 operation error, 2 usage/config error.
EOF
}

# Load the HPS node function bundle into this shell. The bundle carries every
# n_* node function plus the HPS_INIT_SEQUENCE for this node's role.
load_bundle() {
    if [[ ! -r "$HPS_BOOTSTRAP_LIB" ]]; then
        echo "hps-node: bundle not found: $HPS_BOOTSTRAP_LIB" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$HPS_BOOTSTRAP_LIB"
    if ! type hps_load_node_functions >/dev/null 2>&1; then
        echo "hps-node: bootstrap lib did not provide hps_load_node_functions" >&2
        return 2
    fi
    hps_load_node_functions
}

# Require a named function to be present after loading the bundle.
require_fn() {
    local fn="$1"
    if ! type "$fn" >/dev/null 2>&1; then
        echo "hps-node: node function unavailable: $fn" >&2
        return 1
    fi
}

main() {
    # Discard the ctrl-exec JSON context: subcommand and args carry everything
    # this entry point needs, and no operation consumes stdin.
    exec 0</dev/null

    local subcommand="${1:-}"
    [[ -n "$subcommand" ]] || { usage; exit 2; }
    shift

    case "$subcommand" in
        ping)
            load_bundle || exit $?
            echo "hps-node: bundle loaded on $(hostname)"
            ;;
        run-init)
            load_bundle || exit $?
            require_fn n_init_run || exit 1
            n_init_run
            ;;
        set-status)
            local state="${1:-}"
            [[ -n "$state" ]] || { echo "hps-node: set-status needs <state>" >&2; exit 2; }
            load_bundle || exit $?
            require_fn n_remote_host_variable || exit 1
            n_remote_host_variable set STATE "$state"
            ;;
        opensvc-join)
            local token="${1:-}"
            [[ -n "$token" ]] || { echo "hps-node: opensvc-join needs <token>" >&2; exit 2; }
            load_bundle || exit $?
            require_fn n_opensvc_join || exit 1
            n_opensvc_join "$token"
            ;;
        vm-create)
            local name="${1:-}" spec="${2:-}"
            [[ -n "$name" && -n "$spec" ]] || { echo "hps-node: vm-create needs <name> <spec>" >&2; exit 2; }
            load_bundle || exit $?
            require_fn n_vm_create || exit 1
            n_vm_create "$name" "$spec"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            echo "hps-node: unknown subcommand: $subcommand" >&2
            usage
            exit 2
            ;;
    esac
}

main "$@"
