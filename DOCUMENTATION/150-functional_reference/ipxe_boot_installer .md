### `ipxe_boot_installer `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: c73d78c14795c1c7103969e913c3a8552641445fa9ab836f6ca2f3323647ace0

### Function Overview

The `ipxe_boot_installer()` function primarily configures a host for the new network boot installation. It takes two positional arguments, `host_type` and `profile`. If a profile is provided, it sets the `HOST_PROFILE`. If the host type is "TCH", it configures the host for network boot and forces a reboot. Else, it gathers host type parameters, checks if it's already installed, and finally configures the distro path and URL. It then appropriately prepares the distro for PXE Boot based on the OS Name (currently validated for rockylinux) and sets the state as installing.

### Technical Description

- **function name:** `ipxe_boot_installer()`
- **description:** Configures a host for network boot installation. Supports rockylinux based distros.
- **globals:** 
  - `CPU`: The type of CPU of the host
  - `MFR`: The manufacturer
  - `OSNAME`: The name of the operating system 
  - `OSVER`: The version of the operating system 
- **arguments:** 
  - `$1 (host_type)`: The type of host.
  - `$2 (profile)`: A profile for the host. Optional.
- **outputs:** Debug/Info log messages, and/or installation configurations. In case of errors, outputs back to invoking client.
- **returns:** Nothing directly. It can exit the script in case of boots or failures.
- **example usage:** `ipxe_boot_installer TCH default`

### Quality and Security Recommendations

1. Headers should include error handling with proper message propagation; this helps in operations debugging and error handling.  
2. Key dependencies, like external scripts/functions used, should be documented.
3. The function does not currently support Debian distros. Future enhancements should cover more distributions for broader usefulness.
4. Use of local variables can be increased for safer namespace and avoid potential global variable overwrites.
5. Where possible, function arguments should be sanity checked or validated.
6. For security purposes, it is strongly recommended to verify the integrity of the distro before execution.

