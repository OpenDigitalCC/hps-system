# HPS Platform  

**HPS: because recovery is part of the lifecycle, not an afterthought.**  


## 🌍 Mission  

HPS is an open-source platform for managing infrastructure across its full lifecycle: **build, run, grow, and disaster recovery**.  

It treats recovery as a first-class concern, ensuring that repair and restoration are built into the same workflows that create and scale systems.  
By making resilience part of everyday operations, HPS helps communities run infrastructure that can adapt, heal, and keep going.  

Often clusters have many points of storage, lots of hosts accepting ssh, firewalls, etc which means there are lots of places to back up, lots of types of backup, many places to control access and this creates complexity. By keeping functional focus, the job of maintaining and upgrading is simpler. Storage is focused on one or tweo places, deployment of new nodes is one click, and upgrades can be rolled back.

HPS can be nested, so a simple HPS infrastructure can be used to manage many HPS platforms. 

> “Magrathea was the planet whose business it was to build other planets.”  
> — Douglas Adams, *The Hitchhiker’s Guide to the Galaxy*  

## 📌 Project Status  

This is an **ALPHA release**.  

- The overall logic is sound.  
- Implementation details are still evolving.  
- Expect frequent changes until the first stable release.  

> The working title is HPS (Host Provisioning System)


## 🤝 Contributing

Contributions are welcome!

    Fork the repo and open a PR.

    File issues for bugs, ideas, or improvements.

    See CONTRIBUTING.md (to be added) for guidelines.


## 🏗️ Platform Structure  

HPS runs inside the Debian-based IPS container (the `hps-container` repository), which mounts the host's `/srv` as `/srv`. This tree is installed at:

```bash
/srv/hps-system
```


### Software infrastructure

Layer 0: Docker (compose) installation

Layer 1: hps-system installation

Layer 2: hps initialisation

Layer 4: cluster configuration

Layer 5: storage host configuration

Layer 6: compute host configuration

### Service plane


## 📦 How to Start

Once your container is running, begin setup with:

```bash
sudo docker compose exec hps /srv/hps-system/cli/cluster-configure.sh
```

For a non-interactive setup use `scripts/cluster-bootstrap.sh` (see "NixOS nodes and the lab IPS" below).

This script:
- Initialises the configuration directory `/srv/hps-config` if it doesn't exist
- Prompts for new or existing cluster configuration
- Saves structured values to the cluster configuration and global `hps.conf`
- Prepares the system for PXE, TFTP and DHCP boot services (served by dnsmasq)

## 📁 Directory Structure

```
└── hps-system
    ├── bin                  hps-* commands (hps-onboard, hps-bmc, hps-jobs, ...)
    ├── cli
    │   ├── cluster-configure.sh
    │   ├── manage-distros.sh
    │   ├── reload.sh
    │   └── ...
    ├── docs                 reference documents and adr/
    ├── http
    │   ├── api
    │   └── cgi-bin
    ├── lab                  rig scripts for the NixOS lab trial
    ├── lib
    │   ├── functions.d
    │   ├── functions.sh
    │   ├── hps-system.sh
    │   └── perl             HPS::* modules
    ├── node-manager         per-OS node scripts (nixos-26, alpine-3, ...)
    ├── nix                  flake modules and the image builder
    ├── scripts
    │   ├── cluster-bootstrap.sh
    │   ├── cluster-config.d
    │   ├── run-hps.sh
    │   └── tests            bats tests
    ├── t                    Perl tests
    ├── templates
    └── tftp
        ├── ipxe.efi
        ├── snponly.efi
        └── undionly.kpxe

```



## 📚 Configuration

Global config is saved in `/srv/hps.conf` (created by `lib/hps-system.sh`; it holds the four base paths under `/srv`: `hps-system`, `hps-config`, `hps-resources` and `hps-log`) and sourced by:
- cluster configurator fragments
- service startup scripts

See the `hps-container` README for runtime container info.

## NixOS nodes and the lab IPS

HPS can netboot NixOS 26.05 nodes straight into RAM from the IPS. An unknown
host is held (`STATE=HELD`) and boots an audit image, never a menu; a human
then assigns it a role, and its next boot is the node image. The first
hardware trial of this path is described in the project plan
`plans/phase-1.md` (kept beside the repository, not in it).

The usual sequence, with placeholders:

1. Bootstrap the cluster non-interactively: `scripts/cluster-bootstrap.sh`
   (network `$NETWORK`, IPS address `$IPS_IP`, DHCP interface `$IFACE`).
2. Build the images in the builder container (`nix/build.sh`); the artefacts
   land under `hps-resources/nixos/<pin>/<profile>/`.
3. Power on `$NODE` on the provisioning network. It boots the audit image,
   posts its audit and reboots by itself. Its audit appears under
   `hps-onboard show $MAC`.
4. The rebooted node waits at iPXE, asking the IPS again every
   `hold_retry_seconds` (default 30; cluster key). Nothing needs power control
   from here. `hps-onboard reaudit $MAC` makes the next retry run the audit image
   again (at most `audit_max_concurrent` audits run at once, default 2; the rest
   wait in the hold loop with "waiting for an audit slot", docs/IPXE.md); setting
   the cluster key `held_reboot_after_audit` to `false` keeps the
   audit image up after the audit, so a held node can be inspected over ctrl-exec.
5. Assign it: `hps-onboard assign $MAC --type $TYPE --profile $PROFILE --os $OS`.
   The node's next retry boots its role image with no power action; it pairs
   with the IPS over ctrl-exec. Run node operations with
   `scripts/hps-run.sh $NODE <script> [args]`.

Where to read more:

- `docs/LOGGING.md` – where every IPS service and every node logs.
- `docs/IPS-CHECK.md` – the IPS self-check run after every start
  (`bin/hps-ips-check`) and how to read its result.
- `docs/SECURITY.md` – *Node identity at boot* (MAC on the provisioning
  network, no secret in an image) and *Node scripts under the executor*.
- `docs/adr/0002-ctrl-exec-enrolment-trust.md` – registry-bound approval of
  node pairing, including the `HELD` audit image and the per-boot pairing
  window.
- `docs/adr/0003-ctrl-exec-agent-packaging.md` – agent delivery; the
  2026-11-09 amendment covers NixOS nodes and the executor.
- `docs/adr/0007-authorisation-is-ctrl-exec.md` – who may run a destructive
  action is ctrl-exec's decision; HPS's signed approvals are removed.
- `CHANGELOG.md` – the phase 1 span, and `.nonfunctional-report.md` for the
  state of the trial against the eight audit dimensions.

## Performance

To install a new storage node on a virtual machine, using a commodity home PC takes about 7 minutes and 3 key-presses.


# Getting started

You need hardware and the IPS. Nodes boot into RAM from the IPS (NixOS 26.05 images built with `nix/build.sh`), so a node needs no installed operating system.

## Hardware requirements

### Initial Provisioning Node (IPS)

- Docker container (the `hps-container` repository), host networking
- Storage for the images under `/srv/hps-resources`

### Nodes

- Boot from the network (UEFI PXE)
- RAM for the node image and its workload; a storage node also needs data disks, named by `by-id` path


# Troubleshooting

Watch the console for errors, and alsop the logfile which is probably too verbose. Grep for the MAC address for server-specific info.

Common issues:

- a storage node without the data disks its role needs
- BIOS or UEFI not set to boot from the network


# How to help

- Download, install, PR


