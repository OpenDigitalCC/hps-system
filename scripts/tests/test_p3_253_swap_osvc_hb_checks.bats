#!/usr/bin/env bats
#
# Node checks swap (check_swap_use: /proc/meminfo and two /proc/vmstat samples;
# no swap is OK) and osvc_hb (check_osvc_hb: om daemon status, the reading of
# osvc-status; stale peer WARNING, below quorum CRITICAL, om absent or down
# UNKNOWN). The sleep shim copies the "after" vmstat in place of waiting; om is
# a shim printing a fixture.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/node-manager/nixos-26/plugins"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-253.XXXXXX")"
  export TEST_DIR
  mkdir -p "$TEST_DIR/proc" "$TEST_DIR/bin"
  printf '#!/bin/sh\ncp "%s/vmstat.after" "%s/proc/vmstat"\n' "$TEST_DIR" "$TEST_DIR" > "$TEST_DIR/bin/sleep-shim"
  chmod +x "$TEST_DIR/bin/sleep-shim"
  export HPS_SLEEP="$TEST_DIR/bin/sleep-shim"
  export HPS_PROC="$TEST_DIR/proc"
  export HPS_PAGESIZE=4096
  cat > "$TEST_DIR/bin/om" <<'SH'
#!/usr/bin/env bash
echo "om $*" >> "$TEST_DIR/om.log"
if [[ "${FAKE_OM_RC:-0}" -ne 0 ]]; then echo "dial unix: no such file" >&2; exit "$FAKE_OM_RC"; fi
cat "$TEST_DIR/status.json"
SH
  chmod +x "$TEST_DIR/bin/om"
  export HPS_OM="$TEST_DIR/bin/om"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# swap_fixture <SwapTotal kB> <SwapFree kB> <pswpin before> <after> <pswpout before> <after>
swap_fixture() {
  printf 'MemTotal: 16000000 kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$1" "$2" > "$TEST_DIR/proc/meminfo"
  printf 'nr_free_pages 1\npswpin %s\npswpout %s\n' "$3" "$5" > "$TEST_DIR/proc/vmstat"
  printf 'nr_free_pages 1\npswpin %s\npswpout %s\n' "$4" "$6" > "$TEST_DIR/vmstat.after"
}

@test "both plugins are shellcheck clean, have the PATH marker, and refuse bad usage (UNKNOWN)" {
  for f in check_swap_use check_osvc_hb; do
    shellcheck -s bash -S warning "$P/$f"
    grep -qx '# @HPS_PATH@' "$P/$f"
  done
  run "$P/check_swap_use" -i 9
  [ "$status" -eq 3 ]
  run "$P/check_swap_use" -w 90 -c 80
  [ "$status" -eq 3 ]
  run "$P/check_osvc_hb" extra
  [ "$status" -eq 3 ]
}

@test "swap: no swap configured is OK with swap_total=0 (never UNKNOWN or WARNING)" {
  swap_fixture 0 0 0 0 0 0
  run "$P/check_swap_use"
  [ "$status" -eq 0 ]
  [[ "$output" == "SWAP OK - no swap configured | used_pct=0%;50;80;0;100 swap_total=0B swap_used=0B swap_free=0B swap_in_Bps=0 swap_out_Bps=0" ]]
}

@test "swap: little used, nothing swapped in: OK with totals and rates" {
  swap_fixture 1048576 1015808 100 100 200 205
  run "$P/check_swap_use"
  [ "$status" -eq 0 ]
  [[ "$output" == "SWAP OK - 3.1% used (32.0 MiB of 1.0 GiB), in 0.0 KiB/s out 20.0 KiB/s | used_pct=3.1%;50;80;0;100 swap_total=1073741824B swap_used=33554432B swap_free=1040187392B swap_in_Bps=0 swap_out_Bps=20480" ]]
}

@test "swap: pages swapped in during the sample is WARNING (memory pressure)" {
  swap_fixture 1048576 1015808 100 140 200 200
  run "$P/check_swap_use" -i 2
  [ "$status" -eq 1 ]
  [[ "$output" == "SWAP WARNING - 3.1% used"*"in 80.0 KiB/s out 0.0 KiB/s, swapping in (memory pressure) |"*"swap_in_Bps=81920 swap_out_Bps=0" ]]
}

@test "swap: a node with swap (lab DL360: 4 GiB), idle, is OK; the page size scales the rates" {
  swap_fixture 4194300 4194300 0 0 10 12
  HPS_PAGESIZE=16384 run "$P/check_swap_use"
  [ "$status" -eq 0 ]
  [[ "$output" == "SWAP OK - 0.0% used (0.0 MiB of 4.0 GiB), in 0.0 KiB/s out 32.0 KiB/s |"*"swap_total=4294963200B"*"swap_out_Bps=32768" ]]
}

@test "swap: used 50% is WARNING, 80% CRITICAL; -w and -c move them" {
  swap_fixture 1000 500 0 0 0 0
  run "$P/check_swap_use"
  [ "$status" -eq 1 ]
  [[ "$output" == "SWAP WARNING - 50.0% used"* ]]
  swap_fixture 1000 200 0 0 0 0
  run "$P/check_swap_use"
  [ "$status" -eq 2 ]
  [[ "$output" == "SWAP CRITICAL - 80.0% used"* ]]
  run "$P/check_swap_use" -w 85 -c 95
  [ "$status" -eq 0 ]
}

@test "swap: unreadable /proc files are UNKNOWN" {
  run "$P/check_swap_use"
  [ "$status" -eq 3 ]
  [[ "$output" == "SWAP UNKNOWN - cannot read"* ]]
}

# hb_status <peer:beating>...: om daemon status JSON of node sch-001 (om3 rc60 form)
hb_status() {
  local peers="" p
  for p in "$@"; do
    peers+="${peers:+,}\"${p%%:*}\":{\"is_beating\":${p#*:}}"
  done
  printf '{"daemon":{"nodename":"sch-001"},"cluster":{"node":{"sch-001":{"daemon":{"heartbeat":{"streams":[{"id":"hb#1.rx","peers":{%s}},{"id":"hb#1.tx","peers":{%s}}]}}}}}}\n' "$peers" "$peers" > "$TEST_DIR/status.json"
}

@test "osvc_hb: every peer beating is OK, perfdata peers beating stale; om daemon status --format json, bounded" {
  hb_status sch-002:true tch-001:true tch-002:true tch-003:true
  run "$P/check_osvc_hb"
  [ "$status" -eq 0 ]
  [ "$output" = "OSVC_HB OK - 4 of 4 peers beating | peers=4 beating=4 stale=0" ]
  grep -qx 'om daemon status --format json' "$TEST_DIR/om.log"
  grep -q 'timeout 8 "$OM" daemon status --format json' "$P/check_osvc_hb"
}

@test "osvc_hb: a stale peer is WARNING, named" {
  hb_status sch-002:false tch-001:true tch-002:true tch-003:true
  run "$P/check_osvc_hb"
  [ "$status" -eq 1 ]
  [ "$output" = "OSVC_HB WARNING - 3 of 4 peers beating; stale: sch-002 | peers=4 beating=3 stale=1" ]
}

@test "osvc_hb: beating nodes below quorum is CRITICAL (5 nodes: 2 of 5 beating)" {
  hb_status sch-002:false tch-001:true tch-002:false tch-003:false
  run "$P/check_osvc_hb"
  [ "$status" -eq 2 ]
  [[ "$output" == "OSVC_HB CRITICAL - 1 of 4 peers beating, below quorum (2 of 5 nodes, 3 needed); stale: sch-002 tch-002 tch-003 |"* ]]
  hb_status sch-002:false tch-001:true tch-002:true tch-003:false
  run "$P/check_osvc_hb"
  [ "$status" -eq 1 ]
}

@test "osvc_hb: a peer beating in one stream only is beating; a one-node cluster is OK" {
  printf '{"daemon":{"nodename":"sch-001","heartbeat":{"streams":[{"peers":{"sch-002":{"is_beating":false}}},{"peers":{"sch-002":{"is_beating":true}}}]}}}\n' > "$TEST_DIR/status.json"
  run "$P/check_osvc_hb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 of 1 peers beating"* ]]
  printf '{"daemon":{"nodename":"sch-001","heartbeat":{"streams":[]}}}\n' > "$TEST_DIR/status.json"
  run "$P/check_osvc_hb"
  [ "$status" -eq 0 ]
  [ "$output" = "OSVC_HB OK - 0 of 0 peers beating | peers=0 beating=0 stale=0" ]
}

@test "osvc_hb: om not installed, the daemon down, or unreadable JSON is UNKNOWN" {
  HPS_OM="$TEST_DIR/bin/no-om" run "$P/check_osvc_hb"
  [ "$status" -eq 3 ]
  [ "$output" = "OSVC_HB UNKNOWN - om is not installed" ]
  hb_status sch-002:true
  FAKE_OM_RC=1 run "$P/check_osvc_hb"
  [ "$status" -eq 3 ]
  [[ "$output" == "OSVC_HB UNKNOWN - om daemon status failed (exit 1): the daemon is not running or not answering" ]]
  echo 'not json' > "$TEST_DIR/status.json"
  run "$P/check_osvc_hb"
  [ "$status" -eq 3 ]
  [[ "$output" == *"no readable JSON"* ]]
}
