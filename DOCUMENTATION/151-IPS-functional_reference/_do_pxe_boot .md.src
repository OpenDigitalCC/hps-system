### `_do_pxe_boot `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: 34359020b853100f39729c1ec34d66fe43cbe72d4231aa30342ee1342e7faf69

### Function Overview

The function `_do_pxe_boot` is a bash function that takes two arguments, a kernel and an initrd (initial RAM disk). It checks if these parameters are non-empty and logs an error if they are. If everything is in order, it logs some debug information, creates an iPXE boot install script with the given parameters and a datestamp, and then outputs this script.

### Technical description

- **name**: `_do_pxe_boot`
- **description**: Boots the system over a network via iPXE method with the provided kernel and initrd. It generates iPXE boot commands on the fly and outputs them for further usage.
- **globals**: [ IPXE_BOOT_INSTALL: stores the boot script for iPXE ]
- **arguments**: [ $1: The specified kernel to boot, $2: The initial RAM disk to be used while booting ]
- **outputs**: The iPXE boot script as printed to the stdin.
- **returns**: Error state 1 if either a kernel or an initrd were not given. Else nothing is returned.
- **example usage**: 

```bash
_do_pxe_boot "vmlinuz" "initrd.img"
```

### Quality and Security Recommendations

1. Validate the arguments not only for non-emptiness but also for their correct format and for being legitimate files existing in the system.
2. Consider utilizing more distinctive log levels during logging operations for more precise troubleshooting.
3. Through incorporating error handling mechanisms, ensure that the function behaves properly even under unexpected conditions.
4. Always quote the variables in bash to avoid word splitting and pathname expansion.
5. Avoid the usage of uppercase for non-global and non-readonly variables to prevent name clashes with shell variables.

