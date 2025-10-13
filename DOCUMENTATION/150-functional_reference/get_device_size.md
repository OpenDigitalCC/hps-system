### `get_device_size`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 1d4e207d13b80b5424975cd10a3ed7197f78e6832fbbf6662e417abdd6def6d2

### Function Overview

The `get_device_size` function is a bash function that accepts a device name as an argument and then obtains the size of the device using the `lsblk` command. If the device size cannot be determined, it will output "unknown".

### Technical Description

- **Name**: `get_device_size`
- **Description**: This function retrieves the size of a specified device. It utilizes the `lsblk` command and, in the event the device size cannot be determined, it outputs the string "unknown".
- **Globals**: None
- **Arguments**: 
  - `$1`: The device whose size is to be determined. It is usually a block device-like "/dev/sda".
- **Outputs**: The size of the device. If the size can't be determined, it outputs the string "unknown".
- **Returns**: The status of execution of the last command executed, typically the `lsblk` command.
- **Example Usage**: `get_device_size "/dev/sda"`

### Quality and Security Recommendations

1. Since the function performs operations on block devices, it should have proper error checking and handling. This would help in maintaining the integrity of the device and prevent any data loss.
2. Validate the input to the function to ensure that it is a valid device name.
3. The function echoes "unknown" when it can't determine the device size. It might be better to return a specific error code for this situation.
4. Consider adding checks to ensure that the required utilities (`lsblk` in this case) are available on the system. This could prevent errors from occurring due to missing utilities.
5. It's always a good idea to run scripts as a non-root user when possible. If this function needs root privileges, make sure you handle that securely.

