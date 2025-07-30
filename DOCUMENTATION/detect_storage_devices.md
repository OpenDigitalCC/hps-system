## `detect_storage_devices`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview

The function `detect_storage_devices` is used to detect all the storage devices in the system, gathering essential information about each device such as its model, vendor, serial, type, bus, size, usage, and speed. The list of devices and their data are formatted into a string, which is printed out by the function. This function relies on several helper functions to fetch specific information about each device.

### Technical description

- **name:** `detect_storage_devices`
- **description:** Fetches a list of all storage devices present on the system using the helper function `get_all_block_devices`. For each device, the function gets details including model, vendor, serial number, type, bus, size, usage and speed using respective helper functions like `get_device_model`, `get_device_vendor`, etc. It formats these details into a string, which is then outputted.
- **globals:** None
- **arguments:** None
- **outputs:** Prints a string with details of all the storage devices. Each device's detail includes the device name (device), model, vendor, serial number, type, bus, size, usage, and speed.
- **returns:** None
- **example usage:** `detect_storage_devices`

### Quality and security recommendations

- Check and handle possible errors in calls to helper functions for fetching device info. This would improve robustness.
- Escape possible special characters in device names and other strings to prevent unwanted interactions with the scripting language.
- Store all sensitive information, such as serial numbers, safely. This information should not be displayed in a context where unauthorized users could gain access to it. 
- Consider using more specific variable names instead of general ones like `output` and `devs` to improve readability and maintainability of the code.
- Before calling helper functions to get device details, check if a device exists; this helps to prevent potential depending/command errors.
- Include logging at every step, especially where there are chances of failures, to track and rectify issues.

