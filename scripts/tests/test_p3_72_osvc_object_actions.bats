#!/usr/bin/env bats
#
# CS-3.5: osvc-object-start / -stop / -delete, osvc-freeze / -thaw. Starts and
# stops are always om <obj> start|stop --local; start also checks the object's
# enforced keywords first.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  T="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-72.XXXXXX")"
  SD="$ROOT/node-manager/nixos-26/scripts"
  mkdir -p "$T/bin" "$T/vals"
  export SHIM_LOG="$T/shim.log"
  export VALS="$T/vals"
  cat > "$T/bin/om" <<'SH'
#!/usr/bin/env bash
echo "om $*" >> "$SHIM_LOG"
if [[ "$2" == get ]]; then
  kw=${*: -1}
  if [[ -f "$VALS/$kw" ]]; then cat "$VALS/$kw"; exit 0; fi
  case "$kw" in
    nodes) echo sch-001 ;; topology) echo failover ;; orchestrate) echo no ;;
    monitor_action|placement) echo none ;;
  esac
  exit 0
fi
exit "${FAKE_OM_RC:-0}"
SH
  chmod +x "$T/bin/om"
  export PATH="$T/bin:$PATH"
}

teardown() {
  rm -rf "$T"
}

@test "start runs om <obj> start --local and nothing without --local" {
  run -0 bash "$SD/osvc-object-start" rig0
  grep -qx 'om svc/rig0 start --local' "$SHIM_LOG"
  [ "$(grep -c ' start' "$SHIM_LOG")" -eq "$(grep -c ' start --local' "$SHIM_LOG")" ]
  [[ "$output" == *"object svc/rig0 started"* ]]
}

@test "start reads the enforced keywords back first and refuses orchestrate=ha" {
  echo ha > "$VALS/orchestrate"
  run -3 bash "$SD/osvc-object-start" rig0
  run ! grep -q ' start ' "$SHIM_LOG"
}

@test "start refuses placement other than none and a two-node nodes list" {
  echo spread > "$VALS/placement"
  run -3 bash "$SD/osvc-object-start" rig0
  rm "$VALS/placement"
  echo 'sch-001 sch-002' > "$VALS/nodes"
  run -3 bash "$SD/osvc-object-start" rig0
  run ! grep -q ' start ' "$SHIM_LOG"
}

@test "stop runs om <obj> stop --local and does not read keywords" {
  echo ha > "$VALS/orchestrate"
  run -0 bash "$SD/osvc-object-stop" svc/rig0
  grep -qx 'om svc/rig0 stop --local' "$SHIM_LOG"
  run ! grep -q ' get ' "$SHIM_LOG"
}

@test "delete runs om <obj> delete --local --ignore-not-found" {
  run -0 bash "$SD/osvc-object-delete" rig0
  grep -qx 'om svc/rig0 delete --local --ignore-not-found' "$SHIM_LOG"
}

@test "start, stop and delete need exactly one valid object name" {
  local s
  for s in osvc-object-start osvc-object-stop osvc-object-delete; do
    run -2 bash "$SD/$s"
    run -2 bash "$SD/$s" a b
    run -2 bash "$SD/$s" 'Bad Name'
    run -2 bash "$SD/$s" '../x'
  done
  [ ! -e "$SHIM_LOG" ]
}

@test "om failing is exit 1 for start, stop and delete" {
  FAKE_OM_RC=1 run -1 bash "$SD/osvc-object-start" rig0
  FAKE_OM_RC=1 run -1 bash "$SD/osvc-object-stop" rig0
  FAKE_OM_RC=1 run -1 bash "$SD/osvc-object-delete" rig0
}

@test "freeze and thaw run om node freeze / om node thaw, no arguments allowed" {
  run -0 bash "$SD/osvc-freeze"
  grep -qx 'om node freeze' "$SHIM_LOG"
  run -0 bash "$SD/osvc-thaw"
  grep -qx 'om node thaw' "$SHIM_LOG"
  run -2 bash "$SD/osvc-freeze" now
  run -2 bash "$SD/osvc-thaw" now
}
