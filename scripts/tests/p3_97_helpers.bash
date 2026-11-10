# Helpers for the IPS-08 BMC tests (test_p3_97*.bats): PATH shims for curl,
# ipmitool and a PDU command. The shims record every argv (and whether the
# credential arrived on stdin or in the environment) so a test can assert the
# credential never reached a command line.

P97_USER='admin-test'
P97_PASS='s3cr3t"Pw\x9'

# p97_setup: temp dir, shim dir on PATH, fixture dir for the curl shim.
p97_setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_DIR="$(mktemp -d "${BATS_TMPDIR:-/tmp}/p3-97.XXXXXX")"
  export TEST_DIR ROOT
  export SHIM_LOG="$TEST_DIR/shim.log"
  export CALLS_LOG="$TEST_DIR/calls.log"
  export FIX_DIR="$TEST_DIR/fix"
  export P97_USER P97_PASS
  mkdir -p "$TEST_DIR/bin" "$FIX_DIR"
  : > "$SHIM_LOG"
  : > "$CALLS_LOG"
  export PATH="$TEST_DIR/bin:$PATH"
  export DRIVERS="$ROOT/lib/bmc/drivers"
  p97_shim_curl
  p97_shim_ipmitool
  p97_shim_pdu
}

p97_teardown() {
  rm -rf "$TEST_DIR"
}

# p97_run_driver <driver> <action> [VAR=value ...]: run a driver with the
# credential on stdin and the target in the environment.
p97_run_driver() {
  local driver="$1" action="$2"
  shift 2
  run env BMC_ADDR=bmc.example.invalid BMC_HOST=host1 "$@" bash -c 'printf "%s\n%s\n" "$P97_USER" "$P97_PASS" | "$0" "$1"' "$DRIVERS/$driver" "$action"
}

# p97_fix <METHOD> <path> <json> [code]: canned answer of the curl shim.
p97_fix() {
  local method="$1" path="$2" body="$3" code="${4:-200}" key
  key="$(printf '%s' "${path%/}" | tr '/' '_')"
  printf '%s' "$body" > "$FIX_DIR/$method$key.json"
  printf '%s' "$code" > "$FIX_DIR/$method$key.code"
}

# p97_no_credential_in <file>: the password is nowhere in the file.
p97_no_credential_in() {
  ! grep -qF -- "$P97_PASS" "$1"
}

p97_shim_curl() {
  cat > "$TEST_DIR/bin/curl" <<'SHIM'
#!/usr/bin/env bash
# curl shim: serves canned Redfish JSON per method and path, checks the
# credential from the -K - config on stdin, records argv and calls.
echo "curl $*" >> "$SHIM_LOG"
if [[ -n "${FAKE_CURL_RC:-}" ]]; then exit "$FAKE_CURL_RC"; fi
method=GET body="" url="" cfg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -K) cfg="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -H | --max-time | -w) shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
cred=""
if [[ "$cfg" == "-" ]]; then
  line="$(cat)"
  line="${line#user = \"}"
  line="${line%\"}"
  cred="${line//\\\"/\"}"
  cred="${cred//\\\\/\\}"
fi
path="/${url#https://*/}"
key="$(printf '%s' "${path%/}" | tr '/' '_')"
echo "$method $path $body" >> "$CALLS_LOG"
if [[ "$cred" != "$P97_USER:$P97_PASS" ]]; then
  printf '{"error":"auth"}\n401\n'
  exit 0
fi
if [[ -f "$FIX_DIR/$method$key.json" ]]; then
  printf '%s\n%s\n' "$(cat "$FIX_DIR/$method$key.json")" "$(cat "$FIX_DIR/$method$key.code")"
else
  printf '{"error":"not found"}\n404\n'
fi
SHIM
  chmod +x "$TEST_DIR/bin/curl"
}

p97_shim_ipmitool() {
  cat > "$TEST_DIR/bin/ipmitool" <<'SHIM'
#!/usr/bin/env bash
echo "ipmitool $* [IPMI_PASSWORD_SET=${IPMI_PASSWORD:+yes}]" >> "$SHIM_LOG"
if [[ -n "${IPMI_PASSWORD:-}" && "$IPMI_PASSWORD" != "$P97_PASS" ]]; then
  echo "Error: Unable to establish IPMI v2 / RMCP+ session" >&2
  exit 1
fi
if [[ -n "${FAKE_IPMI_ERR:-}" ]]; then
  echo "$FAKE_IPMI_ERR" >&2
  exit 1
fi
args="$*"
args="${args#*-E }"
case "$args" in
  "chassis power status") echo "Chassis Power is ${FAKE_IPMI_POWER:-on}" ;;
  "mc info")
    printf 'Device ID                 : 32\nFirmware Revision         : 2.55\nManufacturer ID           : 11\nProduct ID                : 8199 (0x2007)\n' ;;
  "fru print 0")
    printf 'Product Manufacturer  : HPE\nProduct Name          : ProLiant DL360 Gen9\nProduct Serial        : SER123\n' ;;
  "lan print")
    printf 'IP Address Source       : Static Address\nIP Address              : 192.0.2.50\nMAC Address             : aa:bb:cc:00:11:22\n' ;;
esac
exit 0
SHIM
  chmod +x "$TEST_DIR/bin/ipmitool"
}

p97_shim_pdu() {
  cat > "$TEST_DIR/bin/pdu-ctl" <<'SHIM'
#!/usr/bin/env bash
echo "pdu-ctl $*" >> "$SHIM_LOG"
cat > "$TEST_DIR/pdu-stdin"
case "${*: -1}" in
  status) echo "outlet is ${FAKE_PDU_STATE:-on}" ;;
esac
exit "${FAKE_PDU_RC:-0}"
SHIM
  chmod +x "$TEST_DIR/bin/pdu-ctl"
}
