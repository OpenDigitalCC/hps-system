#!/usr/bin/env bats
#
# IPS-08: the BMC driver contract (lib/bmc/drivers/*). curl, ipmitool and the PDU
# command are PATH shims (scripts/tests/p3_97_helpers.bash) serving canned
# answers. Proves, per driver: the actions and their exit codes (0 ok, 3
# refused, 4 unreachable, 5 not supported, 1 failed), the status JSON, and that
# the credential never appears in argv or in a driver's output.

bats_require_minimum_version 1.5.0

setup() {
  load p3_97_helpers
  p97_setup
}

teardown() {
  p97_teardown
}

ilo_system() {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"'"${1:-On}"'","Model":"ProLiant DL360 Gen9","SerialNumber":"SER123","Boot":{"BootSourceOverrideEnabled":"Disabled","BootSourceOverrideSupported":["None","Cd","Hdd","Usb","Pxe","UefiShell","UefiTarget"],"BootSourceOverrideTarget":"None"},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart","Nmi","PushPowerButton"]}}}'
  p97_fix GET /redfish/v1/Managers/1/ '{"FirmwareVersion":"iLO 4 v2.55"}'
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}'
  p97_fix PATCH /redfish/v1/Systems/1/ '{}'
}

# --- hpe-ilo ------------------------------------------------------------------

@test "hpe-ilo status prints the contract JSON" {
  ilo_system On
  p97_run_driver hpe-ilo status
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<< "$output")" = '{"power":"on","model":"ProLiant DL360 Gen9","serial":"SER123","bmc_firmware":"iLO 4 v2.55"}' ]
}

@test "hpe-ilo status reports off" {
  ilo_system Off
  p97_run_driver hpe-ilo status
  [ "$status" -eq 0 ]
  [ "$(jq -r .power <<< "$output")" = off ]
}

@test "hpe-ilo status maps an unrecognised PowerState to unknown" {
  ilo_system PoweringOn
  p97_run_driver hpe-ilo status
  [ "$(jq -r .power <<< "$output")" = unknown ]
}

@test "hpe-ilo on off force-off reset post the Reset action the lab proved" {
  ilo_system Off
  p97_run_driver hpe-ilo on
  [ "$status" -eq 0 ]
  ilo_system On
  p97_run_driver hpe-ilo off
  [ "$status" -eq 0 ]
  p97_run_driver hpe-ilo force-off
  [ "$status" -eq 0 ]
  p97_run_driver hpe-ilo reset
  [ "$status" -eq 0 ]
  grep -qF 'POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ {"ResetType":"On"}' "$CALLS_LOG"
  grep -qF '{"ResetType":"GracefulShutdown"}' "$CALLS_LOG"
  grep -qF '{"ResetType":"ForceOff"}' "$CALLS_LOG"
  grep -qF '{"ResetType":"ForceRestart"}' "$CALLS_LOG"
}

@test "hpe-ilo pxe-once on iLO 4: one-time PXE override without BootSourceOverrideMode, then restart" {
  ilo_system On
  p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  grep -qF 'PATCH /redfish/v1/Systems/1/ {"Boot":{"BootSourceOverrideTarget":"Pxe","BootSourceOverrideEnabled":"Once"}}' "$CALLS_LOG"
  run grep -F 'BootSourceOverrideMode' "$CALLS_LOG"
  [ "$status" -eq 1 ]
  grep -qF '{"ResetType":"ForceRestart"}' "$CALLS_LOG"
}

@test "hpe-ilo pxe-once on a later iLO that lists BootSourceOverrideMode sends UEFI mode" {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"Off","Model":"ProLiant DL380 Gen10","SerialNumber":"SER9","Boot":{"BootSourceOverrideMode":"UEFI","BootSourceOverrideTarget":"None"},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart"]}}}'
  p97_fix GET /redfish/v1/Managers/1/ '{"FirmwareVersion":"iLO 5 v2.90"}'
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}'
  p97_fix PATCH /redfish/v1/Systems/1/ '{}'
  p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  grep -qF '"BootSourceOverrideMode":"UEFI"' "$CALLS_LOG"
}

@test "hpe-ilo pxe-once powers a stopped host on" {
  ilo_system Off
  p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  grep -qF '{"ResetType":"On"}' "$CALLS_LOG"
  run ! grep -qF 'ForceRestart' "$CALLS_LOG"
}

@test "hpe-ilo uses a trailing slash on every path" {
  ilo_system On
  p97_run_driver hpe-ilo status
  [ "$status" -eq 0 ]
  run ! grep -E '^GET [^ ]*[^/] $' "$CALLS_LOG"
}

@test "hpe-ilo refuses a wrong credential with exit 3" {
  ilo_system On
  run env BMC_ADDR=bmc.example.invalid bash -c 'printf "admin-test\nwrong\n" | "$0" status' "$DRIVERS/hpe-ilo"
  [ "$status" -eq 3 ]
}

@test "hpe-ilo exits 3 without a credential on stdin" {
  run env BMC_ADDR=bmc.example.invalid bash -c '"$0" status < /dev/null' "$DRIVERS/hpe-ilo"
  [ "$status" -eq 3 ]
}

@test "hpe-ilo exits 4 when the BMC is unreachable" {
  ilo_system On
  p97_run_driver hpe-ilo status FAKE_CURL_RC=7
  [ "$status" -eq 4 ]
}

@test "hpe-ilo exits 3 when the BMC answers 409 to an action" {
  ilo_system Off
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{"error":{}}' 409
  p97_run_driver hpe-ilo on
  [ "$status" -eq 3 ]
}

@test "hpe-ilo exits 5 when the action target is not found" {
  ilo_system Off
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}' 404
  p97_run_driver hpe-ilo on
  [ "$status" -eq 5 ]
}

@test "hpe-ilo exits 5 for a ResetType the system does not allow" {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"On","Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On"]}}}'
  p97_run_driver hpe-ilo force-off
  [ "$status" -eq 5 ]
}

@test "hpe-ilo exits 1 on a server error" {
  ilo_system Off
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}' 500
  p97_run_driver hpe-ilo on
  [ "$status" -eq 1 ]
}

@test "hpe-ilo identify exits 5 when the system has no indicator LED" {
  ilo_system On
  p97_run_driver hpe-ilo identify
  [ "$status" -eq 5 ]
}

@test "hpe-ilo identify blinks the IndicatorLED when present" {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"On","IndicatorLED":"Off"}'
  p97_fix PATCH /redfish/v1/Systems/1/ '{}'
  p97_run_driver hpe-ilo identify
  [ "$status" -eq 0 ]
  grep -qF '{"IndicatorLED":"Blinking"}' "$CALLS_LOG"
}

@test "the credential reaches curl on stdin only, never argv, never output" {
  ilo_system On
  p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  p97_no_credential_in "$SHIM_LOG"
  p97_no_credential_in "$CALLS_LOG"
  [[ "$output" != *"$P97_PASS"* ]]
  run ! grep -qF -- "$P97_USER" "$SHIM_LOG"
  grep -qF -- '-K -' "$SHIM_LOG"
}

@test "a hostile password cannot break out of the curl config" {
  ilo_system On
  run env BMC_ADDR=bmc.example.invalid bash -c 'printf "admin-test\n%s\n" "$P97_PASS" | "$0" status' "$DRIVERS/hpe-ilo"
  [ "$status" -eq 0 ]
}

# --- redfish-generic ----------------------------------------------------------

generic_system() {
  p97_fix GET /redfish/v1/Systems '{"Members":[{"@odata.id":"/redfish/v1/Systems/Sys.A"}]}'
  p97_fix GET /redfish/v1/Managers '{"Members":[{"@odata.id":"/redfish/v1/Managers/BMC"}]}'
  p97_fix GET /redfish/v1/Managers/BMC '{"FirmwareVersion":"1.2.3"}'
  p97_fix GET /redfish/v1/Systems/Sys.A '{"PowerState":"'"${1:-On}"'","Model":"Gen X","SerialNumber":"S9","Boot":{"BootSourceOverrideTarget@Redfish.AllowableValues":["None","Pxe","Hdd"]},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/Sys.A/Actions/ComputerSystem.Reset","ResetType@Redfish.AllowableValues":["On","ForceOff","PowerCycle","GracefulShutdown"]}}}'
  p97_fix POST /redfish/v1/Systems/Sys.A/Actions/ComputerSystem.Reset '{}' 204
  p97_fix PATCH /redfish/v1/Systems/Sys.A '{}'
}

@test "redfish-generic discovers the system and manager for status" {
  generic_system On
  p97_run_driver redfish-generic status
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<< "$output")" = '{"power":"on","model":"Gen X","serial":"S9","bmc_firmware":"1.2.3"}' ]
}

@test "redfish-generic picks the ResetType from AllowableValues (reset falls to PowerCycle)" {
  generic_system On
  p97_run_driver redfish-generic reset
  [ "$status" -eq 0 ]
  grep -qF '{"ResetType":"PowerCycle"}' "$CALLS_LOG"
  run ! grep -qF 'ForceRestart' "$CALLS_LOG"
}

@test "redfish-generic exits 5 when no candidate ResetType is allowed" {
  generic_system On
  p97_fix GET /redfish/v1/Systems/Sys.A '{"PowerState":"On","Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/Sys.A/Actions/ComputerSystem.Reset","ResetType@Redfish.AllowableValues":["Nmi"]}}}'
  p97_run_driver redfish-generic off
  [ "$status" -eq 5 ]
}

@test "redfish-generic pxe-once omits the mode when the system has no such property" {
  generic_system Off
  p97_run_driver redfish-generic pxe-once
  [ "$status" -eq 0 ]
  grep -qF 'PATCH /redfish/v1/Systems/Sys.A {"Boot":{"BootSourceOverrideTarget":"Pxe","BootSourceOverrideEnabled":"Once"}}' "$CALLS_LOG"
  grep -qF '{"ResetType":"On"}' "$CALLS_LOG"
}

@test "redfish-generic pxe-once exits 5 when Pxe is not an allowed target" {
  generic_system On
  p97_fix GET /redfish/v1/Systems/Sys.A '{"PowerState":"On","Boot":{"BootSourceOverrideTarget@Redfish.AllowableValues":["None","Hdd"]}}'
  p97_run_driver redfish-generic pxe-once
  [ "$status" -eq 5 ]
}

@test "redfish-generic exits 1 for an unknown action" {
  generic_system On
  p97_run_driver redfish-generic explode
  [ "$status" -eq 1 ]
}

# --- dell-idrac ---------------------------------------------------------------

@test "dell-idrac uses the iDRAC paths and sends no boot mode" {
  p97_fix GET /redfish/v1/Systems/System.Embedded.1 '{"PowerState":"On","Model":"PowerEdge","SerialNumber":"D1","Boot":{"BootSourceOverrideMode":"UEFI"},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset","ResetType@Redfish.AllowableValues":["On","ForceOff","GracefulShutdown","ForceRestart"]}}}'
  p97_fix GET /redfish/v1/Managers/iDRAC.Embedded.1 '{"FirmwareVersion":"7.00.00"}'
  p97_fix PATCH /redfish/v1/Systems/System.Embedded.1 '{}'
  p97_fix POST /redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset '{}'
  p97_run_driver dell-idrac status
  [ "$status" -eq 0 ]
  [ "$(jq -r .bmc_firmware <<< "$output")" = 7.00.00 ]
  p97_run_driver dell-idrac pxe-once
  [ "$status" -eq 0 ]
  grep -qF 'PATCH /redfish/v1/Systems/System.Embedded.1 {"Boot":{"BootSourceOverrideTarget":"Pxe","BootSourceOverrideEnabled":"Once"}}' "$CALLS_LOG"
}

# --- ipmi ---------------------------------------------------------------------

@test "ipmi status reads power, firmware, model and serial" {
  p97_run_driver ipmi status
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<< "$output")" = '{"power":"on","model":"ProLiant DL360 Gen9","serial":"SER123","bmc_firmware":"2.55"}' ]
}

@test "ipmi actions map to chassis commands" {
  p97_run_driver ipmi on
  [ "$status" -eq 0 ]
  p97_run_driver ipmi off
  [ "$status" -eq 0 ]
  p97_run_driver ipmi force-off
  [ "$status" -eq 0 ]
  p97_run_driver ipmi reset
  [ "$status" -eq 0 ]
  p97_run_driver ipmi identify
  [ "$status" -eq 0 ]
  grep -qF 'chassis power on' "$SHIM_LOG"
  grep -qF 'chassis power soft' "$SHIM_LOG"
  grep -qF 'chassis power off' "$SHIM_LOG"
  grep -qF 'chassis power reset' "$SHIM_LOG"
  grep -qF 'chassis identify 15' "$SHIM_LOG"
}

@test "ipmi pxe-once sets the boot device then resets a running host" {
  FAKE_IPMI_POWER=on p97_run_driver ipmi pxe-once FAKE_IPMI_POWER=on
  [ "$status" -eq 0 ]
  grep -qF 'chassis bootdev pxe options=efiboot' "$SHIM_LOG"
  grep -qF 'chassis power reset' "$SHIM_LOG"
}

@test "ipmi pxe-once powers a stopped host on" {
  p97_run_driver ipmi pxe-once FAKE_IPMI_POWER=off
  [ "$status" -eq 0 ]
  grep -qF 'chassis power on' "$SHIM_LOG"
}

@test "ipmi passes the password in the environment, never argv" {
  p97_run_driver ipmi status
  [ "$status" -eq 0 ]
  p97_no_credential_in "$SHIM_LOG"
  grep -qF 'IPMI_PASSWORD_SET=yes' "$SHIM_LOG"
  grep -qF -- ' -E ' "$SHIM_LOG"
}

@test "ipmi exit 4 when the session cannot be established" {
  p97_run_driver ipmi status FAKE_IPMI_ERR="Error: Unable to establish IPMI v2 / RMCP+ session"
  [ "$status" -eq 4 ]
}

@test "ipmi exit 3 when the credential is refused" {
  p97_run_driver ipmi status FAKE_IPMI_ERR="Error: Unauthorized name"
  [ "$status" -eq 3 ]
}

@test "ipmi exits 3 without a credential" {
  run env BMC_ADDR=x bash -c '"$0" status < /dev/null' "$DRIVERS/ipmi"
  [ "$status" -eq 3 ]
}

# --- external -----------------------------------------------------------------

PDU_TEMPLATE='pdu-ctl --host {addr} --outlet {outlet} {action}'

@test "external status reads the PDU command" {
  p97_run_driver external status "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 0 ]
  [ "$(jq -r .power <<< "$output")" = on ]
  grep -qF 'pdu-ctl --host bmc.example.invalid --outlet 7 status' "$SHIM_LOG"
}

@test "external status reports off" {
  p97_run_driver external status "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7 FAKE_PDU_STATE=off
  [ "$(jq -r .power <<< "$output")" = off ]
}

@test "external on, off and force-off call the PDU" {
  p97_run_driver external on "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 0 ]
  p97_run_driver external force-off "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 0 ]
  grep -qF 'outlet 7 on' "$SHIM_LOG"
  grep -qF 'outlet 7 off' "$SHIM_LOG"
}

@test "external reset cycles the outlet off then on" {
  p97_run_driver external reset "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7 BMC_OPT_cycle_delay=0
  [ "$status" -eq 0 ]
  run grep -n 'pdu-ctl' "$SHIM_LOG"
  [[ "${lines[0]}" == *"outlet 7 off" ]]
  [[ "${lines[1]}" == *"outlet 7 on" ]]
}

@test "external pxe-once and identify exit 5" {
  p97_run_driver external pxe-once "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 5 ]
  p97_run_driver external identify "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 5 ]
}

@test "external hands the credential to the PDU command on stdin, never argv" {
  p97_run_driver external on "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7
  [ "$status" -eq 0 ]
  p97_no_credential_in "$SHIM_LOG"
  [ "$(head -n1 "$TEST_DIR/pdu-stdin")" = "$P97_USER" ]
  [ "$(sed -n 2p "$TEST_DIR/pdu-stdin")" = "$P97_PASS" ]
}

@test "external passes a PDU exit 4 through" {
  p97_run_driver external on "BMC_OPT_cmd=$PDU_TEMPLATE" BMC_OPT_outlet=7 FAKE_PDU_RC=4
  [ "$status" -eq 4 ]
}

@test "external exits 1 without a template or outlet" {
  p97_run_driver external on BMC_OPT_outlet=7
  [ "$status" -eq 1 ]
  p97_run_driver external on "BMC_OPT_cmd=$PDU_TEMPLATE"
  [ "$status" -eq 1 ]
}

@test "external never evaluates the template through a shell" {
  p97_run_driver external on "BMC_OPT_cmd=pdu-ctl ;touch$IFS$TEST_DIR/pwned {action}" BMC_OPT_outlet=7
  [ ! -e "$TEST_DIR/pwned" ]
}

# --- manual -------------------------------------------------------------------

@test "manual logs an instruction and exits 5 for every action" {
  local a
  for a in on off force-off reset pxe-once identify; do
    p97_run_driver manual "$a"
    [ "$status" -eq 5 ]
    [[ "$output" == *"operator"* ]]
  done
}

@test "manual status prints an unknown power state and exits 5" {
  run --separate-stderr env BMC_HOST=host1 "$DRIVERS/manual" status
  [ "$status" -eq 5 ]
  [ "$(jq -r .power <<< "$output")" = unknown ]
}

# --- all drivers ----------------------------------------------------------------

@test "every driver is executable, shellcheck clean and takes core tools only" {
  local d
  for d in "$DRIVERS"/*; do
    [ -x "$d" ]
    shellcheck -S warning -x "$d"
    run grep -vE '^[[:space:]]*#' "$d"
    [[ ! "$output" =~ (python|perl|ruby|wget|ssh) ]]
  done
  shellcheck -S warning -x "$ROOT/lib/bmc/redfish-common.sh"
}

@test "hpe-ilo pxe-once with pxe_uefi_target overrides to that UEFI boot device" {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"Off","Model":"ProLiant DL360 Gen9","SerialNumber":"S","Boot":{"BootSourceOverrideSupported":["None","Pxe","UefiTarget"],"UefiTargetBootSourceOverrideSupported":["NIC.LOM.1.1.IPv4","NIC.FlexLOM.1.1.IPv4"]},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","ForceRestart"]}}}'
  p97_fix GET /redfish/v1/Managers/1/ '{"FirmwareVersion":"iLO 4 v2.76"}'
  p97_fix POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset/ '{}'
  p97_fix PATCH /redfish/v1/Systems/1/ '{}'
  BMC_OPT_pxe_uefi_target=NIC.FlexLOM.1.1.IPv4 p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  # device first, then the override (iLO 4 refuses both in one request)
  first=$(grep -n -F '{"Boot":{"UefiTargetBootSourceOverride":"NIC.FlexLOM.1.1.IPv4"}}' "$CALLS_LOG" | head -1 | cut -d: -f1)
  second=$(grep -n -F '{"Boot":{"BootSourceOverrideTarget":"UefiTarget","BootSourceOverrideEnabled":"Once"}}' "$CALLS_LOG" | head -1 | cut -d: -f1)
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
  grep -qF '{"ResetType":"On"}' "$CALLS_LOG"
}

@test "hpe-ilo pxe-once refuses a pxe_uefi_target the system does not list (exit 3, nothing sent)" {
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"Off","Model":"ProLiant DL360 Gen9","SerialNumber":"S","Boot":{"UefiTargetBootSourceOverrideSupported":["NIC.LOM.1.1.IPv4"]},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/"}}}'
  p97_fix GET /redfish/v1/Managers/1/ '{"FirmwareVersion":"iLO 4 v2.76"}'
  BMC_OPT_pxe_uefi_target=NIC.FlexLOM.1.1.IPv4 p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 3 ]
  run grep -E '^(PATCH|POST) ' "$CALLS_LOG"
  [ "$status" -eq 1 ]
}

@test "pxe_override=boot-order: no PATCH, only power on" {
  ilo_system Off
  BMC_OPT_pxe_override=boot-order p97_run_driver hpe-ilo pxe-once
  [ "$status" -eq 0 ]
  run grep -E '^PATCH ' "$CALLS_LOG"
  [ "$status" -eq 1 ]
  grep -qF '{"ResetType":"On"}' "$CALLS_LOG"
}

@test "hpe-ilo off on iLO 4 (no GracefulShutdown): PushPowerButton; Off and On states left alone" {
  ilo_system On
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"On","Model":"ProLiant DL360 Gen9","SerialNumber":"SER123","Boot":{"BootSourceOverrideSupported":["None","Pxe","UefiTarget"]},"Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","ForceRestart","Nmi","PushPowerButton"]}}}'
  p97_run_driver hpe-ilo off
  [ "$status" -eq 0 ]
  grep -qF '{"ResetType":"PushPowerButton"}' "$CALLS_LOG"
  : > "$CALLS_LOG"
  p97_run_driver hpe-ilo on
  [ "$status" -eq 0 ]
  run grep -q 'ComputerSystem.Reset' "$CALLS_LOG"
  [ "$status" -ne 0 ]
  p97_fix GET /redfish/v1/Systems/1/ '{"PowerState":"Off","Actions":{"#ComputerSystem.Reset":{"target":"/redfish/v1/Systems/1/Actions/ComputerSystem.Reset/","ResetType@Redfish.AllowableValues":["On","ForceOff","PushPowerButton"]}}}'
  : > "$CALLS_LOG"
  p97_run_driver hpe-ilo off
  [ "$status" -eq 0 ]
  run grep -q 'ComputerSystem.Reset' "$CALLS_LOG"
  [ "$status" -ne 0 ]
}
