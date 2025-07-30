## `get_device_type`

Contained in `lib/functions.d/storage_functions.sh`

### Function Overview

This function, named `get_device_type`, is responsible for identifying the type of a given device in a Unix-based system. It uses the udevadm utility to query the property of the specified device and parses the output to extract the device type. If the device type cannot be located (due to either the device not being recognized or an error occurring), the function will default to identifying the device as a "disk".


### Technical Description
- **Name**: get_device_type
- **Description**: This function is used to determine the type of a specified device within a Unix-based environment. It will return "disk" as a default output if the device type cannot be determined.
- **Globals**: None
- **Arguments**: 
  - $1: `dev` – The device for which the type is to be determined.
- **Outputs**: Writes the device type to stdout. If the device type cannot be specifically determined, it outputs "disk".
- **Returns**: The function itself does not explicitly return a value.
- **Example Usage**: 

  ```bash
  # Get the device type for /dev/sda
  device_type=$(get_device_type /dev/sda)
  echo $device_type
  ```

### Quality and Security Recommendations

- Add error handling that will inform the user if the entered device is invalid or cannot be located.
- Update the function documentation to detail any assumptions or limitations that the function has. In particular, clarify what types of devices are recognized, and what types of devices will default to "disk".
- Since the function pipes the output of a command to grep, make sure that the context in which function is running trusts that environment. In untrusted environments, the function could be tricked into running unexpected commands.
- Consider changing the function to exit with an error code, instead of defaulting to "disk", if the device type cannot be determined.
- Favour the use of grep -q or grep --quiet when possible to reduce unnecessary data written to stdout.
- Make certain that the utility udevadm and utilities used in this function (like grep and cut) are up-to-date to avoid any potential security issues.

