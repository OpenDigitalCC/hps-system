### HPS system documentation

#### Overview

- **Project introduction** – Purpose of HPS, architecture, intended use cases.
- **Design decisions** – Records of key technical choices and rationale.
- **System components** – Description of major directories and modules.

#### Quick start

- **Prerequisites** – Required host operating system, packages, and network setup.
- **Installation** – Deploying `hps-container` with `hps-system` and `hps-config`.
- **First cluster setup** – Initialising a cluster with `cluster-configure.sh`.
- **Booting a host** – PXE boot process and selecting a host profile.
- **Verification** – Checking service status and logs.

#### System administration

- **Directory layout** – Locations for configuration, logs, distributions, and packages.
- **Cluster management** – Creating, switching, and editing clusters.
- **Host management** – Adding, removing, and updating host configurations.
- **Distribution and repository management** – Managing ISOs, PXE trees, and package repositories.
- **Service management** – Starting, stopping, and reloading dnsmasq, nginx, and supervisord.
- **Backup and restore** – Protecting and recovering configuration and repository data.

#### Functions reference

- Automatically generated from `lib/functions.d/` and other libraries.
- One function per page with purpose, arguments, usage examples, and related functions.

#### Advanced configuration

- **Kickstart and preseed templates** – Structure, variables, and customisation.
- **iPXE menus** – How menus are built and extended.
- **Storage provisioning** – SCH node disk detection, reporting, and configuration.
- **Integration points** – Hooks for OpenSVC, monitoring, and external systems.

#### Troubleshooting

- **PXE boot issues** – Common causes and fixes.
- **Service failures** – Diagnosing and restarting services.
- **Distribution and repository problems** – Checksums, GPG keys, and synchronisation errors.
- **Network problems** – DHCP conflicts, VLAN configuration, and firewall blocks.

#### Development

- **Code layout** – File structure and conventions for scripts and libraries.
- **Adding functions** – Naming, argument handling, logging, and documentation guidelines.
- **Testing** – Using `cli/test.sh` and other test harnesses.
- **Contributing** – Workflow, coding standards, and submission process.

#### Appendices

- **Glossary** – Definitions of terms and acronyms used in HPS.
- **Environment variables** – Description of exported variables and their use.
- **Decision records** – Full list of design decisions.
- **Reference configurations** – Example cluster, host, and service configuration files.

