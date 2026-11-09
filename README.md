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

HPS is designed to be mounted inside a Debian-based container at:  

```bash
/srv/hps-container


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
sudo docker compose exec hps /srv/hps/cluster-configure.sh
```

This script:
- Initializes the configuration directory `/srv/hps-config` if it doesn't exist
- Prompts for new or existing cluster configuration
- Saves structured values to `.cluster` files and global `hps.conf`
- Prepares the system for PXE/TFTP/DHCP boot services

## 📁 Directory Structure

```
└── hps-system
    ├── cli
    │   ├── check-and-download-rocky.sh
    │   ├── cluster-configure.sh
    │   ├── reload.sh
    │   └── test.sh
    ├── http
    │   ├── cgi-bin
    │   └── distros
    ├── lib
    │   ├── functions.d
    │   └── functions.sh
    ├── log
    ├── README.md
    ├── scripts
    │   ├── cluster-config.d
    │   ├── hps-initialise.sh
    │   └── run-hps.sh
    ├── templates
    │   └── script-init-boilerplate.sh
    ├── tftp
    │   ├── ipxe.efi
    │   ├── snponly.efi
    │   └── undionly.kpxe
    └── update-paths.sh

```



## 📚 Configuration

Global config is saved in `/srv/hps-config/hps.conf` and sourced by:
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
3. Power on `$NODE` on the provisioning network. Its audit appears under
   `hps-onboard show $MAC`.
4. Assign it: `hps-onboard assign $MAC --type $TYPE --profile $PROFILE --os $OS`.
5. Reboot `$NODE`; it pairs with the IPS over ctrl-exec. Run node operations
   with `scripts/hps-run.sh $NODE <script> [args]`.

Where to read more:

- `docs/LOGGING.md` – where every IPS service and every node logs.
- `docs/SECURITY.md` – *Node identity at boot* (MAC on the provisioning
  network, no secret in an image) and *Node scripts under the executor*.
- `docs/adr/0002-ctrl-exec-enrolment-trust.md` – registry-bound approval of
  node pairing, including the `HELD` audit image and the per-boot pairing
  window.
- `docs/adr/0003-ctrl-exec-agent-packaging.md` – agent delivery; the
  2026-11-09 amendment covers NixOS nodes and the executor.
- `CHANGELOG.md` – the phase 1 span, and `.nonfunctional-report.md` for the
  state of the trial against the eight audit dimensions.

## Performance

To install a new storage node on a virtual machine, using a commodity home PC takes about 7 minutes and 3 key-presses.


# Getting started

You need hardware, the IPS and a download of your preferred O/S. Rocky 10 has been used for testing.

## Hardware requirements

### Initial Provisioning Node

- Docker container
- Storage 10GB (Redhat DVD)

### Storage node:

- Base O/S: min 30GB
- Swap: min 20GB
- Storage service: As you wish, probably 100G or more
- RAM: 16GB min, as much as you have


# Troubleshooting

Watch the console for errors, and alsop the logfile which is probably too verbose. Grep for the MAC address for server-specific info.

Common issues:

- insufficient disks - see minimum disk sizes for redhat-based distros
- BIOS not set to boot the disk before the network


# How to help

- Download, install, PR


