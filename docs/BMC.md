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

## Driver contract

A driver is one executable `lib/bmc/drivers/<name>` (bash; core tools only:
`curl`, `jq`, `ipmitool`), called as `<driver> <action>`.

- Target: environment `BMC_ADDR` (address, with a port if needed), `BMC_HOST`
  (the host's MAC), `BMC_DRIVER`, and one `BMC_OPT_<name>` per option.
- Credential: stdin, two lines (user, password). Never argv, never logged. The
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
| `hpe-ilo` | HPE iLO 4 and later | Redfish, proven in the lab (`lab/ilo.sh`): system `/redfish/v1/Systems/1/`, every path with a trailing slash, the one-time boot override sends UEFI mode (`BMC_OPT_boot_mode=bios` sends Legacy) |
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
4. Test it with PATH shims for `curl` or `ipmitool` as in
   `scripts/tests/test_p3_97_bmc_drivers.bats`: canned answers, an argv record,
   and an assertion that the credential is in no argv.

## Not proven live

Everything here is tested against shims, not hardware. In particular the
`hpe-ilo` driver has not yet run against the real iLO through `hps-bmc` (the lab
chains still use `lab/ilo.sh`); `dell-idrac`, `ipmi` and `external` have never
met a real device; the audit's `ipmitool` and DMI collection has not run on the
DL360, and the audit image build is not checked here.
