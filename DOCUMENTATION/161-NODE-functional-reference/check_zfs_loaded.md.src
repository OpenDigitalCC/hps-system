### `check_zfs_loaded`

Contained in `node-manager/rocky-10/zpool-management.sh`

Function signature: e83726e842477cf79c67cdcf1de046b56eacfafd7f97ba195d70b1f2bccfabc2

### Function overview

The function `check_zfs_loaded` is responsible for detecting the presence of the ZFS command and its kernel module in the system. It first verifies if the `zfs` command is available. If it is not found, the function ends with a status code 1. If the command is available, it is checked if the ZFS module is currently loaded in the system. If the module is not loaded, an attempt is made to load it using `modprobe`. If the loading operation fails, the function returns 1, signaling the problem to the caller.

### Technical description

- **name**: `check_zfs_loaded`
- **description**: Checks whether the `zfs` command is available and if the ZFS kernel module is loaded. If the ZFS module is not loaded, tries to load it.
- **globals**:  None
- **arguments**:  None
- **outputs**: Diagnostic messages on console about the availability of `zfs` command and the ZFS kernel module status.
- **returns**: 0 if `zfs` command is available and ZFS kernel module is loaded or was able to load; 1 otherwise.
- **example usage**: `check_zfs_loaded`

### Quality and security recommendations

1. Avoid using `echo` to pass error messages. Instead, use the STDERR stream to prevent interfering with STDOUT. 
2. Ensure the script is run by a user with sufficient permissions, especially for executing commands like `modprobe`. Validate the user's permissions before running such commands. 
3. Apply error handling to catch and handle unexpected issues properly. Consider the potential failures of each command used in the function.
4. Document the function and its expectations more comprehensively. The script’s users or maintainers will benefit from a clear description of its expected inputs, outputs and error cases.
5. Potentially dangerous operations, like loading a kernel module, should be performed with caution. Confirm this action with the user before proceeding.

