#!/usr/bin/env bats
#
# Wiring of the issue register (docs/ISSUES.md): hps-issues is an ips-admin tool
# open in the gate for list, show, open, resolve and note, named by hps-op and
# OPERATOR.md; hps-issue-watch is a supervised program filed by rsyslog under
# ips/hps-issue-watch/. The register, the watcher and the healer themselves are
# t/222-issues.t, t/223-issue-watch.t and t/224-issue-heal.t.

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-222.XXXXXX")"
  mkdir -p "$TEST_DIR/sys/bin" "$TEST_DIR/bin"
  printf 'HPS_SYSTEM_BASE=%s\n' "$TEST_DIR/sys" > "$TEST_DIR/hps.conf"
  printf '#!/bin/bash\necho "tool=${0##*/} args=$*"\n' > "$TEST_DIR/sys/bin/hps-issues"
  printf '#!/bin/bash\nexit 0\n' > "$TEST_DIR/bin/logger"
  chmod +x "$TEST_DIR/sys/bin/hps-issues" "$TEST_DIR/bin/logger"
}

teardown() {
  rm -rf "$TEST_DIR"
}

gate() {
  HPS_BASE="$TEST_DIR" PATH="$TEST_DIR/bin:$PATH" run "$ROOT/ips-admin/hps-issues" "$@"
}

@test "hps-issues is an ips-admin tool: allowlisted, a wrapper, named by hps-op and OPERATOR.md" {
  source "$ROOT/lib/functions.d/ips-admin-functions.sh"
  [[ " ${IPS_ADMIN_SCRIPTS[*]} " == *" hps-issues "* ]]
  [[ " ${IPS_ADMIN_RAW_SCRIPTS[*]} " != *" hps-issues "* ]]
  [ -x "$ROOT/ips-admin/hps-issues" ]
  grep -qxF 'exec "${0%/*}/ips-admin-exec" hps-issues "$@"' "$ROOT/ips-admin/hps-issues"
  grep -q 'hps-issues' "$ROOT/bin/hps-op"
  grep -q '^| `hps-issues` | `bin/hps-issues` | `list`, `show`, `open`, `resolve`, `note`, `retry`' "$ROOT/docs/OPERATOR.md"
  [ -x "$ROOT/bin/hps-issues" ]
  [ -x "$ROOT/bin/hps-issue-watch" ]
}

@test "the ips-admin gate: the six hps-issues verbs pass with their options and words" {
  gate list --all --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-issues args=list --all --json"* ]]
  gate show 20261112-001 --json
  [ "$status" -eq 0 ]
  gate open --kind mirror-leg --key-field host=tch-002 --key-field mirror=probe-tch-002-root --summary leg lost
  [ "$status" -eq 0 ]
  [[ "$output" == *"args=open --kind mirror-leg --key-field host=tch-002 --key-field mirror=probe-tch-002-root --summary leg lost"* ]]
  gate open --kind mirror-leg --key-field leg=iqn.2026-01.lab.nas:x@192.0.2.50:3260
  [ "$status" -eq 0 ]
  gate resolve 20261112-001 --by replaced the cable
  [ "$status" -eq 0 ]
  gate note 20261112-001 looking at it
  [ "$status" -eq 0 ]
  gate retry 20261112-001
  [ "$status" -eq 0 ]
  [[ "$output" == *"tool=hps-issues args=retry 20261112-001"* ]]
}

@test "the ips-admin gate: any other hps-issues verb, a space or a path is refused" {
  gate
  [ "$status" -eq 2 ]
  gate watch
  [ "$status" -eq 2 ]
  [[ "$output" == *"only list, show, open, resolve, note and retry"* ]]
  gate --json list
  [ "$status" -eq 2 ]
  gate show ../../etc/passwd
  [ "$status" -eq 2 ]
  gate note 20261112-001 'two words'
  [ "$status" -eq 2 ]
  [[ "$output" != *"tool="* ]]
}

@test "supervisor runs hps-issue-watch loop as root, logging to syslog" {
  local f="$ROOT/lib/functions.d/configure-supervisor.sh"
  run awk '/^\[program:hps-issue-watch\]/ {f=1} f {print} f && /^environment=/ {exit}' "$f"
  [[ "$output" == *"command=\${HPS_SYSTEM_BASE}/bin/hps-issue-watch loop"* ]]
  [[ "$output" == *"user=root"* ]]
  [[ "$output" == *"autorestart=true"* ]]
  [[ "$output" == *"stdout_logfile=syslog"* ]]
  [[ "$output" == *"stderr_logfile=syslog"* ]]
}

@test "rsyslog files the hps-issue-watch program like the other IPS services" {
  grep -q '"hps-monitor", "hps-issue-watch", "ctrl-exec-api"' "$ROOT/lib/functions.d/create-config-rsyslog.sh"
}

@test "the shipped rules parse, and the tools pass perl -c" {
  run perl -I "$ROOT/lib/perl" "$ROOT/bin/hps-issue-watch" check-rules "$ROOT/lib/hps-issue-rules.conf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 marker rule(s), 8 line rule(s)"* ]]
  run perl -I "$ROOT/lib/perl" -c "$ROOT/bin/hps-issues"
  [ "$status" -eq 0 ]
  run perl -I "$ROOT/lib/perl" -c "$ROOT/bin/hps-issue-watch"
  [ "$status" -eq 0 ]
}

@test "the issues doc names the marker, the rules file, the register path and the program" {
  grep -q 'HPS-ISSUE open kind=mirror-leg' "$ROOT/docs/ISSUES.md"
  grep -q 'lib/hps-issue-rules.conf' "$ROOT/docs/ISSUES.md"
  grep -q 'clusters/<cluster>/issues/<id>.json' "$ROOT/docs/ISSUES.md"
  grep -q 'program:hps-issue-watch' "$ROOT/docs/ISSUES.md"
}
