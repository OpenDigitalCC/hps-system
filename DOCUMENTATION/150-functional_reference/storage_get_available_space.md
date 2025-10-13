### `storage_get_available_space`

Contained in `lib/host-scripts.d/common.d/storage-management.sh`

Function signature: 0ecd662d000f3348b1348219cc1c7541ead05b93b29de5edfc244de079f38d03

### Function overview 

The function `storage_get_available_space` is a bash function used to find out the available space in a specific ZPOOL. The function uses ZFS commands to determine the amount of available space in the ZPOOL. It first fetches the ZPOOL name from a remote host and then checks if the ZPOOL name could be fetched successfully. It then queries ZFS for the available space in that ZPOOL and logs an error if this is not successful. Finally, it echos the available space in bytes and returns 0 on successful execution.

### Technical description
- **Function name**: `storage_get_available_space`
- **Description**: This function retrieves the available storage space in a specified ZPOOL residing on a remote host. The ZPOOL name is obtained via the remote_host_variable function.
- **Globals**: [`ZPOOL_NAME`: the ZPOOL's name in the remote host]
- **Arguments**: None
- **Outputs**: 
  1. Logs errors if the ZPOOL name cannot be determined, or if ZFS fails to retrieve available space.
  2. Prints the available space in bytes if the function executes successfully.
- **Returns**: 
  1. If the ZPOOL name cannot be determined or ZFS fails to retrieve available space, the function returns `1`.
  2. Upon successful execution, the function returns `0`.
- **Example usage**: `storage_get_available_space`

### Quality and Security Recommendations
1. Ensure that the remote_host_variable and remote_log functions are secure and cannot be exploited to execute remote shell commands.
2. Make sure that error logs do not reveal sensitive information about the system, which could be utilized by an attacker.
3. Validate the output of the zfs get command to ensure it can't be manipulated to inject malicious code.
4. Check the network connection between the local and remote systems securely to prevent MITM (Man in the Middle) attacks.
5. Consider adding more error handling and logs for network issues or ZFS failures.
6. Regularly update the ZFS command-line tools to benefit from the most recent security patches and improvements.

