### `check_zfs_loaded`

Contained in `lib/host-scripts.d/common.d/zpool-management.sh`

Function signature: e83726e842477cf79c67cdcf1de046b56eacfafd7f97ba195d70b1f2bccfabc2

### Function Overview

The `check_zfs_loaded` function checks whether the ZFS (Zettabyte File System) is installed and operational on the machine where the script is running. If the ZFS command isn't found or the ZFS kernel module isn't loaded, the function attempts to perform the necessary actions and gives feedback on the actions performed. The function ultimately returns 0 if the system passes all checks; otherwise it returns 1.

### Technical Description

#### Name
`check_zfs_loaded`

#### Description
This bash function checks two conditions: if the ZFS command is found on the system, and if the ZFS kernel module is loaded. If any of these conditions is not met, it prompts the user with an error message. Moreover, if the ZFS module is not loaded, it attempts to load it using the `modprobe` function. This operation might require superuser privileges.

#### Globals
None.

#### Arguments
No arguments taken.


#### Output
The function outputs to stdout:

- A successful or unsuccessful message indicating ZFS command installation status.
- A status update on whether the ZFS module is loaded, whether a load attempt was made, and whether that was successful.

#### Returns
- `1`: if either the ZFS command is not found OR the ZFS module failed to load.
- `0`: if the ZFS command is found AND the ZFS module is successfully loaded.

#### Example Usage
```bash
if check_zfs_loaded; then
  echo "ZFS is ready to use."
else
  echo "ZFS is not properly set up."
fi
```

### Quality and Security Recommendations

1. Authentication Check: The function should check if the user has required permissions to perform actions such as loading a kernel module using `modprobe`. Otherwise, it could misleadingly signal a failure when the underlying issue is a lack of permission.
2. Error Catching: It might be beneficial to add additional error handling or checking. For example, catching and further diagnosing errors that result from the `command` or `modprobe` functions could provide more clarity as to what caused a failure.
3. Reliable Checking: Checking presence of ZFS only through presence of `zfs` command and loading status of module might not fully confirm its operational status. Integrate a more reliable way of verifying whether ZFS is properly working, such as creating a test file on a ZFS filesystem.
4. Logging: Consider adding logging for better troubleshooting capabilities. Rather than just echoing the status, also write it into a log file.
5. Use Safe Bash Flags: Consider setting safe bash flags (`set -euo pipefail`) at the beginning of your scripts to avoid certain common bash pitfalls.

