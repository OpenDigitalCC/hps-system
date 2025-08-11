#### `get_device_type`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: c04dccee20f8398f1cc00c1f339464f78c0ea09416025a9627dcbd45477ea68d

##### Function Overview
The `get_device_type` function is a bash shell function designed to determine the device type of a specified device. The function accepts a device name as an argument, and uses `udevadm` info query method to get the relevant properties of the device. It then parses the output to extract the ID_TYPE value. If no such value is found, it defaults to assume that the device is a disk.

##### Technical Description
- **Function name:** `get_device_type`
- **Description:** The function determines the device type of a specified device using the `udevadm` utility. If it fails to retrieve the device type, it assumes the device is a disk.
- **Globals:** None
- **Arguments:** 
    - $1: The device name to query (e.g., `/dev/sda`).
- **Outputs:** Returns the device type (`disk`, `cd`, etc.) to stdout.
- **Returns:** If successful in retrieving the device type, the function returns 0. If it fails to retrieve the device type but defaults to assuming it's a disk, the function still returns 0.
- **Example usage:**
  ```bash
  device_type=$(get_device_type /dev/sda)
  echo $device_type
  ```

##### Quality and Security Recommendations
1. Validate the device name provided as an argument to ensure it is a properly formatted device name.
2. Provide an option for the caller to specify the default type (instead of "disk" being the default).
3. Implement thorough error handling and logging for common failure scenarios, such as when the `udevadm` command is not found.
4. Consider adding conditional checks to ensure that "udevadm" is installed and accessible on the host system before proceeding with the function execution.
5. Sanitize output from the `udevadm` command to make sure potential harmful strings will not cause unintended shell command execution.

