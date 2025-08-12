#### `get_device_usage`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 859cf1265955125053e13b61c6c4bfa14f3715f652ae3ee914eb7e3927870233

##### Function Overview

The bash function `get_device_usage()` is used to determine the usage status of a given device. By employing a series of commands, it retrieves the mountpoints of the device, ignoring any blank entries, before returning the remaining items as a comma-separated string. If no mountpoints exist for the device, the function will return "unused." 

##### Technical Description

 - **Name:** `get_device_usage()`
    
 - **Description:** The function retrieves and returns a comma-separated string of mountpoints for a specific device. If no mountpoints are identified, the function returns "unused."
    
 - **Globals**: (none)
    
 - **Arguments**: 
     - `$1`: `dev` The device for which the usage status is required.
    
 - **Outputs**: Writes to stdout a comma-separated string of the mountpoints for the specified device or "unused" if no mountpoints are found.
    
 - **Returns**: (none)

 - **Example usage**: 
   ```bash
   get_device_usage /dev/sda1
   ```

##### Quality and Security Recommendations

1. Input Validation: Ensure proper validation and sanitization of the inputted device name to prevent code injection or other related security issues.

2. Error Handling: Implement robust error handling to ensure the script doesn't crash when the specified device doesn't exist or other unforeseen errors occur when calling the `lsblk` command.

3. Documentation: Remember to update this documentation if there are changes to the function for maintainability and readability.

4. Testing: Regularly test this function with a variety of different devices and contexts to ensure its versatility and reliability.

