#!/bin/bash
# Test suite for the hps-node agent plugin. Run: bash test/run.sh
#
# Covers the ce-agent-plugins contract (no-args and unknown-subcommand exit
# nonzero) and the subcommand dispatch, with the HPS node bundle stubbed so the
# test needs no PXE environment, no ctrl-exec and no network.

set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/hps-node.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hps-node-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ if [ "$2" = "$3" ]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1 (want $2, got $3)"; FAIL=$((FAIL+1)); fi; }

echo "# Test report: hps-node (ce-agent-plugins)"
echo "Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

# A stub bootstrap lib providing hps_load_node_functions and the node functions
# the plugin dispatches to. Each records its call so the test can assert routing.
STUB="$WORK/hps-bootstrap-lib.sh"
cat > "$STUB" <<EOF
hps_load_node_functions() { :; }
n_init_run()             { echo "n_init_run" > "$WORK/called"; }
n_remote_host_variable() { echo "n_remote_host_variable \$*" > "$WORK/called"; }
n_opensvc_join()         { echo "n_opensvc_join \$*" > "$WORK/called"; }
n_vm_create()            { echo "n_vm_create \$*" > "$WORK/called"; }
EOF
export HPS_BOOTSTRAP_LIB="$STUB"

run() { "$SCRIPT" "$@" </dev/null >/dev/null 2>&1; echo $?; }

# --- contract: no args / unknown subcommand exit nonzero -------------------
r=$(run); [ "$r" -ne 0 ] && v=nonzero || v=zero
ok "no subcommand -> nonzero exit (usage)" nonzero "$v"
r=$(run __no_such__); [ "$r" -ne 0 ] && v=nonzero || v=zero
ok "unknown subcommand -> nonzero exit (usage)" nonzero "$v"
r=$(run help); ok "help -> zero exit" 0 "$r"

# --- missing bundle -> config error (exit 2) -------------------------------
HPS_BOOTSTRAP_LIB="$WORK/nonexistent" "$SCRIPT" ping </dev/null >/dev/null 2>&1
ok "missing bundle -> exit 2" 2 "$?"

# --- ping loads the bundle -------------------------------------------------
r=$(run ping); ok "ping -> zero exit" 0 "$r"

# --- dispatch routes to the right node function ----------------------------
rm -f "$WORK/called"; run run-init >/dev/null
ok "run-init dispatches n_init_run" "n_init_run" "$(cat "$WORK/called" 2>/dev/null)"

rm -f "$WORK/called"; run set-status INSTALLED >/dev/null
ok "set-status dispatches n_remote_host_variable" "n_remote_host_variable set STATE INSTALLED" "$(cat "$WORK/called" 2>/dev/null)"

rm -f "$WORK/called"; run opensvc-join tok123 >/dev/null
ok "opensvc-join dispatches n_opensvc_join" "n_opensvc_join tok123" "$(cat "$WORK/called" 2>/dev/null)"

rm -f "$WORK/called"; run vm-create vm1 spec1 >/dev/null
ok "vm-create dispatches n_vm_create" "n_vm_create vm1 spec1" "$(cat "$WORK/called" 2>/dev/null)"

# --- argument validation ---------------------------------------------------
r=$(run set-status); ok "set-status without state -> exit 2" 2 "$r"
r=$(run opensvc-join); ok "opensvc-join without token -> exit 2" 2 "$r"
r=$(run vm-create vm1); ok "vm-create without spec -> exit 2" 2 "$r"

echo
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "VERDICT: PASS"; else echo "VERDICT: FAIL"; fi
[ "$FAIL" -eq 0 ]
