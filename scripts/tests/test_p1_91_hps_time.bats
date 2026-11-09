#!/usr/bin/env bats
#
# CS-1.9: node-manager/nixos-26/boot/hps-time.sh with curl, date, ip, systemctl
# shimmed. The clock is only stepped when its year is implausible; the
# timesyncd drop-in is always written when an IPS is known.

setup() {
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p1-91.XXXXXX")"
  export TEST_DIR
  export SHIM_LOG="$TEST_DIR/shim.log"
  export HPS_CMDLINE="$TEST_DIR/cmdline"
  export HPS_TIMESYNCD_DIR="$TEST_DIR/run/timesyncd.conf.d"
  export HPS_TIME_GW_TRIES=1
  SCRIPT="${BATS_TEST_DIRNAME}/../../node-manager/nixos-26/boot/hps-time.sh"
  export PATH="$TEST_DIR/bin:$PATH"
  mkdir -p "$TEST_DIR/bin"
  : > "$SHIM_LOG"
  echo "console=ttyS1 hps.ips=10.99.1.1 hps.mac=aa:bb:cc:dd:ee:ff" > "$HPS_CMDLINE"

  cat > "$TEST_DIR/bin/date" <<'SH'
#!/bin/bash
echo "date $*" >> "$SHIM_LOG"
if [[ "$*" == "-u +%Y" ]]; then
  echo "${FAKE_YEAR:-2001}"
fi
exit 0
SH
  cat > "$TEST_DIR/bin/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$SHIM_LOG"
if [[ "${FAKE_NO_DATE:-}" == 1 ]]; then
  printf 'HTTP/1.1 404 Not Found\r\nServer: httpd\r\n\r\n'
  exit 0
fi
printf 'HTTP/1.1 404 Not Found\r\nServer: httpd\r\nDate: Mon, 09 Nov 2026 12:19:00 GMT\r\nContent-Type: text/html\r\n\r\n'
exit "${FAKE_CURL_RC:-0}"
SH
  cat > "$TEST_DIR/bin/ip" <<'SH'
#!/bin/bash
echo "ip $*" >> "$SHIM_LOG"
echo "default via 10.99.1.254 dev eno1"
SH
  cat > "$TEST_DIR/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >> "$SHIM_LOG"
exit "${FAKE_SYSTEMCTL_RC:-0}"
SH
  cat > "$TEST_DIR/bin/sleep" <<'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "a clock in 2001 is set from the IPS Date header" {
  FAKE_YEAR=2001 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'date -u -s Mon, 09 Nov 2026 12:19:00 GMT' "$SHIM_LOG"
  grep -q '^curl .*http://10.99.1.1/nixos/latest' "$SHIM_LOG"
}

@test "a plausible clock is left alone" {
  FAKE_YEAR=2026 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  if grep -q '^date -u -s' "$SHIM_LOG"; then return 1; fi
  if grep -q '^curl ' "$SHIM_LOG"; then return 1; fi
}

@test "the timesyncd drop-in names the IPS and timesyncd is restarted" {
  FAKE_YEAR=2026 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$HPS_TIMESYNCD_DIR/hps.conf")" = "$(printf '[Time]\nNTP=10.99.1.1\nFallbackNTP=')" ]
  grep -qx 'systemctl try-restart systemd-timesyncd.service' "$SHIM_LOG"
}

@test "no hps.ips falls back to the default gateway" {
  echo "console=ttyS1" > "$HPS_CMDLINE"
  FAKE_YEAR=2001 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'NTP=10.99.1.254' "$HPS_TIMESYNCD_DIR/hps.conf"
  grep -q '^curl .*http://10.99.1.254/nixos/latest' "$SHIM_LOG"
}

@test "no IPS at all logs and exits 0 without touching the clock or writing a drop-in" {
  echo "console=ttyS1" > "$HPS_CMDLINE"
  cat > "$TEST_DIR/bin/ip" <<'SH'
#!/bin/bash
echo "ip $*" >> "$SHIM_LOG"
SH
  FAKE_YEAR=2001 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no IPS address found"* ]]
  [ ! -e "$HPS_TIMESYNCD_DIR/hps.conf" ]
  if grep -q '^date -u -s' "$SHIM_LOG"; then return 1; fi
}

@test "an IPS reply without a Date header leaves the clock and still exits 0" {
  FAKE_YEAR=2001 FAKE_NO_DATE=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no Date: header"* ]]
  if grep -q '^date -u -s' "$SHIM_LOG"; then return 1; fi
  [ -f "$HPS_TIMESYNCD_DIR/hps.conf" ]
}

@test "an unreachable IPS exits 0" {
  FAKE_YEAR=2001 FAKE_CURL_RC=7 FAKE_NO_DATE=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "every command is logged as it runs" {
  FAKE_YEAR=2001 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  for c in 'mkdir -p' 'date -u +%Y' 'curl -sI' 'date -u -s' 'systemctl try-restart'; do
    [[ "$output" == *"+ $c"* ]]
  done
}

@test "the script is shellcheck clean and uses env bash" {
  [ "$(head -1 "$SCRIPT")" = "#!/usr/bin/env bash" ]
  run shellcheck -S warning "$SCRIPT"
  [ "$status" -eq 0 ]
}
