#### `get_all_block_devices`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: add7deb6a087d72238984be839fb5488e13aff3ae7251f93f2c1814d79162625

##### Function Overview
The bash function `get_all_block_devices` provides a way to get all block devices in a Linux system. The function reads the `/sys/block` directory, where all block devices are represented. The function filters these objects to only include those with the type of "disk". Each block device appears as a directory in `/sys/block/{device}`, where `{device}` is the name of the block device. The function prints out the names of all devices of the type "disk".

##### Technical Description
- **name**: `get_all_block_devices`
- **description**: This function scans the `/sys/block` directory for all block devices, filtering out entries that are not of type "disk". It then prints out their names to STDOUT.
- **globals**: None
- **arguments**: No arguments needed
- **outputs**: This function will reveal the names all block devices of type "disk".
- **returns**:
    - Name of all block devices of type disk.
- **example usage**: 
```bash
get_all_block_devices
```
The above example will output a list of all block devices of type 'disk' in your system.

##### Quality and Security Recommendations
1. Error handling for the `basename` command should be added to ensure the script doesn't crash if it fails.
2. Additional checks can be made to confirm that "/sys/block" exists and is accessible before running the function.
3. Ensure that the function is running with the necessary permissions to access the "/sys/block" directory. If not, the function could fail or return incorrect results.
4. Implement sufficient input validation or sanitation to thwart potential security risks such as command injection.

