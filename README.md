# MENDr Platform  

**MENDr: because recovery is part of the lifecycle, not an afterthought.**  


## 🌍 Mission  

MENDr is an open-source platform for managing infrastructure across its full lifecycle: **build, run, grow, and disaster recovery**.  

It treats recovery as a first-class concern, ensuring that repair and restoration are built into the same workflows that create and scale systems.  
By making resilience part of everyday operations, MENDr helps communities run infrastructure that can adapt, heal, and keep going.  

> “Magrathea was the planet whose business it was to build other planets.”  
> — Douglas Adams, *The Hitchhiker’s Guide to the Galaxy*  

## 📌 Project Status  

This is an **ALPHA release**.  

- The overall logic is sound.  
- Implementation details are still evolving.  
- Expect frequent changes until the first stable release.  

> The original working title was HPS (Host Provisioning System) -  it is now known as the MENDr platform.


## 🤝 Contributing

Contributions are welcome!

    Fork the repo and open a PR.

    File issues for bugs, ideas, or improvements.

    See CONTRIBUTING.md (to be added) for guidelines.


## 🏗️ Platform Structure  

MENDr is designed to be mounted inside a Debian-based container at:  

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


