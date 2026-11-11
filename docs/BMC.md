# Out-of-band power control (BMC)

The IPS drives power on every host through one contract and a set of drivers.
The audit identifies which driver a device needs; the operator can override it
(a switched PDU outlet, for instance). Filing IPS-08.

```
hps-bmc <action> <host>
        |
   HPS::BMC  -- registry: bmc_driver, bmc_addr, bmc_options, power_devices
        |    -- keysafe:  credential (host or power device)
        v
   lib/bmc/drivers/<driver> <action>      env: BMC_ADDR BMC_OPT_*   stdin: user, password
```

The IPS reaches BMCs on the BMC network (`purpose = bmc`, IPS only; nodes
never get an interface there).

## CLI

```
hps-bmc status|on|off|force-off|reset|pxe-once|identify <host> [--json]
hps-bmc console <host> [--seconds N]
hps-bmc set <host> --driver NAME|auto [--addr A] [--option k=v]...
hps-bmc credential <host|device:NAME> [--user U]
hps-bmc device set <name> [--addr A] [--option k=v]... | list | delete <name>
hps-bmc select <host>
hps-bmc list [--json]
```

`<host>` is a MAC in any format or a registry `HOSTNAME`.

Exit codes of the actions (the contract IPS-04 and the lab chains rely on):

| Exit | Meaning |
|---|---|
| 0 | ok |
| 3 | refused (credential refused, or the BMC refuses the action in this state) |
| 4 | target unreachable (retried, see below) |
| 5 | not supported by this device, or no driver recorded: the caller escalates |
| 1 | failed |
| 2 | usage error of the CLI itself |

`status --json` prints `{"power":"on|off|unknown","model","serial","bmc_firmware"}`.
`off` is a graceful shutdown, `force-off` is the hard power cut (the fence
action), `reset` is a hard restart, `pxe-once` makes the next boot come from the
network once and then powers the host on (or restarts it when it is on),
`identify` lights the chassis LED.
`console` (see "Console" below) attaches to the serial console.

## Driver contract

A driver is one executable `lib/bmc/drivers/<name>` (bash; core tools only:
`curl`, `jq`, `ipmitool`), called as `<driver> <action>`.

- Target: environment `BMC_ADDR` (address, with a port if needed), `BMC_HOST`
  (the host's MAC), `BMC_DRIVER`, and one `BMC_OPT_<name>` per option.
- Credential: stdin, two lines (user, password). Never argv, never logged. The
  `console` action is the exception: stdin carries keystrokes, so the credential
  arrives on file descriptor 3 (same two lines). The
  controller starts the driver with a clean environment (plus `PATH`).
- stdout: only `status` prints (the JSON above). Messages go to stderr.
- Exit codes as in the table above. A driver that cannot do an action exits 5.

The Redfish drivers pass the credential to `curl` through a config on its stdin
(`-K -`), `ipmi` passes the password in `IPMI_PASSWORD` (`-E`), `external` passes
the credential to the PDU command's stdin. The IPMI user name does appear in the
`ipmitool` argv (ipmitool offers no other way); the password never does.

## Drivers

| Driver | Device | Notes |
|---|---|---|
| `hpe-ilo` | HPE iLO 4 and later | Redfish, console by ssh VSP, proven in the lab through `hps-bmc`: system `/redfish/v1/Systems/1/`, every path with a trailing slash, the one-time boot override sends UEFI mode (`BMC_OPT_boot_mode=bios` sends Legacy) |
| `redfish-generic` | any DMTF Redfish BMC | system and manager discovered from the collections; `ResetType` taken from `@Redfish.AllowableValues` (candidates in order: on `On ForceOn`; off `GracefulShutdown`; force-off `ForceOff`; reset `ForceRestart PowerCycle GracefulRestart`); the boot mode is sent only when the system has that property; `Pxe` must be an allowed override target |
| `dell-idrac` | Dell iDRAC | Redfish with the iDRAC paths (`System.Embedded.1`, `iDRAC.Embedded.1`); the boot override sends no mode. Written to the contract and unproven until a Dell is in the lab |
| `ipmi` | IPMI-only devices | `ipmitool -I lanplus` (`BMC_OPT_interface` overrides); `off` is `chassis power soft`; `pxe-once` is `chassis bootdev pxe options=efiboot` then power on or reset |
| `external` | switched PDU outlet, smart plug | see below; `pxe-once` and `identify` exit 5, the node relies on network-first boot order |
| `manual` | nothing automatable | every action logs an operator instruction and exits 5 |

Redfish options: `tls_verify=yes` verifies the BMC certificate (default: BMCs
carry self-signed certificates, so verification is off), `timeout` (seconds,
default 20), `boot_mode`.

### The external driver

A power device (PDU, smart plug) is a cluster-level object so several hosts
share one:

```
hps-bmc device set pdu1 --addr $PDU_ADDR --option 'cmd=pdu-ctl --host {addr} --outlet {outlet} {action}'
hps-bmc credential device:pdu1 < user-and-password
hps-bmc set $HOST --driver external --option outlet=pdu1:7
```

The `cmd` template is split on spaces and run without a shell; `{addr}` is the
device address, `{outlet}` the number after `pdu1:`, `{action}` is `on`, `off`
or `status`. The command prints `on` or `off` for `status`, reads the
credential on stdin, and exits 0, or 3/4/5/1 as the contract says. `reset`
cycles the outlet (`off`, `BMC_OPT_cycle_delay` seconds, default 5, `on`).
A device still used by a host cannot be deleted.

## Console

`hps-bmc console <host> [--seconds N]` attaches to the machine's serial console.
N is an integer from 1 to 3600 (default 600; anything else is a usage error,
exit 2). Stdin is passed through as keystrokes (a newline becomes Enter, CR),
console output goes to stdout, and the session ends after N seconds or when the
far end closes, then detaches cleanly (the driver's leave sequence). It is not
retried. Exit codes are the contract's: 0 ok, 3 refused (credential or a
changed host key), 4 unreachable, 5 no console on this device, 1 failed, 2
usage. Every use is logged like the other actions
(`action=console host=... driver=... exit=... seconds=...`), never content.

The controller starts the driver as `<driver> console` with the credential on
file descriptor 3, the time limit in `BMC_CONSOLE_SECONDS` and the per-BMC
known_hosts path in `BMC_KNOWN_HOSTS`. The password reaches the tool only
through its environment (`SSHPASS`, `IPMI_PASSWORD`), never argv, output or log.

| Driver | Console |
|---|---|
| `hpe-ilo` | iLO Virtual Serial Port over ssh (below) |
| `ipmi` | `ipmitool -I lanplus -H <addr> -U <user> -E sol activate`, bounded by `timeout`, then `sol deactivate` (also after the timeout) |
| `redfish-generic` | exit 5, unless the host option `console=ssh-vsp` is set: then the `hpe-ilo` method |
| `dell-idrac`, `external`, `manual` | exit 5 with a one-line reason |

The ssh VSP method (`lib/bmc/console-common.sh`, shared by `hpe-ilo` and
`redfish-generic`) runs

```
timeout -k 5 <N+15> script -q -f -e -c '<ssh command>' /dev/null
ssh command: sshpass -e ssh -tt -E <errfile> \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<cluster>/bmc/known_hosts-<mac> \
  -o GlobalKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa \
  -o PubkeyAcceptedAlgorithms=+ssh-rsa -o KexAlgorithms=+diffie-hellman-group14-sha1 \
  -o ConnectTimeout=15 -o NumberOfPasswordPrompts=1 <user>@<BMC_ADDR>
```

The ssh options are what iLO 4 needs. `script` gives sshpass a pty (sshpass
segfaults when its stdin is a pipe). The driver feeds the session `vsp` after
a settle (option `console_settle`, default 4 seconds, for the CLP banner), then
the caller's keystrokes, then at the limit `ESC (` (leaves the VSP) and `exit`.
The VSP drops over-long input lines: send short lines.

The host key is pinned per BMC in `<cluster>/bmc/known_hosts-<mac12>` (mode
0700 directory): accepted on first use, refused (exit 3) if it later changes.
Console needs `openssh-client`, `sshpass` and `script` (util-linux) in the IPS
image for the ssh method and `ipmitool` for `ipmi`.

## Selection by the audit

The audit image (`hps-audit`) records the BMC identity under `bmc` in the
`hps-audit/1` document: `ipmitool lan print` (BMC MAC, IP source, IP) and
`ipmitool mc info` (manufacturer ID, product ID, firmware) when a local IPMI
(KCS) device node exists, and the count of DMI type 38 (IPMI device) and type 42
(management controller host interface, i.e. Redfish) entries. The image loads
`ipmi_si` and `ipmi_devintf` and carries `ipmitool`. These are read-only queries.

After the audit is stored (`host_audit_intake`), `hps-bmc select <host>` runs
the ordered rule table `lib/bmc/drivers.map`: the first rule whose conditions
all match wins. Conditions are regular expressions (case-insensitive) on
`vendor` (`dmi.sys_vendor`), `product` (`dmi.product_name`),
`mc_manufacturer_id`, `redfish_host_if` and `ipmi`. The shipped table:

```
hpe-ilo          vendor=^(HP|HPE|Hewlett.Packard.*)$  product=ProLiant|Synergy|Apollo|Edgeline
hpe-ilo          mc_manufacturer_id=^11$
dell-idrac       vendor=^Dell
dell-idrac       mc_manufacturer_id=^674$
redfish-generic  redfish_host_if=^true$
ipmi             ipmi=^true$
manual
```

The lab DL360 reports `sys_vendor = HP` and `product_name = ProLiant DL360 Gen9`
and so selects `hpe-ilo`. The result is recorded as host keys `bmc_driver`,
`bmc_driver_source = audit`, `bmc_addr` (the address `lan print` reported; unset
when none) and `bmc_evidence` (the facts and the rule line used). A failure of
the selection is logged and never fails the audit intake.

## Override

`hps-bmc set <host> --driver NAME [--addr A] [--option k=v]` records the choice
with `bmc_driver_source = operator`. An operator choice is never replaced by a
later audit (`select` reports "operator choice kept"). `--driver auto` hands the
choice back to the audit and clears the options. Options are merged on repeated
`set` for the same driver and stored as `bmc_options`.

## Credentials

In the keysafe (`HPS::Keysafe` secrets, `keysafe/credentials/<name>.cred`, mode
0600 in a 0700 directory), named by the host's MAC (12 hex digits) or
`device-<name>` for a power device. `hps-bmc credential <host|device:NAME>`
reads the user line then the password line from stdin (with `--user U`, stdin is
the password only). Credentials are never in the registry, an image, a log or
an argv. Output of a driver is scrubbed of the password as a second line of
defence.

## Controller behaviour

`HPS::BMC->run($host, $action)` resolves the driver, hands over the credential,
and applies the retry policy: exit 4 is retried (4 tries, 20 seconds apart, so a
host reboot window of 60 seconds is covered); exits 3 and 5 are never retried.
Every call goes to syslog (`hps-bmc: action=... host=... driver=... exit=...
tries=...`), never with the credential. The last call is kept as host key
`bmc_last`. `HPS_BMC_RETRY_DELAY` (seconds) overrides the 20 s wait; the driver
environment is clean except `PATH`, and `HPS_BMC_ENV_PASS` names extra
variables to pass (a test and lab aid).

## Registry keys

Host: `bmc_driver`, `bmc_driver_source`, `bmc_addr`, `bmc_options`,
`bmc_evidence`, `bmc_last`. Cluster: `power_devices`. See
`docs/REGISTRY-KEYS.md`.

## Adding a driver

1. Write `lib/bmc/drivers/<name>` (bash, `#!/usr/bin/env bash`, `set -euo
   pipefail`, shellcheck clean) to the contract above. A Redfish device that
   differs from the standard only in paths or boot-override payloads can set the
   quirk variables documented at the top of `lib/bmc/redfish-common.sh` and call
   `rf_main` (see `hpe-ilo`, `dell-idrac`).
2. Make it executable. `hps-bmc set` finds it by name.
3. To have the audit choose it, add a rule to `lib/bmc/drivers.map` before the
   catch-all, and a case to `t/97-bmc.t`.
4. A driver without a console exits 5 for `console`; one with a console reads
   the credential from fd 3 and honours `BMC_CONSOLE_SECONDS` (see "Console").
5. Test it with PATH shims for `curl` or `ipmitool` as in
   `scripts/tests/test_p3_97_bmc_drivers.bats`: canned answers, an argv record,
   and an assertion that the credential is in no argv. The console shims are in
   `scripts/tests/test_p3_163_bmc_console.bats`.

## Proven live, and not

The `hpe-ilo` driver is proven on a real DL360 Gen9 (iLO 4 v2.76) through
`hps-bmc` (IPS-08 close-out, `inbox/archive/2026-11-11-IPS-08-modular-bmc-control.md`):
`status` in every lab chain since run 13; `pxe-once` in runs 14 to 17; `off`,
`on` and `force-off` in runs 16 and 17; `console` in run 17 (the serial console
captured to the NixOS login). `hps-node power-off` found `hps-bmc` beside it in
run 15. The credential is in the keysafe only; `lab/ilo.sh` and
`lab/secrets/ilo` are deleted, and the lab console tools call `hps-bmc console`.

Tested against shims only, never against a real device: the `ipmi`, `external`
and `redfish-generic` drivers, and `dell-idrac`. `ipmi` cannot be used with the
DL360 because its iLO password exceeds IPMI 2.0's 20-byte limit. The audit's
`ipmitool` and DMI collection has not run on the DL360, and the audit image
build is not checked here.
