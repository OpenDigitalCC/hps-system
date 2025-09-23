### `ipxe_boot_installer `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: ad6c7317bbb7a71cfcd8f86037b9440faaacb0b1a309a4e03c807b567e589b21

### Function overview

The `ipxe_boot_installer` function is part of a Bash script designed to perform automated installations of operating systems on target hosts over networks using the iPXe boot firmware. The function takes in two positional parameters: `host_type`, and `profile`. The function interacts with global configurations to identify the host's hardware and corresponding OS requirements. Then, it begins the process of mounting the necessary boot images and preparing the host for installation. If the function detects a previously installed OS on the host, it will abort the installation to prevent damage. The function currently supports installations for `rockylinux` and has placeholder cases for `debian` and other operating system types, although these are not yet implemented.

### Technical description

- **Name:** ipxe_boot_installer
- **Description:** This function prepares a target host for a network-based OS installation using the iPXe boot firmware.
- **Globals:** 
  - **HPS_DISTROS_DIR**: Directory where the necessary boot files for each OS/hardware setup are stored.
  - **mac**: Global unique mac address of the host.
  - **CGI_URL**: URL for CGI services.
- **Arguments:**
  - **$1: host_type**: Specifies the type of the target host.
  - **$2: profile**: Describes a specific configuration profile for the operating system to be installed.
- **Outputs:** Installation script steps to standard output, as well as debug or error logs.
- **Returns:** Varies based on multiple conditional branching. Often, failure cases will terminate script execution.
- **Example usage:**

    ```
    ipxe_boot_installer rockylinux default
    ```
    
### Quality and security recommendations:

1. Implement error handling for critical steps to prevent script failure.
2. Integrate exception handling to ensure clean termination during a fail state, including unmounting of ISO or other resources.
3. Clean up or secure temporary files used to store iPXe boot install scripts. These may contain sensitive data or configuration details.
4. Implement timeouts or checks to confirm a boot image loads successfully.
5. Hash-check downloaded distros to verify their integrity.
6. As functionality grows, consider creating multiple functions for different OS installations rather than adding more conditional branches to this function.

