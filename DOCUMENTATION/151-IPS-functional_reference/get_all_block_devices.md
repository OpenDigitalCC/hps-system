### `get_all_block_devices`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: add7deb6a087d72238984be839fb5488e13aff3ae7251f93f2c1814d79162625

### Function overview

The `get_all_block_devices` function is used to retrieve all the block devices in a system where their type is 'disk'. It iterates over all block devices in /sys/block directory and which uses a helper function named `get_device_type` to get the type of the device. We get the basename, or the least significant part of the device's path in this instance, to identify the device. If it is a disk, then the device name is printed to the standard output.

### Technical description

- **Function Name**: get_all_block_devices
- **Description**: This function retrieves all the block devices whose type is 'disk' from a system. 
- **Globals**: devname: contains the name of the device.
- **Arguments**: None.
- **Outputs**: The function outputs to stdout the names of all block devices which are of type 'disk'.
- **Returns**: No explicit return value. Success or failure can be inferred from the lack or presence of output.
- **Example Usage**: `get_all_block_devices`. It needs no arguments.

### Quality and security recommendations

1. Validation of the device path: The function directly accesses the /sys/block/ path. The command `basename` can potentially fail if the path does not exist. Hence, validation of the actual device path before processing can improve robustness.
2. Error handling: There is no explicit error handling in case the `get_device_type` returned value is not 'disk' or some other error occurs. It would be beneficial to add error handling mechanisms to improve the robustness of the code.
3. Defensive programming: There are no checks to ensure that the function operates as expected in an abnormal or unanticipated scenario. Therefore, enhancing the function with more checks would increase its resilience.
4. Documentation: There is no comment in the function explaining what it does and how it works. Good documentation makes it easier to maintain and debug the code in the future.

