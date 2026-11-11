#!/usr/bin/env bats
#
# IPS-08, owner ruling 2026-11-11: the `console` action of the BMC driver
# contract (hps-bmc console <host> [--seconds N]). ssh, sshpass, script,
# ipmitool and timeout are PATH shims (the shims record argv and the
# environment flags; script runs its -c command line, timeout logs and runs
# the real one). Proves: the iLO 4 ssh options, vsp then the keystrokes then
# the leave sequence on the session's stdin, the per-BMC known_hosts path,
# the password only in SSHPASS / IPMI_PASSWORD and in no argv, output or log,
# the ipmi sol activate/deactivate pair (also on timeout), exit 5 for the
# drivers without a console, the exit-code mapping, and the --seconds bounds.

bats_require_minimum_version 1.5.0

setup() {
  load p3_97_helpers
  p97_setup
  HPSBMC="$ROOT/bin/hps-bmc"
  export HPS_CONFIG_BASE="$TEST_DIR/cfg"
  export HPS_SYSTEM_REGISTRY="$TEST_DIR/cfg/system.db"
  export HPS_BMC_RETRY_DELAY=0
  export HPS_BMC_ENV_PASS="SHIM_LOG CALLS_LOG FIX_DIR TEST_DIR P97_USER P97_PASS FAKE_SSH_RC FAKE_SSH_ERR FAKE_SSHPASS_RC FAKE_SOL_HANG"
  unset HPS_BMC_NO_SYSLOG
  export PERL5LIB="$ROOT/lib/perl"
  mkdir -p "$HPS_CONFIG_BASE/clusters/lab/cluster.db" "$HPS_CONFIG_BASE/clusters/lab/hosts" "$HPS_SYSTEM_REGISTRY"
  perl -MHPS::Registry -e 'HPS::Registry->new->system_set("ACTIVE_CLUSTER", "lab")'
  MAC=52:54:00:97:aa:01
  MAC12=52540097aa01
  MAC2=52:54:00:97:aa:02
  KH_DIR="$HPS_CONFIG_BASE/clusters/lab/bmc"
  cat > "$TEST_DIR/bin/logger" <<'SHIM'
#!/usr/bin/env bash
echo "logger $*" >> "$SHIM_LOG"
SHIM
  cat > "$TEST_DIR/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
echo "ssh $*" >> "$SHIM_LOG"
echo "SSHPASS_OK=$([[ "${SSHPASS:-}" == "$P97_PASS" ]] && echo yes || echo no)" >> "$TEST_DIR/ssh-env"
errf=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -E ]]; then errf="$2"; fi
  shift
done
echo "CONSOLE-OUTPUT"
if [[ -n "${FAKE_SSH_RC:-}" ]]; then
  if [[ -n "${FAKE_SSH_ERR:-}" && -n "$errf" ]]; then echo "$FAKE_SSH_ERR" > "$errf"; fi
  exit "$FAKE_SSH_RC"
fi
cat > "$TEST_DIR/ssh-stdin"
exit 0
SHIM
  cat > "$TEST_DIR/bin/sshpass" <<'SHIM'
#!/usr/bin/env bash
echo "sshpass $*" >> "$SHIM_LOG"
if [[ -n "${FAKE_SSHPASS_RC:-}" ]]; then exit "$FAKE_SSHPASS_RC"; fi
shift
exec "$@"
SHIM
  cat > "$TEST_DIR/bin/script" <<'SHIM'
#!/usr/bin/env bash
echo "script $*" >> "$SHIM_LOG"
cmd=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -c ]]; then cmd="$2"; fi
  shift
done
exec bash -c "$cmd"
SHIM
  cat > "$TEST_DIR/bin/timeout" <<'SHIM'
#!/usr/bin/env bash
echo "timeout $*" >> "$SHIM_LOG"
exec /usr/bin/timeout "$@"
SHIM
  cat > "$TEST_DIR/bin/ipmitool" <<'SHIM'
#!/usr/bin/env bash
echo "ipmitool $* [IPMI_PASSWORD_OK=$([[ "${IPMI_PASSWORD:-}" == "$P97_PASS" ]] && echo yes || echo no)]" >> "$SHIM_LOG"
case "$*" in
  *"sol activate")
    echo "SOL-OUTPUT"
    if [[ -n "${FAKE_SOL_HANG:-}" ]]; then sleep 30; fi
    cat > "$TEST_DIR/sol-stdin"
    ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR"/bin/*
}

teardown() {
  p97_teardown
}

# con_host <driver> [--option k=v ...]: a registered host with a driver and the credential.
con_host() {
  local mac="${CON_MAC:-$MAC}"
  perl -MHPS::Registry -e '$r = HPS::Registry->new; $r->host_set($ARGV[0], "STATE", "INSTALLED"); $r->host_set($ARGV[0], "HOSTNAME", $ARGV[1])' "$mac" "${CON_NAME:-sch-001.lab}"
  run "$HPSBMC" set "$mac" --driver "$@" --addr bmc.example.invalid --option console_settle=0
  [ "$status" -eq 0 ]
  run bash -c 'printf "%s\n%s\n" "$P97_USER" "$P97_PASS" | "$0" credential "$1"' "$HPSBMC" "$mac"
  [ "$status" -eq 0 ]
}

# con_driver <driver> [VAR=value ...]: a driver run directly, credential on fd 3.
con_driver() {
  local driver="$1"
  shift
  run --separate-stderr env BMC_ADDR=bmc.example.invalid BMC_HOST=host1 BMC_CONSOLE_SECONDS=1 \
    BMC_KNOWN_HOSTS="$TEST_DIR/kh" BMC_OPT_console_settle=0 "$@" \
    bash -c '"$0" console 3< <(printf "%s\n%s\n" "$P97_USER" "$P97_PASS") < /dev/null' "$DRIVERS/$driver"
}

# no_password_anywhere: the password is in no argv log, output or stderr.
no_password_anywhere() {
  ! grep -qF -- "$P97_PASS" "$SHIM_LOG"
  [[ "$output" != *"$P97_PASS"* ]]
  [[ "${stderr:-}" != *"$P97_PASS"* ]]
}

# --- hpe-ilo: the ssh VSP method ---------------------------------------------------

@test "hpe-ilo console runs the iLO 4 ssh command line with sshpass -e" {
  con_host hpe-ilo
  run --separate-stderr bash -c 'printf "hi\n" | "$0" console sch-001 --seconds 1' "$HPSBMC"
  [ "$status" -eq 0 ]
  grep -qF 'sshpass -e ssh -tt ' "$SHIM_LOG"
  local line
  line="$(grep '^ssh ' "$SHIM_LOG")"
  [[ "$line" == *"-o StrictHostKeyChecking=accept-new"* ]]
  [[ "$line" == *"-o HostKeyAlgorithms=+ssh-rsa"* ]]
  [[ "$line" == *"-o PubkeyAcceptedAlgorithms=+ssh-rsa"* ]]
  [[ "$line" == *"-o KexAlgorithms=+diffie-hellman-group14-sha1"* ]]
  [[ "$line" == *"-tt"* ]]
  [[ "$line" == *" admin-test@bmc.example.invalid" ]]
  grep -q '^script -q -f -e -c sshpass' "$SHIM_LOG"
}

@test "hpe-ilo console sends vsp, relays the keystrokes, then ESC ( and exit" {
  con_host hpe-ilo
  run --separate-stderr bash -c 'printf "ls\nuname\n" | "$0" console sch-001 --seconds 1' "$HPSBMC"
  [ "$status" -eq 0 ]
  printf 'vsp\rls\runame\r\033(exit\r' > "$TEST_DIR/expected-stdin"
  cmp "$TEST_DIR/ssh-stdin" "$TEST_DIR/expected-stdin"
}

@test "hpe-ilo console prints the console output on stdout" {
  con_host hpe-ilo
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *CONSOLE-OUTPUT* ]]
}

@test "hpe-ilo console known_hosts file is per BMC under the cluster state dir" {
  con_host hpe-ilo
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  grep -qF "UserKnownHostsFile=$KH_DIR/known_hosts-$MAC12 " "$SHIM_LOG"
  [ "$(stat -c %a "$KH_DIR")" = 700 ]
  CON_MAC="$MAC2" CON_NAME=sch-002.lab con_host hpe-ilo
  run --separate-stderr "$HPSBMC" console sch-002 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  grep -qF "UserKnownHostsFile=$KH_DIR/known_hosts-52540097aa02 " "$SHIM_LOG"
}

@test "hpe-ilo console password: SSHPASS environment only, never argv, output or log" {
  con_host hpe-ilo
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  grep -qx 'SSHPASS_OK=yes' "$TEST_DIR/ssh-env"
  no_password_anywhere
  ! grep -qF 'sshpass -p' "$SHIM_LOG"
}

@test "console logs action, host, driver, exit and seconds, never content" {
  con_host hpe-ilo
  run --separate-stderr bash -c 'printf "secretkeys\n" | "$0" console sch-001 --seconds 1' "$HPSBMC"
  [ "$status" -eq 0 ]
  grep -qE "hps-bmc: action=console host=$MAC12 driver=hpe-ilo exit=0 seconds=1" "$SHIM_LOG"
  ! grep -qF CONSOLE-OUTPUT "$SHIM_LOG"
  ! grep -qF secretkeys "$SHIM_LOG"
}

@test "hpe-ilo console ends when the far end closes, without waiting for the limit" {
  con_host hpe-ilo
  start=$SECONDS
  FAKE_SSH_RC=0 run --separate-stderr "$HPSBMC" console sch-001 --seconds 300 < /dev/null
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 20 ]
}

@test "console passes the bound to timeout: default 600, and 3600" {
  con_host hpe-ilo
  FAKE_SSH_RC=0 run --separate-stderr "$HPSBMC" console sch-001 < /dev/null
  [ "$status" -eq 0 ]
  grep -qF 'timeout -k 5 615 script' "$SHIM_LOG"
  FAKE_SSH_RC=0 run --separate-stderr "$HPSBMC" console sch-001 --seconds 3600 < /dev/null
  [ "$status" -eq 0 ]
  grep -qF 'timeout -k 5 3615 script' "$SHIM_LOG"
}

@test "hpe-ilo console exit codes: changed host key 3, wrong password 3, unreachable 4, other 1" {
  con_host hpe-ilo
  FAKE_SSH_RC=255 FAKE_SSH_ERR='WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!' run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 3 ]
  FAKE_SSH_RC=255 FAKE_SSH_ERR='Host key verification failed.' run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 3 ]
  FAKE_SSHPASS_RC=5 run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 3 ]
  FAKE_SSH_RC=255 FAKE_SSH_ERR='ssh: connect to host bmc.example.invalid port 22: Connection timed out' run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 4 ]
  FAKE_SSH_RC=2 run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 1 ]
  grep -qE "action=console host=$MAC12 driver=hpe-ilo exit=4 seconds=1" "$SHIM_LOG"
  no_password_anywhere
}

@test "console without a stored credential is refused (exit 3)" {
  con_host hpe-ilo
  [ -d "$HPS_CONFIG_BASE/clusters/lab/keysafe/credentials" ]
  rm -rf "$HPS_CONFIG_BASE/clusters/lab/keysafe/credentials"
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 3 ]
  [[ "$stderr" == *"no credential"* ]]
  ! grep -q '^ssh ' "$SHIM_LOG"
}

# --- redfish-generic ------------------------------------------------------------------

@test "redfish-generic console exits 5 with a one-line reason" {
  con_host redfish-generic
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"no serial console method"* ]]
  con_driver redfish-generic
  [ "$status" -eq 5 ]
  [ "$(wc -l <<< "$stderr")" -eq 1 ]
  ! grep -q '^ssh ' "$SHIM_LOG"
}

@test "redfish-generic with console=ssh-vsp reuses the iLO method" {
  con_host redfish-generic --option console=ssh-vsp
  run --separate-stderr bash -c 'printf "x\n" | "$0" console sch-001 --seconds 1' "$HPSBMC"
  [ "$status" -eq 0 ]
  grep -qF 'sshpass -e ssh -tt ' "$SHIM_LOG"
  grep -qF 'HostKeyAlgorithms=+ssh-rsa' "$SHIM_LOG"
  printf 'vsp\rx\r\033(exit\r' > "$TEST_DIR/expected-stdin"
  cmp "$TEST_DIR/ssh-stdin" "$TEST_DIR/expected-stdin"
}

@test "redfish-generic with an unknown console method exits 5" {
  con_driver redfish-generic BMC_OPT_console=carrier-pigeon
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"unknown console method"* ]]
}

# --- ipmi -----------------------------------------------------------------------------

@test "ipmi console runs sol activate with IPMI_PASSWORD, then sol deactivate" {
  con_host ipmi
  run --separate-stderr bash -c 'printf "ls\n" | "$0" console sch-001 --seconds 1' "$HPSBMC"
  [ "$status" -eq 0 ]
  [[ "$output" == *SOL-OUTPUT* ]]
  grep -qF 'ipmitool -I lanplus -H bmc.example.invalid -U admin-test -E sol activate [IPMI_PASSWORD_OK=yes]' "$SHIM_LOG"
  grep -qF 'ipmitool -I lanplus -H bmc.example.invalid -U admin-test -E sol deactivate [IPMI_PASSWORD_OK=yes]' "$SHIM_LOG"
  [ "$(grep -n 'sol ' "$SHIM_LOG" | head -1 | grep -c activate)" -eq 1 ]
  [ "$(cat "$TEST_DIR/sol-stdin")" = ls ]
  grep -qF 'timeout -k 5 1 ipmitool' "$SHIM_LOG"
  no_password_anywhere
  grep -qE "action=console host=$MAC12 driver=ipmi exit=0 seconds=1" "$SHIM_LOG"
}

@test "ipmi console deactivates after the timeout too" {
  con_host ipmi
  FAKE_SOL_HANG=1 run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  grep -qF -- '-E sol deactivate' "$SHIM_LOG"
}

# --- no console: external, manual, dell-idrac -----------------------------------------

@test "external, manual and dell-idrac console exit 5 with a reason" {
  local d
  for d in external manual dell-idrac; do
    con_driver "$d"
    [ "$status" -eq 5 ]
    [ -n "$stderr" ]
  done
  ! grep -q '^ssh ' "$SHIM_LOG"
}

@test "hps-bmc console on a manual host exits 5 and is logged" {
  con_host manual
  run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 5 ]
  grep -qE "action=console host=$MAC12 driver=manual exit=5 seconds=1" "$SHIM_LOG"
}

@test "hps-bmc console on a host with no driver exits 5" {
  perl -MHPS::Registry -e 'HPS::Registry->new->host_set($ARGV[0], "HOSTNAME", "sch-009.lab")' "$MAC"
  run --separate-stderr "$HPSBMC" console sch-009 < /dev/null
  [ "$status" -eq 5 ]
}

# --- usage and bounds -----------------------------------------------------------------

@test "console usage errors exit 2 and run nothing" {
  con_host hpe-ilo
  run --separate-stderr "$HPSBMC" console
  [ "$status" -eq 2 ]
  run --separate-stderr "$HPSBMC" console sch-001 extra
  [ "$status" -eq 2 ]
  run --separate-stderr "$HPSBMC" console sch-001 --bogus
  [ "$status" -eq 2 ]
  run --separate-stderr "$HPSBMC" console sch-001 --seconds
  [ "$status" -eq 2 ]
  ! grep -q '^ssh ' "$SHIM_LOG"
}

@test "console --seconds accepts only integers 1 to 3600" {
  con_host hpe-ilo
  local s
  for s in 0 3601 99999 -5 1.5 abc '' ' 5'; do
    run --separate-stderr "$HPSBMC" console sch-001 --seconds "$s" < /dev/null
    [ "$status" -eq 2 ]
  done
  ! grep -q '^ssh ' "$SHIM_LOG"
  FAKE_SSH_RC=0 run --separate-stderr "$HPSBMC" console sch-001 --seconds 1 < /dev/null
  [ "$status" -eq 0 ]
  FAKE_SSH_RC=0 run --separate-stderr "$HPSBMC" console sch-001 --seconds 3600 < /dev/null
  [ "$status" -eq 0 ]
}

@test "console on an unknown host exits 1" {
  run --separate-stderr "$HPSBMC" console nosuchhost --seconds 1 < /dev/null
  [ "$status" -eq 1 ]
}

@test "hps-bmc usage documents console" {
  run --separate-stderr "$HPSBMC" help
  [[ "$stderr" == *"hps-bmc console <host> [--seconds N]"* ]]
}
