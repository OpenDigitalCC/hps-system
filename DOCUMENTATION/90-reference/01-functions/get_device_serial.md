#### `get_device_serial`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 8e1b210627973a0cc629e646a16460819b61ae08954c5dba162358f2b6cb4532

##### 1. Function overview

The `get_device_serial` function is a bash function designed to retrieve the serial number of a device. This function utilizes the `udevadm` command-line utility and the `grep` and `cut` command to extract the serial number from the device properties.

##### 2. Technical description 

- **Name**: `get_device_serial`
- **Description**: This function retrieves the Serial Number of a specified device. It utilizes `udevadm` utility to query device properties and then filters out the Serial Number from the queried properties.
- **Globals**: None.
- **Arguments**: 
  - `$1`: The device for which the serial number is to be retrieved.
- **Outputs**: The Serial Number of the provided device, or "unknown" if the serial number cannot be determined.
- **Returns**: Nothing.
- **Example usage**: `get_device_serial /dev/sda1`

##### 3. Quality and security recommendations

1. The function does not handle the cases where the `udevadm` command is not installed or accessible on the system. It's recommended to add a check before executing the `udevadm` command.
2. Tot prevent running with improper arguments, the function should include an initial check to ensure that the proper argument (device name) is provided.
3. Output should be sanitized to prevent potential command injection or processing of unintended data.
4. Include more comprehensive error handling and output informative error messages for better maintainability and debugging.
5. For maximum security, ensure this function runs with minimum required permissions to avoid potential privilege escalation attacks.

