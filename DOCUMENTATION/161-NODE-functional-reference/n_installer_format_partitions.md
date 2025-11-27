### `n_installer_format_partitions`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: 0b4a0dbbfa19524cd835648932858b139e035c5ca2a01459ac2743b4c74bb981

### Function overview

The `n_installer_format_partitions` function is used in Bash to format and mount partitions on boot and root devices. It starts by logging the start of partition formatting, reads device paths from host_config, checks for mkfs.ext4 availability, formats boot and root partitions, fetches UUIDs, stores them to host_config, mounts root and boot partitions, creates essential directories, creates a swap file of 1GB, generates a static filesystem table (/etc/fstab), and ends by logging the completion of partition formatting and successful mount locations.

### Technical description

- **Name**: `n_installer_format_partitions`
- **Description**: This function formats and mounts partitions on boot and root devices.
- **Globals**: `boot_device`: Contains the file path for the boot device; `root_device`: Contains the file path for the root device.
- **Arguments**: This function does not have explicit arguments but uses devices defined in the host configuration.
- **Outputs**: Logs messages that indicate the status and results of each operation.
- **Returns**: Returns `1` if it fails to read `boot_device` or `root_device` from host_config or if `boot_device` or `root_device` is empty. Returns `2` if formatting, installation of `e2fsprogs`, or fetching UUIDs fail, while `3` if mounting of any partition fails, and `4` if creation or initialization of swap file or fstab fails. Returns `0` on successful execution.
- **Example usage**: This function is primarily intended to be used within the boot and installation scripts, hence it is typically not invoked manually.

### Quality and security recommendations

1. Validate user inputs or data retrieved from host configurations to prevent potential errors or code injection.
2. All operations that may fail due to factors beyond control (like file system operations) are correctly handled with error checks.
3. Logging of all significant actions is a good practice for future debugging.
4. Clearing of any sensitive data when it's no longer needed.
5. Prevent command injection by always using absolute paths to programs rather than relying on the user's `$PATH`. Make sure any dynamically constructed commands are correctly escaped.
6. Avoid using temporary files to store sensitive information.
7. Use silent or quiet flags in command to avoid exposing unnecessary details to the user.
8. Always use the latest stable version of all software and libraries and routinely update them to get the latest security updates and bug fixes.

