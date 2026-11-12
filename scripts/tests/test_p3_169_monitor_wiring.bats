#!/usr/bin/env bats
#
# Resource monitor wiring: flake input, node module, allowlist entry, checks.conf
# text, the check_zpool plugin, the supervisor program and the log-routing.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  MOD="$ROOT/nix/modules/hps-monitor.nix"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-169.XXXXXX")"
  export TEST_DIR
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "the flake pins ctrl-exec-plugins to a release tag as a non-flake input and passes it to the modules" {
  grep -qE 'url = "github:OpenDigitalCC/ctrl-exec-plugins/v[0-9]+\.[0-9]+\.[0-9]+";' "$ROOT/flake.nix"
  grep -q 'outputs = { self, nixpkgs, ctrl-exec, om3-src, ctrl-exec-plugins }' "$ROOT/flake.nix"
  grep -q 'specialArgs = { inherit ctrl-exec ctrl-exec-plugins;' "$ROOT/flake.nix"
  run awk '/ctrl-exec-plugins = \{/ {f=1} f && /flake = false;/ {print "ok"; exit}' "$ROOT/flake.nix"
  [ "$output" = ok ]
}

@test "build.sh can override the ctrl-exec-plugins input like ctrl-exec" {
  grep -q -- '--override-input ctrl-exec-plugins "$CTRL_EXEC_PLUGINS_FLAKE"' "$ROOT/nix/build.sh"
}

@test "the node image imports the monitor module and the audit image does not" {
  grep -q './hps-monitor.nix' "$ROOT/nix/modules/hps-node.nix"
  run ! grep -q 'hps-monitor' "$ROOT/nix/modules/hps-audit.nix"
  run ! grep -q 'hps-monitor' "$ROOT/nix/modules/hps-ctrl-exec.nix"
  grep -q '../hps-node.nix' "$ROOT/nix/modules/profiles/converged.nix"
}

@test "nagios-check is allowlisted under profile node, read-only, with no input option" {
  grep -q 'services.ctrl-exec-agent.scripts.nagios-check = {' "$MOD"
  grep -q 'source = nagiosCheck;' "$MOD"
  grep -q 'options.profile = "node";' "$MOD"
  run ! grep -q 'options.input' "$MOD"
  run ! grep -q 'input = "raw"' "$MOD"
}

@test "the script comes from the pinned input with its shebang patched, and is a derivation output" {
  grep -q '${ctrl-exec-plugins}/ce-agent-plugins/nagios-check' "$MOD"
  grep -q 'nagios-check.pl' "$MOD"
  grep -q 'patchShebangs "$out"' "$MOD"
  grep -q 'pkgs.runCommand "nagios-check"' "$MOD"
}

@test "the plugin directory holds monitoring-plugins' checks, check_mem from the input and check_zpool" {
  grep -q '${pkgs.monitoring-plugins}' "$MOD"
  grep -q 'for p in check_disk check_load check_procs; do' "$MOD"
  grep -q '${pluginSrc}/plugins/check_mem' "$MOD"
  grep -q 'node-manager/nixos-26/plugins/check_zpool' "$MOD"
}

@test "checks.conf is /etc/nagios-checks/checks.conf, mode 0644, plugin_dir the store directory" {
  grep -q 'environment.etc."nagios-checks/checks.conf"' "$MOD"
  grep -q 'mode = "0644";' "$MOD"
  grep -qF '"plugin_dir = ${plugins}"' "$MOD"
}

@test "the check set: root, load, mem, procs, swap everywhere; disk and zpool on storage nodes; osvc_hb where om3 runs; thresholds as the plugin example" {
  grep -qF '"disk_root = check_disk -w 20% -c 10% -p /"' "$MOD"
  grep -qF '"load = check_load -r -w 1.5,1.2,1 -c 3,2.5,2"' "$MOD"
  grep -qF '"mem = check_mem -w 10 -c 5"' "$MOD"
  grep -qF '"procs = check_procs -k -w 1000 -c 2000"' "$MOD"
  grep -qF '"swap = check_swap_use -w 50 -c 80"' "$MOD"
  grep -qF '(usagePlugin "check_swap_use" "")' "$MOD"
  run ! grep -q 'hasSwap' "$MOD"
  grep -qF 'lib.optional hasOsvc "osvc_hb = check_osvc_hb"' "$MOD"
  grep -qF 'hasOsvc = config.hps.monitor.osvc;' "$MOD"
  grep -qF "lib.optional hasOsvc (usagePlugin \"check_osvc_hb\"" "$MOD"
  grep -qF "'HPS_OM:-\${pkgs.om3}/bin/om}'" "$MOD"
  grep -qF 'options.hps.monitor.osvc = lib.mkOption {' "$MOD"
  grep -qx '  hps.monitor.osvc = true;' "$ROOT/nix/modules/hps-opensvc.nix"
  grep -qF 'pkgs.jq' "$MOD"
  run ! grep -q '"disk = check_disk' "$MOD"
  grep -qF '"zpool = check_zpool"' "$MOD"
  grep -qF 'isStorage = lib.hasInfix "SCH" config.hps.roles;' "$MOD"
}

@test "the plugin names in checks.conf match the nagios-check name rule" {
  run bash -c "grep -oE '^    \"[a-z_]+ = ' '$MOD' | tr -d ' \"=' | grep -vE '^[A-Za-z0-9_-]+\$' || true"
  [ -z "$output" ]
}

@test "check_zpool is shellcheck clean and takes no arguments" {
  run shellcheck -s bash -S warning "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 0 ]
  run "$ROOT/node-manager/nixos-26/plugins/check_zpool" x
  [ "$status" -eq 3 ]
}

zpool_stub() {
  mkdir -p "$TEST_DIR/bin"
  printf '#!/bin/sh\n%s\n' "$1" > "$TEST_DIR/bin/zpool"
  chmod +x "$TEST_DIR/bin/zpool"
}

@test "check_zpool: all ONLINE is OK with a capacity perfdata per pool" {
  zpool_stub "printf 'tank\tONLINE\t12%%\nfast\tONLINE\t3%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL OK - 2 pools: tank=ONLINE fast=ONLINE | tank_cap=12%;80;90;0;100 fast_cap=3%;80;90;0;100" ]
}

@test "check_zpool: DEGRADED is WARNING, FAULTED is CRITICAL and wins" {
  zpool_stub "printf 'tank\tDEGRADED\t12%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 1 ]
  [[ "$output" == "ZPOOL WARNING - 1 pools: tank=DEGRADED |"* ]]
  zpool_stub "printf 'tank\tDEGRADED\t12%%\nbad\tFAULTED\t0%%\nok\tONLINE\t1%%\n'"
  PATH="$TEST_DIR/bin:$PATH" run "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 2 ]
  [[ "$output" == "ZPOOL CRITICAL - 3 pools:"* ]]
}

@test "check_zpool: no pool is OK, a failing zpool is UNKNOWN" {
  zpool_stub "exit 0"
  PATH="$TEST_DIR/bin:$PATH" run "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 0 ]
  [ "$output" = "ZPOOL OK - no pools imported" ]
  zpool_stub "echo 'no such device /dev/zfs' >&2; exit 1"
  PATH="$TEST_DIR/bin:$PATH" run "$ROOT/node-manager/nixos-26/plugins/check_zpool"
  [ "$status" -eq 3 ]
  [[ "$output" == "ZPOOL UNKNOWN - zpool list failed:"* ]]
}

@test "supervisor runs hps-monitor loop as root, logging to syslog" {
  local f="$ROOT/lib/functions.d/configure-supervisor.sh"
  run awk '/^\[program:hps-monitor\]/ {f=1} f {print} f && /^environment=/ {exit}' "$f"
  [[ "$output" == *"command=\${HPS_SYSTEM_BASE}/bin/hps-monitor loop"* ]]
  [[ "$output" == *"user=root"* ]]
  [[ "$output" == *"autorestart=true"* ]]
  [[ "$output" == *"stdout_logfile=syslog"* ]]
  [[ "$output" == *"stderr_logfile=syslog"* ]]
}

@test "rsyslog files the hps-monitor program like the other IPS services" {
  grep -q '"hps-jobs", "hps-monitor", ' "$ROOT/lib/functions.d/create-config-rsyslog.sh"
}

@test "bin/hps-monitor is executable and passes perl -c" {
  [ -x "$ROOT/bin/hps-monitor" ]
  run perl -I "$ROOT/lib/perl" -c "$ROOT/bin/hps-monitor"
  [ "$status" -eq 0 ]
}

@test "the monitoring doc names the key, the log format and the script" {
  grep -q 'monitor_interval_seconds' "$ROOT/docs/MONITORING.md"
  grep -q 'hps-monitor: host=' "$ROOT/docs/MONITORING.md"
  grep -q 'nagios-check' "$ROOT/docs/MONITORING.md"
}
