# HPS System

The hps-system is the Magrathea - "Magrathea was the planet whose business it was to build other planets." — Douglas Adams, The Hitchhiker's Guide to the Galaxy.


This package contains the **core logic and configuration** for the Host Provisioning Service (HPS). It is designed to be mounted inside a Debian-based container at:

```
/srv/hps
```



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


