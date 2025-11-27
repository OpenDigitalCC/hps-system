### `n_rescue_unmount_recursive`

Contained in `node-manager/alpine-3/RESCUE/rescue-functions.sh`

Function signature: dbc9f7811032cf5f35fbc50a136a70298422f1e6f87faa3008065c8e35170161

### Function overview

The `n_rescue_unmount_recursive` function is a bash function specifically designed to unmount a given mount point in a Linux system. The function takes a `mount_point` as input and performs a series of operations to unmount it. It first checks if the `mount_point` is not empty and then verifies if the `mount_point` is mounted before proceeding to unmount it. The function will attempt a recursive unmount if the mount is detected, and in case of failure, it will then try unmounting the specific bind mounts individually. If all these unmount attempts fail, the function log an error message and returns 1.

### Technical description

- **Function name**: `n_rescue_unmount_recursive`
- **Description**: The function is designed to unmount a mount point recursively. If the recursive unmount fails, it attempts to unmount the bind mounts individually.
- **Globals**: `n_remote_log`: Used to log information, debug, and error messages.
- **Arguments**: 
  - `$1: mount_point`: A string representing the mount point in the filesystem.
- **Outputs**: Debug, information, error messages regarding unmount attempts. Success or failure of unmounting is also outputted.
- **Returns**: 
  - `0` if the mount point is successfully unmounted or already unmounted.
  - `1` if the mount_point is undefined or the unmount operation fails.
- **Example usage**: 
```bash
n_rescue_unmount_recursive "/mnt/point_to_unmount"
```  

### Quality and security recommendations

1. A validation to ensure that the given `mount_point` actually exists in the filesystem can be added, to avoid attempts to unmounting non-existent mount points.
2. Injecting user-controlled input directly into the system command could lead to potential command injection vulnerabilities. Always sanitize the user input before using it in the system commands.
3. Consider using a more robust logging mechanism that will help in understanding the system state and debug issues effectively when necessary.
4. Performance can be improved by executing the unmounting of the bind mounts in parallel.
5. Implement a guard against re-entrant calls.
6. Consider checking and handling other potential errors returned by the `umount` command.

