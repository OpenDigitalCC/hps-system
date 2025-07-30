## `get_device_vendor`

Contained in `lib/functions.d/storage_functions.sh`

### 1. Function Overview

`get_device_vendor` is a bash function designed for identifying the device vendor. The function takes a device path as an argument and reads from the `/sys/block/<basename of the device path>/device/vendor` file to fetch vendor information. If it is unable to fetch the vendor information, it returns a string "unknown".

### 2. Technical Description

- **Name**: `get_device_vendor`
- **Description**: This function takes a device path as an argument in order to outsource the vendor of the provided device. In case the provided device doesn't have a vendor, the function will return a string `"unknown"`.
- **Globals**: None
- **Arguments**:
  - `$1: Device path from which the function will extract the basename and use in the fetch vendor process.`
- **Outputs**: The vendor of a given device or "unknown" if it's not found.
- **Returns**: The device vendor name or "unknown".
- **Example Usage**:
  ```bash
  get_device_vendor /dev/sda
  ```
Will return the vendor of the device located at /dev/sda.

### 3. Quality and Security Recommendations

- **File Existence**: Before attempting to read the device/vendor file, check whether it exists to avoid unnecessary error handling.
- **Argument Validation**: The function doesn't validate the input argument before use. Implement input validation to ensure the provided path is a valid device path.
- **Error Messages**: Instead of routing all error messages to /dev/null, consider logging the actual error message for debugging purposes.
- **Return Status Codes**: For better error handling, the function should return distinct status codes for different error/results.
- **Input Sanitization**: Unfiltered user input can lead to potential security vulnerabilities. Always sanitize user inputs before using them in a function.

