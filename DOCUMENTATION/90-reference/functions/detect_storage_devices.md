#### `detect_storage_devices`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 26407abf67962b945819ec70c2d91c7a26b60c144eeb209e22298b013ba307ed

##### Function Overview
The function `detect_storage_devices()` is used to retrieve and display data related to all block devices available on a system, such as name, model, vendor, serial number, bus type, device type, size, usage, and speed. It makes use of other utility functions to get this data and puts it into a designated output string, each set of data separated by `---`.

##### Technical Description
- **Name**: detect_storage_devices
- **Description**: This function retrieves details of all block storage devices on a system including device name, model, vendor, serial number, bus type, device type, size, usage and speed.
- **Globals**: None
- **Arguments**: None
- **Outputs**: Displays details of every block device on output.
- **Returns**: Doesn't return any value.
- **Example usage**: `detect_storage_devices`

##### Quality and Security Recommendations
1. Implement input validation to ensure that only valid block storage devices are being processed.
2. Handle exceptions when calling other utility functions (like `get_device_model`, etc.) to ensure the function doesn't break due to unexpected errors.
3. Secure the information being displayed by the function, as it might contain sensitive data like device serial number.
4. Consider optimizing the function if the number of storage devices is high to avoid performance issues.

