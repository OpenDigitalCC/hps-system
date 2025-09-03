### `ipxe_boot_installer `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: ad6c7317bbb7a71cfcd8f86037b9440faaacb0b1a309a4e03c807b567e589b21

### Function overview

The function `ipxe_boot_installer ()` automates the process of PXE booting installation for new hosts in a network using iPXE (an open-source network boot firmware). It takes in the host type and the desired profile, and then retrieves the necessary parameters such CPU, Manufacturer (MFR), Operating System Name (OSNAME) and Version (OSVER). It also checks whether the new host is already installed, and exits if that is the case. The function currently supports `rockylinux` but has placeholders for `debian`.

### Technical description

- name: `ipxe_boot_installer`
- description: This function manages configuration and boot of PXE for a new host installation.
- globals: 
  - `$HPS_DISTROS_DIR`: Directory path to the list of supported distributions.
  - `mac`: The MAC address of the host.
  - `CGI_URL`: The URL of the CGI script to generate the kickstart file.
- arguments: 
  - `$1: host_type`: Type of the host, e.g. server, workstation.
  - `$2: profile`: The desired profile.
- outputs: The function outputs a string representation of a iPXE boot script.
- returns: Returns nothing. However, in case of error, it terminates and echoes an error message.
- example usage: 
  ```
  ipxe_boot_installer workstation minimal
  ```

### Quality and security recommendations

1. Make sure that the `HPS_DISTROS_DIR` points to a secure and reliable source for the distributions. 
2. Avoid hard-coding URLs and paths inside the function. Instead, pass them as arguments or set them in a separate configuration file. 
3. Check that all globally used variables, like `mac` and `CGI_URL`, are safely defined and handled to avoid overwriting or misusage. 
4. Add support for other distribution types, such as Debian, to heighten the function's versatility.
5. Implement proper error handling and logging to identify and resolve issues quickly, contributing to function robustness.
6. Finally, to enhance security, in cases of failure, consider using placeholders for logging error messages that avoid printing sensitive information (like file paths, URLs, or parameter values).

