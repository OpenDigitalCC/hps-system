### `check_zfs_loaded`

Contained in `lib/host-scripts.d/common.d/zpool-management.sh`

Function signature: e83726e842477cf79c67cdcf1de046b56eacfafd7f97ba195d70b1f2bccfabc2

### Function Overview

The `check_zfs_loaded` function is used to ensure that the `ZFS` filesystem is installed and enabled in the kernel. It first checks if the `zfs` command is available. If the command is not found it will notify the user and return an error code. If the command is found, the function then checks if the ZFS kernel module is loaded using the `lsmod` and `grep` commands. If the module is not loaded, the function will attempt to load it using `modprobe`. If successful, it notifies the user and returns a success code. Otherwise, it notifies the user of the failure and returns an error code.

### Technical Description

Definition Block:

- **Name**: `check_zfs_loaded`
- **Description**: A bash function to check whether the `ZFS` filesystem is installed and enabled in the kernel on the current system.
- **Globals**: None.
- **Arguments**: None.
- **Outputs**: Echoes information to the console regarding the state of the `ZFS` filesystem and its kernel module.
- **Returns**: `1` if the `ZFS` command is not found or the kernel module fails to load; `0` otherwise.
- **Example Usage**: 
    ```bash
    check_zfs_loaded
    if [ $? -eq 0 ]; then
        echo "ZFS is installed and loaded"
    else
        echo "ZFS is either not installed or not loaded"
    fi
    ```

### Quality and Security Recommendations

1. The function should validate the return status of the `command -v zfs` and `modprobe zfs` calls directly to avoid false positives in case of error situations.
2. The function could handle more error scenarios, such as failing to run `modprobe`.
3. Other tuning parameters could be checked to ensure optimal ZFS performance, such as the zfs module option values.
4. To enhance security, consider ensuring that the function is run with the right permissions, as loading/unloading kernel modules typically requires root access.
5. This function could be supplemented by implementing additional checks, such as whether or not a given ZFS pool or filesystem exists.

