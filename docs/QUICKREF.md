---
title: "HPS Quick Reference"
subtitle: "Quickstart and command reference for the operator tools"
brand: plain
---

# About this page

This is the first, short manual: a quickstart and a command reference for the
operator tools in `bin/`. The fuller manuals follow once the design settles.
Every form below comes from the tool's own usage text, `docs/OPERATOR.md` or
`docs/WORKLOADS.md`; the linked docs hold the detail.

Example names are generic: host `sch-001` (a storage host), `tch-001` (a
compute host), workload `web-1`, project `demo`, credential file `FILE`.

Run a tool on the IPS as root, or from an operator machine through
`hps-op --cred FILE <tool> [args...]`. The exit status is the tool's own.

`<host>` is a MAC address in any format or a registry hostname.

# Quickstart

From an IPS to a running workload. Each step is one command.

## Onboard a node

Audit
: The node boots from the IPS, posts its hardware audit and waits at iPXE.
  Nothing to type.

Held
: `hps-onboard list` – lists the held hosts. `hps-onboard show <mac>` shows one
  host's audit.

Assign
: `hps-onboard assign <mac> --type TCH --profile NAME --os arch:name:version --pin PIN`
  – gives the held host its role, profile, OS and image pin. A storage host
  takes `--type SCH`.

Pair
: Boot the assigned node again. It converges on its first boot and the IPS
  pairs it by itself after each boot. `hps-onboard list --all` shows its state
  and whether its last init failed.

## Give a storage host its pool

```bash
hps-storage sch-001 create demo --disk <by-id>
```

Creates the pool on one disk of `sch-001`. The pool is named after the active
cluster, and any other name needs `--allow-any-pool-name`. A disk that carries
a signature is refused unless `--wipe`. Add `--dry-run` to see the node calls
first.

## Define, create and start a workload

```bash
hps-workload images
hps-workload define web-1 < web-1.json
hps-workload create web-1
hps-workload start web-1
```

`images` lists the images a definition may name. `define` checks the JSON
definition on stdin and stores it. `create` builds the VMs, disks and mirrors.
`start` boots them.

## Read its address

```bash
hps-workload status web-1 --json
```

Prints each VM's DHCP-lease addresses. `hps-workload list --project demo` shows
the first address of every workload of the project.

## Stop and destroy

```bash
hps-workload stop web-1
hps-workload destroy web-1
```

`stop` shuts the VMs down. `destroy` removes the VMs, zvols, mirrors and the
record and keeps the definition, so a later `create` works. `destroy --forget`
removes the definition too.

# Command reference

Common flags: `--json` prints machine-readable output and `--dry-run` prints
what would happen and changes nothing, on the tools that list them.

## hps-onboard

Held hosts and their assignment.

`hps-onboard list [--all] [--json]`
: Lists the held hosts. With `--all`, every host with its state; FAILED marks a
  failed init.

`hps-onboard show <mac> [--json]`
: Shows one host.

`hps-onboard assign <mac> --type SCH,TCH,DRH,CNH,BLD --profile NAME --os arch:name:version --pin PIN [--storage "note"] [--host-key NAME=VALUE ...]`
: Assigns a held host. `--host-key` sets an allowed host key before the first
  converged boot (`boot_bridge=br-NAME`).

`hps-onboard set-key <mac> --host-key NAME=VALUE [--host-key ...]`
: Sets an allowed host key on an assigned host (`boot_bridge` only). Reboot the
  node for it to take effect.

`hps-onboard repin <mac> (--pin PIN | --to-latest)`
: Moves a host to another image pin.

`hps-onboard reaudit <mac>`
: Marks a held host's audit stale, so its next boot serves the audit image
  again. Held hosts only.

`hps-onboard nets <mac> [--attach NAME[,NAME...]] [--json]`
: Shows the networks attached to the host. With `--attach` the list is
  replaced; `--attach ''` clears it.

`hps-onboard forget <mac> [--dry-run]`
: Removes a host that will not come back: agent registration, registry entry,
  DHCP and DNS entries. Refused for a host with exports, a pool or workloads.

`hps-onboard prune-agents [--dry-run]`
: Removes agent registrations that are not the FQDN agent of a registry host.

## hps-node

Power and network of a node. `<host>` as above.

`hps-node power-off <host> [--force-after SECONDS]`
: Runs `hps-storage <host> down`, then stops the node and waits for the BMC to
  report Off. The BMC is asked to force power off only after `--force-after`
  seconds (default 120), and that is logged as a fault.

`hps-node net-up <host> [--dry-run] [--json] [--wait SECONDS]`
: Gives a NixOS host its addresses on the storage and transit networks and, on
  a TCH, builds its vxlan networks.

`hps-node net-status <host>`
: Shows bridges, VLAN sub-interfaces, members and addresses (read-only).

`hps-node resources <host>`
: Shows the host reserve, the guests' limits, the ZFS ARC and memory
  (read-only).

## hps-storage

Pools, zvols and exports on a storage host. Every form is
`hps-storage <host> <verb> ...`. Sizes are like `1G` (K, M, G, T).

`up|down|trim-check|status [--dry-run] [--json] [--wait SECONDS]`
: `up` exports every recorded target again; `down` takes them down;
  `status` prints the recorded figures.

`measure [--dry-run] [--json]`
: Measures the pool with a temporary 1 GiB zvol; the pool must be up.

`create <pool> --disk <by-id> [--disk <by-id>]... [--wipe] [--no-measure] [--dry-run] [--json] [--allow-any-pool-name]`
: Creates a pool from 1 to 4 disks. One disk is a single vdev; two to four make
  one mirror. Measures the disks first unless `--no-measure`.

`destroy <pool> [--dry-run] [--json] [--allow-any-pool-name]`
: Destroys the pool.

`zvol-create <pool>/enc/[vm/]<name> <size> [--dry-run] [--json]`
: Creates a zvol.

`zvol-destroy <pool>/enc/[vm/]<name> [--dry-run] [--json] [--allow-any-pool-name]`
: Destroys a zvol.

`zvol-grow <pool>/enc/[vm/]<name> <new size> [--dry-run] [--json]`
: Grows a zvol to the new total size; it never shrinks.

`zvol-list [--json]`
: Lists the zvols.

`export <pool>/enc/[vm/]<name> --iqn <iqn> --initiator <iqn> [--portal <ip>] [--dry-run] [--json]`
: Exports a zvol as an iSCSI target and records it. The portal defaults to the
  host's registry IP.

`unexport <iqn> [--dry-run] [--json]`
: Removes an export.

`vdev-online <pool> <vdev> [--dry-run] [--json]`
: Brings a returned disk back (`zpool online`, `zpool clear`). Refused while the
  disk is still away.

`zfs-set <pool>/enc[/[vm/]<name>] <prop>=<value>... [--dry-run] [--json]`
: Sets `sync=standard|always|disabled` or `logbias=latency|throughput`, and
  nothing else.

`forget-key [--yes] [--dry-run] [--json]`
: Forgets the host's stored key.

## hps-workload

Virtual-machine workloads. `<name>` is the workload, stored as
`workloads/<name>.json`. `--vm <vm>` narrows a verb to one VM.

`hps-workload define <name> [--replace] [--dry-run] [--json]`
: Reads the JSON definition on stdin, checks it and stores it. An existing
  definition is replaced only with `--replace`, and never while the workload
  exists. Through `hps-op` this is `hps-workload-define` (see below).

`hps-workload show-definition <name>`
: Prints the stored JSON.

`hps-workload create <name> [--resume [--image-written]] [--dry-run] [--json] [--allow-any-pool-name]`
: Builds the instance. `--resume` continues an unfinished create.

`hps-workload start <name> [--vm <vm>] [--dry-run] [--json]`
: Starts the VMs.

`hps-workload stop <name> [--vm <vm>] [--force] [--dry-run] [--json]`
: Stops the VMs.

`hps-workload suspend <name> [--vm <vm>] [--dry-run] [--json]`
: Saves each VM's memory on its compute host and stops it, so a long job
  survives a planned host reboot.

`hps-workload resume <name> [--vm <vm>] [--dry-run] [--json]`
: Brings a suspended VM back where it left off.

`hps-workload destroy <name> [--forget] [--dry-run] [--json] [--allow-any-pool-name]`
: Removes the instance and keeps the definition; `--forget` removes that too.

`hps-workload status <name> [--vm <vm>] [--dry-run] [--json]`
: Shows each VM's latest utilisation and its addresses.

`hps-workload grow-disk <name> <vm> <disk> <new size> [--dry-run] [--json]`
: Grows one disk of a VM. The filesystem inside the guest is grown there.

`hps-workload console <name> [--vm <vm>] [--lines N] [--dry-run] [--json]`
: Prints the tail of each VM's serial console log (read-only), `N` from 1 to
  10000.

`hps-workload list [--project <P>] [--json]`
: Lists every recorded workload: name, project, state, hosts, VM count, first
  address, creation time.

`hps-workload images [--json]`
: Lists the image catalogue with size and sha256.

## hps-workload-define

Only through the operator API. It is the form of `hps-workload define` that
takes the definition as confidential input.

```bash
hps-op --cred FILE --input hps-workload-define web-1 < web-1.json
```

Add `--dry-run` to check the definition and write nothing, `--replace` to
replace an existing one.

## hps-issues

The issue register: what the IPS found wrong, healed or left for a person.

`hps-issues list [--all] [--json]`
: Lists unresolved issues (open, healing, needs-human). `--all` adds resolved
  ones.

`hps-issues show <id> [--json]`
: Shows one issue with its trail.

`hps-issues open --kind K --key-field k=v [--key-field k=v]... [--severity urgent|warning] [--summary S|-] [words...]`
: Files an issue, or adds to the unresolved one of the same key. The default
  severity is warning.

`hps-issues resolve <id> --by TEXT|- [words...]`
: Resolves an issue by id. `-` reads the text from standard input.

`hps-issues resolve --kind K --key-field k=v... --by TEXT|- [words...]`
: Resolves the unresolved issue of a key.

`hps-issues note <id> TEXT|- [words...]`
: Adds a note to the trail.

`hps-issues retry <id>`
: Puts an issue back to open with its heal backoff reset. Refused for a
  resolved issue.

Through `hps-op`, text with spaces or other characters goes through
`hps-issues-input` with `--input`.

## hps-metrics

Read-only results of `hps-monitor`. The target is `<mac|hostname|ips|all>`.

`hps-metrics last <target> [--json]`
: Each host's latest check results and utilisation. `ips` is the IPS itself.

`hps-metrics series <target> [--hours N] [--step S] [--json]`
: One host's utilisation per bucket. `--hours` 1 to 168 (default 24), `--step`
  30 to 86400 seconds (default 300). With `all`, every host's compound only.

`hps-metrics series <mac|hostname> --guest <vm> [--hours N] [--step S] [--json]`
: One guest of a compute host: cpu, memory, vcpus and disk and network rates.

## hps-log

Read-only syslog lines, newest last, secrets shown as `[redacted]`.

`hps-log attention [--since 1h] [--json]`
: Is anything wrong: the open problems from the event lines, at most a
  screenful. Exit 0 nothing needs attention, 10 attention, 11 the events could
  not be read (never "no problems").

`hps-log events [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]`
: The event lines (what happened, in a fixed vocabulary).

`hps-log audit [--lines N] [--since T] [--grep WORD] [--json]`
: The audit records: ctrl-exec and operator calls with identity.

`hps-log host <mac|hostname> [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]`
: The lines the IPS received from a host.

`hps-log ips [--lines N] [--since T] [--grep WORD] [--min-level LEVEL] [--json]`
: The IPS's own lines (and its DHCP lines).

`--lines` defaults to 50 (at most 500). `--since` is 1 to 43200 minutes, or a
number with `m`, `h` or `d` (`30m`, `1h`, `2d`); rotated and compressed files
are read. `--min-level` is `warning` or `error`. `--grep` takes one word.
Files, markers and retention: `docs/LOGGING.md`.

## hps-pins

Node image pins on the IPS.

`hps-pins list [--json]`
: Lists pins with date, size, profiles and the hosts pinned to each.

`hps-pins verify (<pin> | --all) [--json]`
: Checks hashes and sizes of a pin's files. FAIL lines name the file.

`hps-pins prune [--keep-previous N] [--dry-run]`
: Removes pins nothing references, keeping the newest N (default 1).

`hps-pins delete <pin>`
: Deletes one pin that nothing protects.

`hps-pins latest <pin>`
: Points `nixos/latest` at a pin that verifies.

## hps-bmc

Out-of-band power and console. `<host>` as above.

`hps-bmc status|on|off|force-off|reset|pxe-once|identify <host> [--json]`
: Power and identify actions. `status --json` returns power, model, serial and
  BMC firmware.

`hps-bmc console <host> [--seconds N]`
: Serial console: stdin in, output out; ends after N seconds (1 to 3600,
  default 600).

`hps-bmc set <host> --driver NAME|auto [--addr A] [--option k=v]...`
: Sets the host's BMC driver.

`hps-bmc credential <host|device:NAME> [--user U]`
: Stores a BMC credential from stdin: the user line, then the password line
  (with `--user`, the password only).

`hps-bmc device set <name> [--addr A] [--option k=v]... | list | delete <name>`
: Manages named BMC devices.

`hps-bmc select <host>`
: Chooses the driver from the stored audit.

`hps-bmc list [--json]`
: Lists BMC settings.

## hps-osvc

OpenSVC cluster membership of a node.

`hps-osvc deliver <host> [--dry-run]`
: Sends the cluster secret and CA to the node and restarts its daemon. Run it
  for every node, and again on every node after a node is paired.

`hps-osvc status <host>`
: Shows the daemon's peers. Exit 0 healthy, 2 a peer stale, 1 not answering.

`hps-osvc ca-forget`
: Deletes the stored CA for a deliberate re-bootstrap.

## hps-cluster-config

Cluster keys. The cluster defaults to the active one; `--cluster NAME` selects
another.

`hps-cluster-config [--cluster NAME] questions [--json]`
: Lists the keys that can be set.

`hps-cluster-config [--cluster NAME] show [--json]`
: Shows the configuration.

`hps-cluster-config [--cluster NAME] get KEY`
: Prints one key. Exit 4 when it is unset.

`hps-cluster-config [--cluster NAME] set KEY VALUE [--dry-run] [--json]`
: Sets one key.

`hps-cluster-config [--cluster NAME] apply FILE|- [--dry-run] [--json]`
: Applies `key = value` lines or a JSON object. On a validation error nothing
  is written.

`hps-cluster-config [--cluster NAME] export [--json]`
: Exports the configuration.

Through `hps-op`, values that do not fit an argument go through
`hps-cluster-config-apply` with `--input`.

## hps-operator

Operator credentials, run on the IPS.

`hps-operator issue <name>`
: Prints a new credential once. Save it mode 0600 as the file for
  `hps-op --cred`. The name is 1 to 32 of `a-z 0-9 -`, starting with a letter.

`hps-operator list [--json]`
: Lists the names holding a credential, with the issue time.

`hps-operator revoke <name>`
: Stops the credential at once.

`hps-operator export`
: Rewrites the auth hook's digest file from the keysafe.

`hps-operator ca`
: Prints the API's TLS certificate.

## hps-ips-check

`hps-ips-check [--json] [--wait SECONDS] [--no-logger]`
: Self-check of the IPS: boot manager, TFTP, DNS, ctrl-exec, syslog, time,
  disk space, registry and pairing. Prints PASS, FAIL or WARN per check and
  writes `ips-check.json`. Exit 0 with no FAIL, 1 with any FAIL, 2 usage.

## hps-op and hps-run

`hps-op [--ips URL] --cred FILE [--input] [--timeout S] [--json] <tool> [args...]`
: Runs an `ips-admin` tool on the IPS's own agent and prints its output.

`--cred FILE`
: The credential from `hps-operator issue`; a file wider than 0600 is refused.

`--ips URL`, `--ca FILE`
: The API address and certificate; by default those in the credential.

`--input`
: Sends stdin as confidential input. For `hps-bmc-credential`,
  `hps-cluster-config-apply`, `hps-workload-define` and `hps-issues-input`.

`--timeout S`
: Seconds to wait (default 900). `--json` prints the API's JSON reply.

Tools it runs: `hps-onboard`, `hps-cluster-config`, `hps-cluster-config-apply`,
`hps-bmc`, `hps-bmc-credential`, `hps-node`, `hps-storage`, `hps-workload`,
`hps-workload-define`, `hps-pins`, `hps-ips-check`, `hps-osvc`, `hps-monitor`,
`ips-syslog-forward`, `hps-repo`, `hps-log`, `hps-metrics`, `hps-issues`,
`hps-issues-input`.

`hps-run`
: The node-script runner (`scripts/hps-run.sh`) that the tools use to reach a
  node, with `--input` for confidential input. It has no operator verbs.

# Exit codes and refusals

```datatable
columns: Code | Meaning
widths: 2cm | X
bold: 1
---
0 | Done.
1 | Failed: a node call or the operation did not complete.
2 | Usage: a missing or malformed argument.
3 | Refused: a rule stopped it and nothing was changed. The message names the reason.
4 | No such thing: host, workload, pin, issue, key or log.
```

Tool-specific codes:

`hps-node power-off`
: 6 – the BMC forced the power off.

`hps-bmc`
: 4 – target unreachable; 5 – not supported by this device.

`hps-log attention`
: 0 – nothing needs attention; 10 – attention; 11 – the events could not be read
  (no `events.log`, an empty one, an unreadable one, or no event line in the window).

`hps-osvc status`
: 2 – a peer is stale.

`hps-ips-check`
: 1 – any FAIL; WARNs do not fail.

`hps-op`
: The tool's own code; 2 for usage or a refused credential file; 1 when the
  API call failed.

A refusal is a policy answer and changes nothing. Typical ones: `assign` on a host
that is not held, `repin` on a host that is held, `forget` on a host with a
pool, `define` over an existing definition, a disk with a signature without
`--wipe`, a pin another host still uses.

## Logs and the issue register

- `hps-log attention` answers "is anything wrong" in a few lines; `hps-log
  events` shows what happened; `hps-log audit` shows who called what;
  `hps-log host <host>` reads what a host sent to the IPS; `hps-log ips` reads
  the IPS's own lines.
- `hps-metrics last <host>` shows the latest check results.
- `hps-issues list` shows what is unresolved; `hps-issues show <id>` shows the
  trail.
- Workload tools log every node call, its exit status and every refusal to
  stderr and to syslog (tag `hps`).
- Operator calls through `hps-op` log two lines with the tag `ips-admin`: the
  tool and arguments, then its exit status. The input is never logged.

# What needs a node image and what works at once

Works at once on the IPS, with no node involved
: `hps-issues`, `hps-log`, `hps-metrics` (reads of what the IPS holds),
  `hps-pins`, `hps-cluster-config`, `hps-operator`, `hps-ips-check`,
  `hps-onboard` (list, show, assign, forget, prune-agents),
  `hps-workload` define, show-definition, list and images, and every
  `--dry-run`.

Needs a booted, paired node
: `hps-node`, `hps-storage`, `hps-osvc` and the `hps-workload` verbs that act
  on VMs (create, start, stop, suspend, resume, destroy, status, grow-disk,
  console) call node scripts through the IPS's dispatcher. `hps-node net-up`
  needs a NixOS host.

Needs a node image or a reboot
: `hps-onboard repin` points a host at another pin. `hps-onboard set-key`
  `boot_bridge` is read at boot. `hps-onboard reaudit` takes effect at the
  node's next boot.

Needs a BMC driver
: `hps-bmc` actions, and the power-state confirmation in `hps-node power-off`.

# Further reading

- `docs/OPERATOR.md` – operator access, credentials and the API.
- `docs/WORKLOADS.md` – the definition, limits, suspend and resume.
- `docs/CLUSTER-CONFIG.md`, `docs/ISSUES.md`, `docs/LOGGING.md`,
  `docs/MONITORING.md`, `docs/BMC.md`, `docs/OPENSVC.md`, `docs/IPS-CHECK.md`.
