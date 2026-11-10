#!/usr/bin/env bats
#
# CS-2.4: ce_pairing_window_open/_close, the pending-request listing and the
# approval go through the job queue when `id -u` is not 0 (the CGI user) and call
# the dispatcher directly as root. The runner is the real bin/hps-jobs polling a
# temp queue, with a fake dispatcher on its side; the caller's own
# CTRL_EXEC_DISPATCHER points nowhere, so a call that bypassed the queue fails.

bats_require_minimum_version 1.5.0

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p2-61.XXXXXX")"
  export TEST_DIR
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export HPS_JOBS_DIR="$TEST_DIR/jobs"
  export CE_LOG="$TEST_DIR/ced.log"
  export CTRL_EXEC_PAIRING_DIR="$TEST_DIR/pairing"
  export CTRL_EXEC_PAIR_WINDOW=300
  export CTRL_EXEC_PAIR_CLOSE_DELAY=0
  mkdir -p "$CTRL_EXEC_PAIRING_DIR" "$TEST_DIR/bin"

  cat > "$TEST_DIR/fake-ced" <<EOT
#!/usr/bin/env bash
echo "\$*" >> "$CE_LOG"
case "\$1" in
  --help) echo "approve <reqid> [--replace]"; exit 0 ;;
  list-requests)
    echo "ID  HOSTNAME  SOURCE IP  REVERSE DNS  CODE"
    echo "-------------------------------------------"
    [[ -f "$TEST_DIR/list.row" ]] && cat "$TEST_DIR/list.row"
    ;;
  approve) echo "Approved \$2 (replaced: none)" ;;
esac
if [[ "\$1" == approve || "\$1" == pairing-mode ]] && [[ -f "$TEST_DIR/ced.rc" ]]; then
  echo "dispatcher says no" >&2
  exit "\$(cat "$TEST_DIR/ced.rc")"
fi
exit 0
EOT
  chmod +x "$TEST_DIR/fake-ced"

  # `id -u` is whatever FAKE_UID says (default: the web user); the rest is real id
  cat > "$TEST_DIR/bin/id" <<'EOT'
#!/usr/bin/env bash
if [[ "$*" == "-u" ]]; then echo "${FAKE_UID:-33}"; exit 0; fi
exec /usr/bin/id "$@"
EOT
  chmod +x "$TEST_DIR/bin/id"
  export PATH="$TEST_DIR/bin:$PATH"

  CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced" HPS_STORAGE_CMD="$TEST_DIR/fake-storage" \
    perl "$ROOT/bin/hps-jobs" --interval 0.1 > "$TEST_DIR/runner.log" 2>&1 3>&- &
  RUNNER_PID=$!

  export REG_FILE="$TEST_DIR/registry"
  : > "$REG_FILE"
  hps_log() { echo "$*" >> "$TEST_DIR/hps.log"; }
  host_registry() {
    local mac="$1" cmd="$2" key="$3" value="${4:-}" line
    case "$cmd" in
      get)
        line=$(grep -F "${mac}|${key}=" "$REG_FILE" | tail -n1) || true
        [[ -n "$line" ]] || return 1
        printf '%s\n' "${line#*=}"
        ;;
      set) printf '%s|%s=%s\n' "$mac" "$key" "$value" >> "$REG_FILE" ;;
    esac
  }
  export -f hps_log host_registry
  # host_fqdn (host-functions.sh) stubbed: registry HOSTNAME (first label) + .lab.hps
  host_fqdn() {
    local h
    h=$(host_registry "$1" get HOSTNAME) || return 1
    printf '%s.lab.hps\n' "${h%%.*}"
  }
  export -f host_fqdn

  source "${BATS_TEST_DIRNAME}/../../lib/hps-state.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/jobs-functions.sh"
  source "${BATS_TEST_DIRNAME}/../../lib/functions.d/ctrl-exec-functions.sh"
  hps_state_umask
  MAC="52:54:00:11:22:33"
  # the caller must not reach the dispatcher itself
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/not-there/ced"
  wait_for_dir "$HPS_JOBS_DIR/new"
}

teardown() {
  kill "$RUNNER_PID" 2> /dev/null || true
  wait "$RUNNER_PID" 2> /dev/null || true
  rm -rf "$TEST_DIR"
}

wait_for_dir() {
  for _ in {1..50}; do
    [[ -d "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

seed() {
  host_registry "$MAC" set STATE NETWORK_BOOT
  host_registry "$MAC" set IP 10.0.0.50
  host_registry "$MAC" set HOSTNAME node-50
  host_registry "$MAC" set last_boot_at "$(date +%s)"
  printf 'ab12cd34  node-50.lab.hps  10.0.0.50  -  1234\n' > "$TEST_DIR/list.row"
}

@test "as the web user the pairing window opens through a job" {
  run ce_pairing_window_open 120
  [ "$status" -eq 0 ]
  grep -qx 'pairing-mode start --timeout 120' "$CE_LOG"
  [ "$(ls "$HPS_JOBS_DIR/done" | wc -l)" -eq 1 ]
  f=("$HPS_JOBS_DIR"/done/*.result.json)
  [ "$(jq -r .kind "${f[0]}")" = "pairing-window-open" ]
}

@test "as the web user the pairing window closes through a job" {
  run ce_pairing_window_close
  [ "$status" -eq 0 ]
  grep -qx 'pairing-mode stop' "$CE_LOG"
}

@test "a window the dispatcher refuses is a failure of ce_pairing_window_open" {
  echo 5 > "$TEST_DIR/ced.rc"
  run ce_pairing_window_open 120
  [ "$status" -eq 1 ]
  [ "$(ls "$HPS_JOBS_DIR/failed" | wc -l)" -eq 1 ]
}

@test "an out-of-range window is refused before any job is queued" {
  run ce_pairing_window_open 9999
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$HPS_JOBS_DIR/new")" ]
  [ -z "$(ls -A "$HPS_JOBS_DIR/done")" ]
}

@test "as the web user the approval is a pairing-approve job with --replace" {
  seed
  run ce_approve_pair_request "$MAC" ab12cd34
  [ "$status" -eq 0 ]
  grep -qx 'list-requests' "$CE_LOG"
  grep -qx 'approve ab12cd34 --replace' "$CE_LOG"
  [ -n "$(host_registry "$MAC" get ctrl_exec_paired)" ]
  grep -q 'Approved ab12cd34' "$TEST_DIR/hps.log"
}

@test "the runner drops --replace for a dispatcher that does not list it" {
  seed
  cat > "$TEST_DIR/fake-ced" <<EOT
#!/usr/bin/env bash
echo "\$*" >> "$CE_LOG"
[[ "\$1" == --help ]] && { echo "approve <reqid>"; exit 0; }
[[ "\$1" == list-requests ]] && { echo "ID  H  S"; echo "--"; cat "$TEST_DIR/list.row"; }
exit 0
EOT
  run ce_approve_pair_request "$MAC" ab12cd34
  [ "$status" -eq 0 ]
  grep -qx 'approve ab12cd34' "$CE_LOG"
  run ! grep -q -- '--replace$' "$CE_LOG"
}

@test "a dispatcher refusal fails the approval and records nothing" {
  seed
  echo 1 > "$TEST_DIR/ced.rc"
  run ce_approve_pair_request "$MAC" ab12cd34
  [ "$status" -eq 1 ]
  [ -z "$(host_registry "$MAC" get ctrl_exec_paired || true)" ]
  grep -q 'dispatcher approve failed for ab12cd34' "$TEST_DIR/hps.log"
}

@test "a reqid with shell text never reaches the queue" {
  seed
  run ce_approve_pair_request "$MAC" 'abc;touch x'
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$HPS_JOBS_DIR/new")" ]
}

@test "as root the dispatcher is called directly and no job is queued" {
  export FAKE_UID=0
  export CTRL_EXEC_DISPATCHER="$TEST_DIR/fake-ced"
  seed
  run ce_pairing_window_open 120
  [ "$status" -eq 0 ]
  run ce_pairing_window_close
  [ "$status" -eq 0 ]
  run ce_approve_pair_request "$MAC" ab12cd34
  [ "$status" -eq 0 ]
  grep -qx 'pairing-mode start --timeout 120' "$CE_LOG"
  grep -qx 'pairing-mode stop' "$CE_LOG"
  grep -qx 'approve ab12cd34 --replace' "$CE_LOG"
  [ -z "$(ls -A "$HPS_JOBS_DIR/done")" ]
  [ -z "$(ls -A "$HPS_JOBS_DIR/failed")" ]
}
