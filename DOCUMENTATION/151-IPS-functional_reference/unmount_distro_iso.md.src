### `unmount_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: e11fdcfe99e864f4cee9a16d324b9d48b2ee3fa3525026c1dd2e8c8f233b0e61

### Function overview

The `unmount_distro_iso()` function has been designed to help unmount a Linux distribution's ISO file. It accepts a distribution identifier or path to the ISO file as an argument and proceeds to determine the mount point and check if this is currently in use. If it's mounted, the function attempts to unmount it, first through a normal unmount command and then via a lazy unmount if the first approach fails.

### Technical description

- **Name**: unmount_distro_iso
- **Description**: Function to unmount a Linux distribution's ISO file.
- **Globals**: None.
- **Arguments**: 
    - `$1: os_id_or_path` - A string that represents either the distribution identifier or the absolute path to the ISO file.
- **Outputs**: Logs messages to indicate the unmounting process status (not mounted, successful unmount, lazy unmount, or failed unmount).
- **Returns**: 
    - `0`: If the unmount process is successful or the mount point is not in use.
    - `1`: If the unmount process fails.
- **Example Usage**: 
```bash
unmount_distro_iso "/path/to/iso"
unmount_distro_iso "distro_id"
```

### Quality and security recommendations

1. Ensure to validate and sanitize the `os_id_or_path` input to protect against path traversal or any form of injection attacks.
2. Always check and handle error conditions appropriately. In the situation where both normal and lazy unmount fails, the function should handle this condition properly and not proceed assuming the unmount was successful.
3. Consider adding more descriptive logging messages to help with debugging if an error occurs.
4. Validate the provided mount point before trying to unmount. Confirm that it exists and is indeed a mount point to prevent unintended behavior.
5. Implement some form of logging system that handles log rotation and log levels. This would prevent your disk space from being filled up by logs and control the verbosity of your logs.

