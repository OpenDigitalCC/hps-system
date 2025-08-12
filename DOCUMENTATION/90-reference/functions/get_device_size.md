#### `get_device_size`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 1d4e207d13b80b5424975cd10a3ed7197f78e6832fbbf6662e417abdd6def6d2

##### Function overview

The `get_device_size` function in Bash is designed to determine and return the size of a device (or partition) in a Linux based system. This is achieved utilizing the `lsblk` command, which retrieves information about block devices. Should the command fail to execute, the function returns "unknown". 

##### Technical description

- **Name:** `get_device_size`
- **Description:** This function determines the current size of a block device within a Unix-like system.
- **Globals:** None
- **Arguments:** 
    - `$1`: The identifier or path of the device to be queried for its size.
- **Outputs:** The size of the queried device, or "unknown" if the device does not exist or cannot be accessed.
- **Returns:** 
    - Size of the Device: If the queried device exists and can be accessed.
    - "unknown": If the queried device doesn't exist or can't be accessed.
- **Example usage:** 

```bash
### Get the size of /dev/sda device
device_size=$(get_device_size /dev/sda)
echo "Device size is: $device_size"
```

##### Quality and security recommendations

1. Error Handling: To enhance reliability, incorporate error capturing and handling mechanisms. While "unknown" serves as a failure response, more explicit messaging could improve debugging and user experience.
2. Information Leakage: Avoid exposing detailed system information via error messages which could be utilized by potential attackers.
3. Validate Arguments: Before the function execution, validate if the supplied argument ($1) is a valid device identifier or path.
4. Permission Check: The function should check if it has the necessary permissions to access the device before attempting to query its size.
5. Check Dependency: Ensure `lsblk` command is available in the system environment where the script is intended to run.

