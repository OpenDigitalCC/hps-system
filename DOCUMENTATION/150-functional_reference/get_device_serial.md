### `get_device_serial`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 8e1b210627973a0cc629e646a16460819b61ae08954c5dba162358f2b6cb4532

### Function overview

The function `get_device_serial` is used for extracting the serial number from a specific device in a Linux system. This is accomplished by querying the Udev device manager using the `udevadm info` command with the particular device and parsing the output to get the serial number.

### Technical description

- **name**: `get_device_serial`
- **description**: This function takes in a device (a local variable `dev`) as an argument, runs a query for its properties using `udevadm`, and extracts its ID_SERIAL value (the device's serial number). If no serial is found, it returns "unknown".
- **globals**: No global variables are used in this function.
- **arguments**: 
  - `$1: dev`, the name of the device to get the serial number from.
- **outputs**: Either the device's serial number or the string "unknown" if no serial number is found.
- **returns**: The function doesn't have a `return` statement, its output is a side-effect of the function.
- **example usage**: `get_device_serial /dev/sda`
  
### Quality and security recommendations

1. Add error checking and handling for non-existent devices or permission issues when running the `udevadm` command.
2. Currently, the function silently defaults to "unknown" when the device serial cannot be retrieved. This could be enhanced by incorporating a verbose mode or a warning message to inform the user about possible issues.
3. To avoid potential command injection, ensure that the provided input is properly validated and sanitized before it is used.
4. Prefer using the `printf` function over `echo` for compatibility and predictability reasons.
5. Always use double quotes around variable substitutions to avoid word splitting and pathname expansion. For instance, `--name="$dev"` instead of `--name=$dev`. This is already correctly done in the provided function.

