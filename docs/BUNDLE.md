# The node bundle, the hook and the adapter

A host assigned the profile `STARTER` boots the distribution's own starter
(`docs/STARTER.md`), which has nothing of HPS in it. This page is how that
starter becomes a paired node, with no image built and no secret in anything it
holds. It is steps 2 and 3 of `plans/PLAN.md`. The pinned-image nodes (`CONVERGED`,
`CONTAINER_HOST`, ...) are not touched: they boot, pair and run the same
actions as before, until plan step 7 retires them.

## In four lines

- The **bundle** is one archive the IPS builds from the tree's node scripts and
  serves; a node keeps it in RAM under `/run/hps`.
- The **bootstrap script** is the only thing the starter fetches by itself; the
  **hook** in the kernel line makes the stock starter run it, as root, at boot.
- At boot the bundle creates the `sysadmin` user, installs the role's packages,
  installs the ctrl-exec agent and its preset allowlist, sets up what a storage
  or compute node runs (step 3, "Storage and compute"), and pairs.
- Everything that differs between operating systems is the **adapter**: how to
  boot it, how to add a package, how to start a service.

## What the IPS serves

All of it is plain HTTP on the provisioning network, from the CGI
`/cgi-bin/boot_manager.sh`; none of it is secret and none of it is signed
(`STRATEGY.md`: whoever controls the IPS controls the cluster).

| `cmd=` | gives | built from |
| --- | --- | --- |
| `node_bootstrap` | the bootstrap script | `node-manager/bundle/bootstrap.sh` |
| `node_bundle` | the bundle, a `tar.gz` | the tree, on each request |
| `node_packages` | the store paths of this node's role, one per line | `lib/starter/<os>.roles`, resolved through the repository manifest |
| `node_sysadmin_keys` | the installation's sysadmin SSH public key(s) | `<config>/sysadmin_authorized_keys` |

The agent is not in the bundle: it is a **local package** of the IPS
repository (see "Local packages"), named in the node's package list, and the
node runs it by its store path.

### The bundle

`node_bundle_tar` (`lib/functions.d/node-bundle-functions.sh`) is one `tar`:

| in the bundle | from the tree |
| --- | --- |
| `init`, `role`, `bootstrap.sh`, `allowlist`, `adapter/`, `actions/bundle-refresh`, `lib/hps-log-journal` | `node-manager/bundle/` |
| `actions/<name>` | `node-manager/nixos-26/scripts/<name>`, as they are |
| `actions/hps-node` | `node-manager/plugins/hps-node/hps-node.sh` |
| `plugins/<check>` | `node-manager/nixos-26/plugins/`, the monitoring checks as they are ("Monitoring") |
| `apparmor/<profile>` | `node-manager/apparmor/`, the libvirt profile texts the pinned images' nix module reads too ("AppArmor") |
| `lib/hps-pair` | `node-manager/nixos-26/boot/hps-pair.sh`, the existing pairing flow |
| `lib/hps-time`, `hps-iscsi-name`, `hps-osvc-config`, `hps-md-event`, `hps-shutdown-storage` | `node-manager/nixos-26/boot/hps-*.sh`: the scripts the pinned images run as units, as they are |

It is built when a node asks, so a script changed in the tree is in the next
bundle a node fetches (and nothing is regenerated or restarted on the IPS). The
build is deterministic (sorted, fixed time and owner, not group- or
world-writable), so the same tree is the same bytes and the same bundle id; the
IPS log line `node bundle served: <id>` and the node's `/run/hps/bundle` link
both show the id (the first 16 hex digits of the sha256). The node actions are
not forked: an action under `nixos-26/scripts/` is the one script for pinned
images and starter nodes alike. Alpine (plan step 4) will add its own scripts
directory to the builder.

## The hook

A stock starter runs nothing of ours, so the IPS's kernel line makes it fetch
one script. The mechanism is systemd's own `systemd.run=` (nothing is added to
the image), with three companions:

```
systemd.run="/bin/sh -c '/run/current-system/sw/bin/curl -fsS --retry 60 --retry-delay 2 --retry-all-errors http://<ips>/cgi-bin/boot_manager.sh?cmd=node_bootstrap | /bin/sh'"
systemd.run_success_action=none
systemd.run_failure_action=none
systemd.wants=kernel-command-line.service
```

`nixos_starter_hook` writes it. `systemd.run=` makes systemd's run generator
write a unit, `kernel-command-line.service`, that runs the command as root. What
the trial on the stock NixOS 26.05 starter (the lab VM's nested guest, 16
November 2026) showed:

- With `systemd.run=` alone the unit is written and **never started**: the
  starter's default target is `multi-user.target`, a link in `/etc`, and it wins
  over the target the generator makes. `systemd.wants=kernel-command-line.service`
  starts it with the normal boot.
- `run_success_action=none` and `run_failure_action=none` keep the node up
  whatever the script does. Without them the default is to power off.
- The unit's `PATH` has no coreutils (`id`, `cat` are not found), so the command
  uses absolute paths and the bootstrap script sets its own `PATH`.
- The network is not up when the unit starts; `curl --retry --retry-all-errors`
  waits for it (up to two minutes, then the unit fails and says why in the
  journal and on the console).
- **iPXE has operators of its own.** The first form of the command ended in
  `&& exec /bin/sh ...`; iPXE 1.21 read the `&&` as the end of the `kernel`
  command and failed with `exec: command not found` (the boot was tried through
  the real iPXE ROM, not only with `-kernel`). The line therefore has no `&&`,
  `||`, `;`, `$`, backslash or backtick, and one pipe. The double quotes and the
  single quotes reach the kernel as characters. A test (`test_p3_263`) checks
  the line for all of this.
- The long work does not hold the boot: the unit is wanted, not required, and
  the console login, SSH and everything else start in parallel.

The command line carries no secret and no key: the IPS address, the MAC, the OS
(`hps.os=x86_64:nixos:26.05`), the profile and the DNS domain. It is the same
kind of line the pinned images get.

## At boot, in order

`bootstrap.sh` (POSIX sh) reads `hps.ips=` from the kernel line (the first one,
never an argument), fetches the bundle, unpacks it to `/run/hps/b/<id>/`, points
`/run/hps/bundle` at it with one atomic rename and runs its `init`. Then `init`,
in the bundle, does these things. Each is idempotent and logged as `+ command`;
the output is on the console, in the journal (`journalctl -u
kernel-command-line`) and the main events on the IPS log.

1. **sysadmin.** Creates the user `sysadmin` in the OS's sudo group, installs
   its SSH key from the IPS, and makes sshd refuse root (`PermitRootLogin no`,
   no password login, `AllowUsers sysadmin`; the directives go first in
   `sshd_config` because the first value of a keyword wins, the starter's own
   file follows unchanged; `passwd -l root`). This is first so that a person can
   log in and look when anything later fails. No key is in any image: it is
   fetched; if the IPS holds none, `init` says so and the user cannot log in by
   SSH. The starter's serial-console auto-login of `nixos` is physical access,
   which is inside the boundary of `SECURITY-MODEL.md`.
2. **packages.** Asks the IPS for this node's package list and adds it from the
   IPS repository (`/packages/<os>/<release>/`) and nothing else.
3. **agent.** Takes the ctrl-exec agent, with its executor, from the IPS
   repository by store path; creates the service user `ctrl-exec-agent` (not
   `sysadmin`, which has sudo); writes `agent.conf` with the profiles of the
   pinned images and `scripts.conf` (from `allowlist`); and starts two
   services: the executor (root) and the agent (the service user, no
   capability, the sandbox of ctrl-exec's own NixOS module). The agent starts
   when `agent.crt` exists.
4. **legacy bundle.** Fetches the older function bundle (`get_remote_functions`)
   into `/run/hps/functions.sh`, which the allowlisted `hps-node` plugin
   sources. Not fatal. It goes with the pinned images (plan step 7).

5. **role** (plan step 3). For a node whose registry `TYPE` is `SCH` or `TCH`: the
   clock, log forwarding, the storage or compute services, the bridges, om3 and
   the power-off unit, before pairing. Its own section: "Storage and compute".
6. **pairing.** Runs `hps-pair`, the existing pairing flow: the hostname from
   the registry (as `<name>.<domain>`), `ctrl-exec-agent request-pairing`, the
   report to the IPS, the approval, the certificate, and a restart of the
   agent. A refused pairing is exit 3, any other failure exit 1.
7. **role, after pairing.** The iSCSI initiator of a compute node, whose name is the
   FQDN that pairing has just set.

A failed step stops the sequence with the reason; sysadmin is already there. A
failed role step is the one exception: it is said and remembered, pairing goes
on, and `init` ends with exit 1 naming it.

### The preset allowlist

`node-manager/bundle/allowlist` is plain data: one action per line, `name
[key=value ...]`. It is the list of the pinned images
(`nix/modules/hps-ctrl-exec.nix`) plus `bundle-refresh`; a test keeps the two
the same. `init` writes `scripts.conf` from it, each action pointing at
`/run/hps/bundle/actions/<name>`, so a refreshed script is the one that runs.
The agent assumes its dispatcher is compromised: it runs only what the list
names, with the arguments the action itself checks. There is **no action that
runs a command or script a dispatcher sends**, and a test says so.

The agent that takes requests from the network is not root. It is the user
`ctrl-exec-agent` with no capabilities and the unit sandbox of ctrl-exec's own
module (`ProtectSystem=strict`, `PrivateDevices`, a system call filter,
`MemoryDenyWriteExecute`, ...). Only the executor, a small root service the
agent talks to over a socket, raises privilege, per action and per profile: the
profiles in `agent.conf` are those of the pinned images word for word
(`nix/modules/hps-ctrl-exec.nix`; a test compares the capability list), so an
action runs as root with that capability set, `no_new_privileges`, in a
private mount namespace of its own, and with the agent's own configuration
read-only to it. This is the same arrangement as `docs/SECURITY.md` "Node
scripts under the executor". No compiler is on the node and none runs at boot:
the executor is a file in the package.

### Packages: the role-to-package mapping

`lib/starter/nixos.roles` is the mapping, as plain data:

```
*:   ctrl-exec-agent
SCH: targetcli-fb mdadm smartmontools xxd jq om3 nagios-check hps-nagios-plugins
TCH: libvirt qemu-host-cpu-only open-iscsi mdadm tcpdump jq om3 apparmor-parser apparmor-profiles nagios-check hps-nagios-plugins
```

A role is a word of the host's registry `TYPE` (`SCH,TCH` gets both lines);
`*` is every node. Each name is a name in `lib/starter/nixos.packages`.
`node_role_packages` resolves each through the repository's own
`manifest.json` (`roots`) and the node gets exactly what the repository holds; a
name the repository does not hold is an error that names it (the node reports
it and stops), never a silent omission. What the storage and compute scripts
need beyond the starter (smartmontools, xxd, tcpdump, jq, om3) is in the lines above
since step 3 ("Storage and compute"). `jq`, `smartmontools`, `tcpdump` and `xxd` are
named in `nixos.packages` by the store path the pinned images use (upstream,
signed), so no search chooses among candidates; `om3` is a local package.

**openssl and Perl JSON.** The agent needs both, and they are in its package's closure: the JSON module is the starter's own path (`perl5.42.3-JSON-4.10`), openssl is the bin output of the starter's own version (`openssl-3.6.5-bin`). Nothing is listed for them any more; a new agent build brings its own.

### The sysadmin key

`<config>/sysadmin_authorized_keys` on the IPS (the config base, for example
`/srv/hps-config`) holds the installation's public key or keys, OpenSSH
`authorized_keys` lines. The installer or the operator writes it (the
installation's key extraction is outside this step). The IPS serves only
well-formed lines without options in front (no `command=`, no `from=`), and the
node checks the same again. A public key is not a secret.

## The refresh and the upgrade

`bundle-refresh` is an allowlisted action with no arguments. It runs the
`bootstrap.sh` that is inside the bundle with `refresh`: the same fetch, from
the address on the node's own kernel line, then `init` again. Nothing a
dispatcher sends names the address or the file: a dispatcher credential can ask
for a refresh and cannot change what is fetched. The agent's configuration is
read-only to every action, so the action does the work in a transient systemd
unit (`systemd-run --wait --pipe`), outside the executor, and relays its output.

After a refresh, with **no reboot**:

- a script changed on the IPS is live (the agent runs each action through the
  `bundle` link);
- the allowlist is rewritten if it changed (the agent reloads it by itself);
- a package the node's role gained on the IPS is installed (`nix profile
  install` of the new path only; what the node has is left alone);
- a node that is paired is not paired again;
- **a new agent version** is taken: the IPS lists the agent by store path, so a
  new version is a new path. The refresh fetches it beside the old one,
  rewrites the two unit files to point at it, and, because a unit changed,
  starts a timer unit (`systemd-run --on-active=5`) that restarts exactly the
  executor and the agent. The action has answered by then, so the agent is not
  killed in the middle of its own reply. Nothing else is restarted: guests,
  storage services, sshd and the rest of the node run on. An unchanged agent is
  not restarted by a refresh.

A base OS or a storage host therefore never needs a reboot for a new agent, a
new script or a new package of its role. (A new kernel still does.)

```
hps-run <host> bundle-refresh
```

## Local packages

A package that is not in nixpkgs (the ctrl-exec agent, later om3 and others the
builder compiles) is a **local package**. Three lines:

1. A store path, built elsewhere (the builder), as a narinfo and a nar, goes into
   the IPS with `hps-starter add-local nixos --from <cache dir> <store path>`:
   its closure, minus what the repository already holds, lands in
   `<resources>/local/nixos/<release>/`.
2. `lib/starter/nixos.packages` names it by path (`NAME /nix/store/...`), and
   `hps-starter sync nixos` puts it in the repository beside the upstream ones,
   with the same manifest (size and sha256, so `verify` and the pruning treat
   it like any other file).
3. `lib/starter/nixos.roles` says which roles get it. It then arrives on a node
   like any package of the repository.

The repository has no signing key of its own, and STRATEGY.md keeps the
upstream signatures as they are, so a local package is a narinfo without a
`Sig:` line and a node installs it knowing so: upstream packages with their
signatures checked against the stock key, local ones in a separate call without
the check (`require-sigs false`), after the signed ones. A package with a
signature is never installed unchecked. Delivery from the IPS is plain
(`STRATEGY.md`).

The agent: the lab's Nix cache holds the build the pinned images use
(`ctrl-exec-agent-0.14.7`, with `bin/ctrl-exec-executor`; no compiler is
needed to use it). To change version: `add-local` the new path, change the
list line, `sync`; the nodes take it at their next refresh.

**om3** is the second local package (OpenSVC v3, `3.0.0-rc62`, the tag `flake.nix`
pins; plan step 3). The same cache holds the pinned images' build, and it is put in
the same way, with no compiling:

```
hps-starter add-local nixos --from /srv/hps-resources/nix-cache /nix/store/icpkmfz7s1kdv444l7sfdsvijk7m7qvx-om3-3.0.0-rc62
hps-starter sync nixos --only repository
```

(its closure is eight store paths, 96 MiB unpacked, 21 MiB in the repository beyond
what it already holds). `nixos.packages` names it by path and both `SCH` and `TCH`
lines of `nixos.roles` carry it; it arrives at a node's next refresh, and a node that
already runs takes it with no reboot. It has no upstream signature (the narinfo has no
`Sig:` line) and is installed in its own call, as the agent is. The unit that runs it
is `opensvc-daemon`, the pinned image's own, in `role`.

## The adapter

The per-OS part is exactly three things, and `node-manager/bundle/adapter/<os>.sh`
holds them for one OS:

| thing | NixOS | where |
| --- | --- | --- |
| how to boot it | the kernel line: the stock arguments, the hook, `hps.*` | the IPS, `nixos_starter_boot_lines` |
| how to add a package | `nix profile install` of store paths, substituted from the IPS repository only; the stock upstream key; `pkg_realise` for the agent, outside the profile | `pkg_add`, `pkg_realise` |
| how to start a service | a unit in `/run/systemd/system`, started; its port opened in the host firewall; a restart from a timer; a unit the OS ships linked to `/dev/null` | `svc_start`, `svc_reload`, `svc_restart_later`, `svc_mask`, `fw_open` |

Everything else in the bundle is OS-neutral: the user, the SSH key, the
`sshd_config` change (the starter's link into the store is replaced by a real
file), the agent, the allowlist, the pairing. The adapter also sets two
variables: where added packages' programs appear (`PKG_BIN`) and the sudo group.

**Alpine** (plan step 4) adds `adapter/alpine.sh` with the same functions and
variables (`PKG_ETC`, where a package's `etc` files appear, is the one AppArmor added) and one branch in `init`'s `case "$OS_NAME"`, which marks the place;
the IPS side adds its kernel line and its package repository. There is no Alpine
code now, and `init` refuses an OS it has no adapter for by name.

## On the IPS: what makes a starter host pair

Nothing new in the pairing flow. `hps-onboard assign --profile STARTER` already
allocates the host's address and name (as for any host) and sets `NETWORK_BOOT`.
What was missing is the window: a boot of a starter host now opens the
dispatcher's pairing window and clears the old pairing record, as the boot of a
pinned host does (`ipxe_boot_nixos`). The approver binds the request to the
registry host as for every node (state, source address, FQDN, window).

## Storage and compute

A node whose registry `TYPE` is `SCH` or `TCH` (or both) does what the pinned
storage and compute profiles do (`nix/modules/profiles/storage.nix`,
`compute.nix`, `hps-opensvc.nix`, `hps-common.nix`), from the bundle and not
from an image. The node scripts it runs are the same files; the boot scripts
those images start as units travel in the bundle as `lib/*`. This is plan step 3.
`init` sources `role` and calls two functions of it:

| when | step | what it does |
| --- | --- | --- |
| before pairing | clock | `lib/hps-time`: timesyncd points at the IPS, a wrong clock is stepped once from the IPS's HTTP date |
| | log forwarding | unit `hps-log-journal`: the journal of this boot, one RFC 3164 line per entry, to the IPS on TCP 514 with the journal's own facility and priority (`lib/hps-log-journal`; jq and the shell, no package) |
| | host reserve | `actions/host-reserve-apply`, the allowlisted script itself: CPU, memory and IO kept for the host, the ZFS ARC cap, `min_free_kbytes` |
| | storage (SCH) | `zfs` and the LIO modules, `/etc/target` for targetcli's saved configuration, port 3260 in the firewall |
| | compute (TCH) | KVM module of the CPU vendor, `vhost_net`, `8021q`, `bridge`, `raid1`, `iscsi_tcp`; AppArmor (`role_apparmor`, "AppArmor"); the user `qemu-libvirtd`; libvirt's `qemu.conf`; the UEFI firmware linked into `/run/libvirt/nix-ovmf`; `mdadm.conf`; the units `virtlogd` and `libvirtd` |
| | bridges | `actions/net-bridge-ensure`, once, so they exist before any workload |
| | om3 | the unit `opensvc-daemon`; ports 1215 and 10000; the group `opensvc` |
| | monitoring | the plugin directory, the link to `nagios-check` and `checks.conf` (`role_monitor`, "Monitoring"); no unit |
| | power-off | the unit `hps-shutdown-storage`: guests, mirrors, targets, sessions and pools stop in that order while everything they need is still up |
| after pairing | initiator (TCH) | `lib/hps-iscsi-name` writes the initiator name from the FQDN pairing set; `iscsid` with the package's own `iscsid.conf` and the fail-fast timeouts |

The units are written to `/run/systemd/system` by the adapter's `svc_start` and
started; nothing is in the image and nothing persists (the node's root is RAM).
Every directory outside `/run/hps` is written under `${HPS_ROOT}`, which is empty
on a node, so the tests can run the whole sequence. A step that fails is said on
the console, in the journal and on the IPS log (`error: role step failed: <step>`),
is never allowed to stop the boot or the pairing, and makes `init` end with exit 1
naming it. A role's package list that lacks a program is found by the step that
needs it, with the missing names (`missing programs: smartctl xxd`), not by the
first action that calls it.

What decides the role is the registry's `TYPE` (the same word the IPS uses to pick
the packages), read by `cmd=host_variable&name=TYPE`. A type that is neither `SCH`
nor `TCH` gets the agent and nothing else.

### What the pinned image does, and where the starter does it

| pinned image | starter |
| --- | --- |
| `services.target` (LIO restore at boot) | `/etc/target` made; the saved configuration is in RAM and gone after a reboot, as on the pinned image (the IPS exports again after `hps-storage up`) |
| `networking.firewall.allowedTCPPorts = [ 3260 ]`, `[ 1215 10000 ]` | `fw_open` of the adapter, an `iptables` rule of the boot |
| `services.openiscsi` with `extraConfig` | the package's `iscsid.conf` plus the four fail-fast lines (`replacement_timeout` 15, `noop_out_interval` 5, `noop_out_timeout` 5, `login_timeout` 15), the same values `leg-resolve` writes per record (a test compares the two) |
| `boot.swraid` with `PROGRAM` and `AUTO -all`, the last-resort units suppressed | `/etc/mdadm.conf` with the same two lines, `PROGRAM` an sh wrapper (`/run/hps/md-event`) that gives the bundle's `lib/hps-md-event` a PATH; the monitor is the starter's own `mdmonitor.service`, which udev starts with the first array; the last-resort timer and service are linked to `/dev/null` for the boot; written on storage nodes too, or udev assembles a zvol that carries a mirror leg and the export is refused |
| `virtualisation.libvirtd` (`qemu_kvm`, `runAsRoot = false`, `verbatimConfig`) | `libvirtd` from the package, `/var/lib/libvirt/qemu.conf` with the same settings and the same unprivileged user, `KillMode=process` so that a restart of the daemon leaves the guests running |
| `security.apparmor` with `compute-apparmor.nix`; `security_driver = "apparmor"` | the kernel line's `lsm=` and `apparmor=1`, the parser as a package, the same profile files, loaded before `libvirtd` starts (see "AppArmor") |
| `hps-monitor.nix`: `nagios-check` in the agent's scripts and `/etc/nagios-checks/checks.conf` | the allowlist entry, the plugin and the plugin directory, the same `checks.conf` (see "Monitoring") |
| libvirtd-config linking QEMU's firmware into `/run/libvirt/nix-ovmf` | the same links, made by the role step, for `vm-define` |
| `hps-kvm` (the vendor's KVM module) | the same decision, read from `/proc/cpuinfo` |
| `hps-host-reserve`, `hps-iscsi-initiator`, `hps-shutdown-storage`, `opensvc-daemon`, `hps-time`, `hps-log-target` + rsyslog | the same scripts as units of the bundle (log forwarding by `hps-log-journal`, see below) |

### What is not carried

- **`hps-net`.** The stock starter's own DHCP serves the boot NIC; a second NIC on a
  foreign LAN is not made unmanaged. Nothing in step 3 uses a second NIC.
- **Headless QEMU** is plan step 5. `qemu-host-cpu-only` is the QEMU the repository
  already has (its closure is 330 store paths and 1,487 MiB unpacked, with the GTK,
  SDL, PipeWire and ffmpeg libraries a headless guest never loads). A node keeps
  its added packages in RAM (the overlay on the starter's store): the `TCH` set
  measured 1,277 MiB of it in the step 1 check (273 paths the starter lacks), and
  step 3 adds `tcpdump` and `jq` and om3 (96 MiB) on top. A 6,144 MiB node
  therefore has about 3.5 GiB left for the base, ZFS's ARC, the host reserve and the
  guests; 4,096 MiB is not enough for a compute node with a guest.

### AppArmor

A compute node confines each guest's QEMU by an AppArmor profile, as the pinned
images do (`docs/CONFINEMENT.md` "AppArmor layer"). Four parts:

| part | where |
| --- | --- |
| **kernel arguments** | The stock starter kernel has AppArmor built in (the decompressed kernel of the 26.05 starter carries "AppArmor initialized") and its line has `lsm=landlock,yama,bpf`, which leaves it out. `nixos_starter_boot_lines` (the adapter's boot-arguments part, on the IPS) adds `apparmor` to the list before `bpf` and `apparmor=1`, so a starter node's line carries `lsm=landlock,yama,apparmor,bpf apparmor=1` as a pinned node's does. It is on every starter node, not only compute ones: with no profile loaded it changes nothing, and one line is simpler than one per role. Adding it to a node that already runs is the one kernel change that needs a reboot. |
| **packages** | `apparmor-parser` and `apparmor-profiles` (4.1.7, upstream, signed; the store paths of the pinned images) on the `TCH` line of `nixos.roles`. The parser's closure is small (about 2.3 MiB, with bash and glibc). `virt-aa-helper` needs nothing more: it runs `/sbin/apparmor_parser`, a link the role step makes to the package's parser. |
| **profile text** | `node-manager/apparmor/`: `libvirtd`, `virt-aa-helper`, `libvirt-qemu` (the guest abstraction) and `TEMPLATE.qemu`. One copy. The files hold `@@LIBVIRT@@`, `@@QEMU@@` and `@@APPARMOR_PARSER@@` where a store path goes. `nix/modules/profiles/compute-apparmor.nix` reads them and fills the markers in with `builtins.replaceStrings`; the bundle carries them as `apparmor/` and `role_apparmor` fills them in with `sed` from the paths of the node's own packages (`readlink -f` of `libvirtd`, `qemu-system-x86_64`, `apparmor_parser`). The node's libvirt is whatever the repository holds, not necessarily the pinned one's path, which is why nothing is written with a path in it. |
| **loading** | `role_apparmor`, the first thing `role_compute` does after the program check. |

`role_apparmor` in order: the kernel's `/sys/module/apparmor/parameters/enabled` must be
`Y` and `/sys/kernel/security/apparmor/profiles` readable; it writes the abstraction
to `/etc/apparmor.d/abstractions/libvirt-qemu`, `TEMPLATE.qemu` to
`/var/lib/apparmor.d/libvirt/` (libvirt's compiled-in `APPARMOR_DIR`), the two
policies to `/etc/apparmor.d/hps/`, and `/etc/apparmor/parser.conf` with the Include
lines (`/etc/apparmor.d`, the profile's `etc/apparmor.d` that the `apparmor-profiles`
package fills, and `/var/lib/apparmor.d` for the per-guest `libvirt/<uuid>.files`);
it links `/sbin/apparmor_parser`; it loads `libvirtd` and `virt-aa-helper` with
`apparmor_parser -r -K`; and it checks that the daemon's own profile
(`<libvirt>/sbin/.libvirtd-wrapped (enforce)`) is in the kernel's list, because
libvirt's driver probe looks for exactly that. Only then do `libvirtd` and the mirror
monitor start, so the daemon is confined from its first `exec`. `qemu.conf` carries
`security_driver = "apparmor"` as `compute.nix` does.

**No quiet fall back.** If the kernel's AppArmor is off (a node booted before the IPS
issued the new line, or a kernel without it), if the parser fails or if the daemon's
profile is not in the list afterwards, the step prints `ERROR: AppArmor is not active
in this kernel ...` and `libvirtd is NOT started`, the role step "compute services" is
recorded as failed (the IPS log gets `error: role step failed: compute services`), and
`init` ends with exit 1. Pairing still goes on, as for any failed role step, so the
node can be looked at. The guests never run with the DAC model alone.

What the nix side keeps: the profile text is in the plain files and `compute-apparmor.nix`
only fills in store paths. That change is mechanical and **unevaluated** (the host
that made it has no Nix): `checks.<system>.apparmor-profiles` and an evaluation of
`node-converged` have to be run where Nix is (the lab builder) before the next image
build. The text is byte for byte what the module held, so the check is expected to
pass unchanged.

### Monitoring

`hps-monitor` on the IPS asks each paired node to run the allowlisted action
`nagios-check --all` and grades the lines it gets back; it asks every node the same
way (`bin/hps-monitor`), so a starter node is one more node once it answers. The
pinned image answers with the ctrl-exec plugin `nagios-check.pl` and
`/etc/nagios-checks/checks.conf` (`nix/modules/hps-monitor.nix`). A starter node:

| what | how |
| --- | --- |
| the action | `nagios-check profile=node` on the bundle's allowlist (the pinned image's own entry: same profile, no `input`). The bundle's `actions/nagios-check` runs the plugin through `/run/hps/nagios-check` with the arguments it was given and nothing else; the plugin takes check names or `--all` and refuses the rest. No link yet (a node whose role step failed) is a plain message and exit 3. |
| the plugin | `nagios-check`, a local package (the pinned image's build, from the lab's cache, one 13 KiB file whose only reference is Perl). Realised by its store path outside the profile, as the agent is, and linked to `/run/hps/nagios-check`. |
| the plugin directory | `/run/hps/nagios-plugins/`, one directory of real files (nagios-check refuses a plugin that resolves outside its directory). `check_disk`, `check_load`, `check_procs` and `check_mem` come from the local package `hps-nagios-plugins` (the pinned `node-base` build, which holds them next to the `monitoring-plugins` they were copied from). The usage checks (`check_cpu`, `check_net`, `check_diskio`, `check_fs`, `check_swap_use`, `check_osvc_hb`, and `check_zpool`, `check_zpool_io` on a storage node and `check_vms` on a compute node) are the bundle's `plugins/` files, copied as they are with their one `# @HPS_PATH@` line replaced by a `PATH` of the program directories (the nix module replaces it with the store paths of its tools). |
| the checks | `/etc/nagios-checks/checks.conf`, written by `role_monitor`: the set `hps-monitor.nix` generates for the node's roles, line for line (a test compares each line with the module's). |
| what starts | Nothing. The pinned images run no timer or unit for monitoring; the IPS asks, and the checks run when it does. |

`check_vms` reports a paused guest (`PAUSED <vm> reason=...`), `hps-monitor` writes the
line into the IPS log, and the `guest-paused` rule of `lib/hps-issue-rules.conf` opens
the issue (`docs/ISSUES.md` "A paused guest"); the healer then runs `vm-resume`, which
was already on the bundle's allowlist. The missing piece on a starter node was the
reading, and it is now there. `hps-nagios-plugins` and `nagios-check` are put on the IPS
with `hps-starter add-local` like `om3` (`plans/step3b-trial.md`). The packages'
closure beyond the repository (the `monitoring-plugins` libraries that `check_disk`
and the others link) has not been measured on a node; it adds to the RAM of every
storage and compute node.

### The waiting fixes

Three fixes were written for the pinned images and waited on branches
(`suspend-state`, `guest-resume`, `iscsi-failfast`). They are bundle content now:
the script side is in the tree, and so in the bundle, and the settings side is in
`role`. Each was ported with its tests; none was merged as a branch.

| fix | script side (bundle `actions/`) | settings side |
| --- | --- | --- |
| suspend state (`suspend-state`): `vm-save` mounts its state dataset | `vm-save`, `vm-restore`; the tests of `test_p3_257` and `test_p3_26` | none: the dataset's mountpoint is set by the script |
| paused-guest resume (`guest-resume`) | `vm-resume`, `vm-status` (`PAUSED <vm> reason=`), `vm-stop` (refuses a paused guest), `check_vms`; the IPS healer (`HPS::GuestHeal`, `IssueHeal`, the issue rules) and their tests | `vm-resume` is in the allowlist of the pinned images (`hps-ctrl-exec.nix`) and of the bundle; no setting |
| fail fast (`iscsi-failfast`) | `leg-resolve`, `mirror-*`: already on `main` (merged through `storage-faults`); the branch's copy is older and was not taken | the 15 s iSCSI timeouts in `iscsid.conf`, the `PROGRAM` and `AUTO -all` of `mdadm.conf` and the `hps-md-event` script, all by `role_compute` and `role_iscsi` |

The error policy and command size of `storage-faults` (`iscsi_max_sectors_kb`, the
`error_policy` of the guest disks) are in the scripts, and `min_free_kbytes` and the
ARC cap in `host-reserve-apply`: all in the bundle already.

### Cold start

A node boots from the IPS alone: the kernel, the initramfs, the bundle, the packages
and the guest images are all served by the IPS. What the node lost with its RAM (the
imported pool, the exports, the mirror, the guest) the operator verbs bring back
from the registry record: `hps-storage <host> up` imports and unlocks the pool and
exports the recorded targets again, `hps-osvc deliver` gives om3 its secret, and
`hps-workload start` assembles the mirror, defines the guest and starts it. Nothing in `init` or `role`
reaches outside the provisioning network (the agent's package, the role's packages
and om3 come from `/packages/` on the IPS; `curl` addresses only `hps.ips`). The
check is the egress proxy's log, which holds no line from the node's address during
the boot (`plans/step3-trial.md`).

## Operating it

| to | do |
| --- | --- |
| give the installation's sysadmin key | write `<config>/sysadmin_authorized_keys` |
| put a locally built package (a new agent) on the IPS | `hps-starter add-local nixos --from <cache> <store path>`, name it in `nixos.packages`, then `hps-starter sync nixos --only repository` |
| bring running nodes to the new agent | `hps-run <host> bundle-refresh` on each (no reboot) |
| see what a node will get | `curl 'http://<ips>/cgi-bin/boot_manager.sh?cmd=node_packages'` from the node; or the IPS log `node packages served` |
| see the bundle a node runs | `ls -l /run/hps/bundle` on the node; the id is in the IPS log line `node bundle served` |
| change an action | change the file under `node-manager/nixos-26/scripts/`, then `hps-run <host> bundle-refresh` |
| see why a node did not come up | its console, or `journalctl -u kernel-command-line` over SSH as `sysadmin` |
| see what a storage or compute node runs | `systemctl list-units 'hps-*' libvirtd iscsid opensvc-daemon` over SSH; the units are in `/run/systemd/system` and say what they run |
| see that guests are confined | on a compute node, `cat /sys/kernel/security/apparmor/profiles` lists the `libvirtd` and `virt-aa-helper` profiles, and `hps-run <host> vm-confinement-report <vm>` says `model=apparmor` with a `libvirt-<uuid>` label |
| see what the monitor gets from a node | `hps-run <host> nagios-check --all`, or `hps-monitor run --host <host>` on the IPS |
| add a program to a role | name it in `nixos.packages`, put it on the role line of `nixos.roles`, `hps-starter sync nixos --only repository`, then `hps-run <host> bundle-refresh`; `role` then finds it, or says `missing programs: ...` |

## Not in this step

The IPS-side sysadmin key extraction by the installer; an Alpine adapter (plan step
4); headless QEMU, which brings the compute node's RAM down (plan step 5); and
`hps-net` on starter nodes (see "What is not carried"). The monitoring checks are
on storage and compute nodes only: a starter node of another `TYPE` has no
`checks.conf` and the IPS's `hps-monitor` gets the action's plain message from it.
