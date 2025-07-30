## `get_device_rotational`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview

The `get_device_rotational()` function is a bash function for determining the rotation status of a device. This function works specifically on Linux systems, fetching the rotation information directly from the system files. The result can indicate whether the specific device is rotational or not. This could be useful for operations that require specific measures or optimizations for rotational or non-rotational storage devices.


### Technical description

- Name: `get_device_rotational`
- Description: This function determines whether a given block device is rotational (like hard disk drives) or non-rotational (like solid-state drives). It accesses a particular system file using the device name, attempting to read out a value ('0' or '1') that indicates the device's rotation status.
    
- Globals: None
    
- Arguments: 
    - `$1: dev` - a string specifying the name of the device for which to fetch the rotational status.

- Outputs: 
    - '0' indicates the device is non-rotational.
    - '1' indicates the device is rotational.
   

- Returns: The rotation status of the input device.

- Example Usage:
    ```
    get_device_rotational sda
    # Output: 1
    ```

### Quality and Security Recommendations

1. Implement error handling for cases where the input argument does not meet expected formats or when the system file does not exist for the specified device.
2. Use clear and descriptive naming conventions for parameters and variables to improve code readability.
3. As the function deals with system-level information, ensure that it is invoked by users with appropriate permissions. Unauthorized usage should be avoided.
4. Include input validation to check that the device exists and try to handle edge cases where the device may not be available.  
5. Comment your code to make it easy for others (or future you) to understand what each part of the function is doing.
6. Sanitize system command (like `basename`) exaggerations and redirection to prevent potential command injection security weaknesses.

