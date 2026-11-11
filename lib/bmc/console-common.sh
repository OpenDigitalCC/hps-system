# shellcheck shell=bash
# console-common.sh - the iLO Virtual Serial Port console over ssh, shared by
# the drivers that use it (hpe-ilo; redfish-generic with option console=ssh-vsp).
# Sourced after the driver has set RF_NAME; it is not a driver itself (see
# docs/BMC.md, "Console").
#
# Contract of the `console` action (the controller, HPS::BMC->console, sets it
# up): the credential (user line, password line) arrives on file descriptor 3,
# because stdin carries the keystrokes; BMC_ADDR is the BMC; BMC_KNOWN_HOSTS is
# the per-BMC known_hosts file; BMC_CONSOLE_SECONDS the time limit. Console
# output goes to stdout, diagnostics to stderr. The password reaches sshpass
# only through the environment (SSHPASS, sshpass -e), never argv.
#
# sshpass segfaults when its stdin is a pipe, so script(1) gives it a pty. The
# driver feeds the session: "vsp" after the CLP banner, then the caller's
# keystrokes until the limit, then ESC ( (leaves the VSP) and "exit".
#
# Options: console_settle (seconds before "vsp" is sent, default 4).

con_die() {
  # con_die <exit code> <message>
  printf '%s: %s\n' "${RF_NAME:-console}" "$2" >&2
  exit "$1"
}

CON_USER=""
CON_PASS=""

# con_read_credential: user and password from fd 3.
con_read_credential() {
  { IFS= read -r CON_USER <&3 || true; } 2> /dev/null
  { IFS= read -r CON_PASS <&3 || true; } 2> /dev/null
  [[ -n "$CON_USER" && -n "$CON_PASS" ]] || con_die 3 "no credential supplied on fd 3"
}

# con_check_target: BMC_ADDR, the time limit and the known_hosts path.
con_check_target() {
  [[ -n "${BMC_ADDR:-}" ]] || con_die 1 "BMC_ADDR is not set"
  [[ "$BMC_ADDR" =~ ^[][A-Za-z0-9._:-]+$ ]] || con_die 1 "BMC_ADDR has unsupported characters"
  [[ "$CON_USER" =~ ^[A-Za-z0-9._@-]+$ ]] || con_die 1 "the BMC user name has unsupported characters"
  [[ "${BMC_CONSOLE_SECONDS:-}" =~ ^[0-9]+$ ]] || con_die 1 "BMC_CONSOLE_SECONDS is not set"
  [[ -n "${BMC_KNOWN_HOSTS:-}" ]] || con_die 1 "BMC_KNOWN_HOSTS is not set"
}

# con_feed <seconds>: the keystrokes into script(1), read from fd 4 (the
# caller's stdin). Ends with the leave sequence; SIGUSR1 ends it early.
con_feed() {
  local secs="$1" stop=0 eof=0 deadline ch rc
  trap 'stop=1' USR1
  sleep "${BMC_OPT_console_settle:-4}"
  printf 'vsp\r'
  deadline=$((SECONDS + secs))
  while ((stop == 0 && SECONDS < deadline)); do
    if ((eof)); then
      sleep 0.5
      continue
    fi
    rc=0
    IFS= read -r -t 0.5 -N 1 ch <&4 || rc=$?
    if ((rc == 0)); then
      # A newline typed or piped in is Enter for the serial port.
      [[ "$ch" == $'\n' ]] && ch=$'\r'
      printf '%s' "$ch"
    elif ((rc <= 128)); then
      eof=1
    fi
  done
  printf '\033('
  sleep 1
  printf 'exit\r'
}

# con_classify <rc> <errfile>: the contract exit code for a failed session.
con_classify() {
  local rc="$1" errf="$2"
  case "$rc" in
    5 | 6) return 3 ;;
  esac
  if grep -qiE 'host key verification failed|identification has changed|permission denied|authentication fail' "$errf"; then
    return 3
  fi
  if grep -qiE 'timed out|refused|no route|could not resolve|unreachable|connection closed|reset by peer' "$errf"; then
    return 4
  fi
  return 1
}

# console_ssh_vsp: run the session; exits with the contract code.
console_ssh_vsp() {
  local secs="$BMC_CONSOLE_SECONDS" errf sshcmd rc=0 spid feed_pid
  con_read_credential
  con_check_target
  errf="/tmp/hps-console-$$.err"
  : > "$errf"
  # shellcheck disable=SC2064  # errf is fixed now
  trap "rm -f '$errf'" EXIT
  printf -v sshcmd 'sshpass -e ssh -tt -E %q -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1 -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1 %q' \
    "$errf" "$BMC_KNOWN_HOSTS" "${CON_USER}@${BMC_ADDR}"
  exec 4<&0
  exec 5< <(con_feed "$secs")
  feed_pid=$!
  trap 'kill -USR1 "$feed_pid" 2>/dev/null || true' TERM INT HUP
  SSHPASS="$CON_PASS" timeout -k 5 "$((secs + 15))" script -q -f -e -c "$sshcmd" /dev/null <&5 &
  spid=$!
  while true; do
    rc=0
    wait "$spid" || rc=$?
    kill -0 "$spid" 2> /dev/null || break
  done
  kill "$feed_pid" 2> /dev/null || true
  wait "$feed_pid" 2> /dev/null || true
  case "$rc" in
    0 | 124 | 137) exit 0 ;;
  esac
  [[ ! -s "$errf" ]] || head -c 600 "$errf" >&2
  local crc=0
  con_classify "$rc" "$errf" || crc=$?
  con_die "$crc" "console session to $BMC_ADDR failed (ssh exit $rc)"
}
