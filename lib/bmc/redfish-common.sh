#!/usr/bin/env bash
# redfish-common.sh - shared code of the Redfish drivers (redfish-generic,
# hpe-ilo, dell-idrac). Sourced by a driver after it has set its quirk
# variables; it is not a driver itself (see docs/BMC.md).
#
# Contract (docs/BMC.md): <driver> <action>; target in BMC_ADDR and BMC_OPT_*;
# credential on stdin, two lines (user, password), never on argv, never printed.
# curl gets the credential through a config on its own stdin (-K -), so it never
# shows in a process list.
#
# Quirk variables a driver may set before calling rf_main:
#   RF_SYSTEM_DEFAULT   ComputerSystem path used without discovery
#   RF_MANAGER_DEFAULT  Manager path used without discovery
#   RF_TRAILING_SLASH   1: every path ends in / (iLO 4 redirects otherwise)
#   RF_PXE_MODE         send | omit | auto: BootSourceOverrideMode in pxe-once
#   RF_PXE_MODE_VALUE   value sent (default UEFI; option boot_mode=bios sends Legacy)
set -euo pipefail

: "${RF_SYSTEM_DEFAULT:=}"
: "${RF_MANAGER_DEFAULT:=}"
: "${RF_TRAILING_SLASH:=0}"
: "${RF_PXE_MODE:=auto}"
: "${RF_PXE_MODE_VALUE:=UEFI}"

RF_USER=""
RF_PASS=""
RF_CODE=""
RF_BODY=""
RF_SYSTEM=""
RF_SYSJSON=""

die() {
  # die <exit code> <message>
  printf '%s: %s\n' "${RF_NAME:-redfish}" "$2" >&2
  exit "$1"
}

read_credential() {
  IFS= read -r RF_USER || true
  IFS= read -r RF_PASS || true
  [[ -n "$RF_USER" && -n "$RF_PASS" ]] || die 3 "no credential supplied on stdin"
  [[ -n "${BMC_ADDR:-}" ]] || die 1 "BMC_ADDR is not set"
}

# cfg_quote <text>: text escaped for a double-quoted curl config value.
cfg_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

norm_path() {
  local p="$1"
  if [[ "$RF_TRAILING_SLASH" == 1 && "$p" != */ ]]; then
    p="$p/"
  fi
  printf '%s' "$p"
}

# rf_req <METHOD> <path> [json body]: sets RF_CODE (HTTP status) and RF_BODY.
# Exit 4 when the BMC cannot be reached.
rf_req() {
  local method="$1" path out rc=0 insecure=(-k)
  path="$(norm_path "$2")"
  local body="${3:-}"
  local args=(-sS --max-time "${BMC_OPT_timeout:-20}" -K - -X "$method" -w '\n%{http_code}')
  if [[ "${BMC_OPT_tls_verify:-}" == yes ]]; then
    insecure=()
  fi
  args+=("${insecure[@]}")
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  args+=("https://${BMC_ADDR}${path}")
  out="$(printf 'user = "%s:%s"\n' "$(cfg_quote "$RF_USER")" "$(cfg_quote "$RF_PASS")" | curl "${args[@]}")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    case $rc in
      6 | 7 | 28 | 35 | 52 | 55 | 56 | 60) die 4 "BMC $BMC_ADDR unreachable (curl exit $rc)" ;;
      *) die 1 "curl failed (exit $rc)" ;;
    esac
  fi
  RF_CODE="${out##*$'\n'}"
  RF_BODY="${out%$'\n'*}"
}

# code_to_exit <code>: 0 for 2xx, else the contract exit code.
code_to_exit() {
  case "$1" in
    2??) return 0 ;;
    401 | 403 | 409) return 3 ;;
    404 | 405 | 501) return 5 ;;
    *) return 1 ;;
  esac
}

# rf_check <what>: exit with the mapped code unless the last request was 2xx.
rf_check() {
  local rc=0
  code_to_exit "$RF_CODE" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "$rc" "$1: HTTP $RF_CODE"
  fi
}

find_system() {
  if [[ -n "$RF_SYSTEM_DEFAULT" ]]; then
    RF_SYSTEM="$RF_SYSTEM_DEFAULT"
    return 0
  fi
  rf_req GET /redfish/v1/Systems
  rf_check "list systems"
  RF_SYSTEM="$(jq -r '.Members[0]["@odata.id"] // empty' <<< "$RF_BODY")"
  [[ -n "$RF_SYSTEM" ]] || die 1 "no ComputerSystem found"
}

load_system() {
  find_system
  rf_req GET "$RF_SYSTEM"
  rf_check "read system"
  RF_SYSJSON="$RF_BODY"
}

find_manager_path() {
  if [[ -n "$RF_MANAGER_DEFAULT" ]]; then
    printf '%s' "$RF_MANAGER_DEFAULT"
    return 0
  fi
  rf_req GET /redfish/v1/Managers
  rf_check "list managers"
  jq -r '.Members[0]["@odata.id"] // empty' <<< "$RF_BODY"
}

act_status() {
  local power model serial fw mgr
  load_system
  power="$(jq -r '(.PowerState // "") | ascii_downcase | if . == "on" then "on" elif . == "off" then "off" else "unknown" end' <<< "$RF_SYSJSON")"
  model="$(jq -r '.Model // ""' <<< "$RF_SYSJSON")"
  serial="$(jq -r '.SerialNumber // ""' <<< "$RF_SYSJSON")"
  fw=""
  mgr="$(find_manager_path || true)"
  if [[ -n "$mgr" ]]; then
    rf_req GET "$mgr"
    if [[ "$RF_CODE" == 2?? ]]; then
      fw="$(jq -r '.FirmwareVersion // ""' <<< "$RF_BODY")"
    fi
  fi
  jq -cn --arg power "$power" --arg model "$model" --arg serial "$serial" --arg fw "$fw" \
    '{power: $power, model: $model, serial: $serial, bmc_firmware: $fw}'
}

# reset_target: the ComputerSystem.Reset action URI from the loaded system.
reset_target() {
  local t
  t="$(jq -r '.Actions["#ComputerSystem.Reset"].target // empty' <<< "$RF_SYSJSON")"
  if [[ -z "$t" ]]; then
    t="${RF_SYSTEM%/}/Actions/ComputerSystem.Reset"
  fi
  printf '%s' "$t"
}

# pick_reset_type <candidate...>: the first candidate the system lists in
# ResetType@Redfish.AllowableValues (the first candidate when it lists none).
# Exit 5 when none is allowed.
pick_reset_type() {
  local allowed c
  allowed="$(jq -r '(.Actions["#ComputerSystem.Reset"]["ResetType@Redfish.AllowableValues"] // [])[]' <<< "$RF_SYSJSON")"
  if [[ -z "$allowed" ]]; then
    printf '%s' "$1"
    return 0
  fi
  for c in "$@"; do
    if grep -qx "$c" <<< "$allowed"; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 5
}

do_reset() {
  local rtype rc=0
  rtype="$(pick_reset_type "$@")" || rc=$?
  [[ $rc -eq 0 ]] || die 5 "none of ($*) is an allowed ResetType"
  printf '%s: ComputerSystem.Reset %s\n' "${RF_NAME:-redfish}" "$rtype" >&2
  rf_req POST "$(reset_target)" "$(jq -cn --arg t "$rtype" '{ResetType: $t}')"
  rf_check "ComputerSystem.Reset $rtype"
}

current_power() {
  jq -r '(.PowerState // "") | ascii_downcase' <<< "$RF_SYSJSON"
}

act_power() {
  load_system
  case "$1" in
    on) do_reset On ForceOn ;;
    off) do_reset GracefulShutdown ;;
    force-off) do_reset ForceOff ;;
    reset) do_reset ForceRestart PowerCycle GracefulRestart ;;
    *) die 1 "unknown power action $1" ;;
  esac
}

act_pxe_once() {
  local allowed mode_json target_json
  load_system
  allowed="$(jq -r '(.Boot["BootSourceOverrideTarget@Redfish.AllowableValues"] // [])[]' <<< "$RF_SYSJSON")"
  if [[ -n "$allowed" ]] && ! grep -qx Pxe <<< "$allowed"; then
    die 5 "Pxe is not an allowed BootSourceOverrideTarget"
  fi
  local mode="$RF_PXE_MODE_VALUE"
  if [[ "${BMC_OPT_boot_mode:-}" == bios ]]; then
    mode=Legacy
  fi
  local send_mode=0
  case "$RF_PXE_MODE" in
    send) send_mode=1 ;;
    auto) jq -e '.Boot | has("BootSourceOverrideMode")' <<< "$RF_SYSJSON" > /dev/null && send_mode=1 ;;
    *) send_mode=0 ;;
  esac
  mode_json='{}'
  if [[ $send_mode -eq 1 ]]; then
    mode_json="$(jq -cn --arg m "$mode" '{BootSourceOverrideMode: $m}')"
  fi
  target_json="$(jq -cn --argjson m "$mode_json" '{Boot: ({BootSourceOverrideTarget: "Pxe", BootSourceOverrideEnabled: "Once"} + $m)}')"
  printf '%s: one-time boot override -> PXE\n' "${RF_NAME:-redfish}" >&2
  rf_req PATCH "$RF_SYSTEM" "$target_json"
  rf_check "boot override"
  if [[ "$(current_power)" == on ]]; then
    do_reset ForceRestart PowerCycle GracefulRestart
  else
    do_reset On ForceOn
  fi
}

act_identify() {
  load_system
  local body
  if jq -e 'has("LocationIndicatorActive")' <<< "$RF_SYSJSON" > /dev/null; then
    body='{"LocationIndicatorActive":true}'
  elif jq -e 'has("IndicatorLED")' <<< "$RF_SYSJSON" > /dev/null; then
    body='{"IndicatorLED":"Blinking"}'
  else
    die 5 "no indicator LED property on the system"
  fi
  rf_req PATCH "$RF_SYSTEM" "$body"
  rf_check "identify"
}

rf_main() {
  local action="${1:-}"
  case "$action" in
    status | on | off | force-off | reset | pxe-once | identify) ;;
    *) die 1 "usage: <driver> status|on|off|force-off|reset|pxe-once|identify" ;;
  esac
  read_credential
  case "$action" in
    status) act_status ;;
    pxe-once) act_pxe_once ;;
    identify) act_identify ;;
    *) act_power "$action" ;;
  esac
}
