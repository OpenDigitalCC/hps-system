#### `get_device_rotational`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 1002aec4163a82a48171eea735ad8700633333695a4b75dcb9ecc3317d14222f

##### Function overview
`get_device_rotational` is a Bash function that gets the rotational characteristic of a block device on a Linux-based system. A parameter, which is the name of a block device, is passed to the function. If the device is rotational, the function will return '1', and if it's not or if there is an error retrieving the information, it will also return '1'. This function is typically used to check if a hard drive is Solid-State Drive (SSD) or Hard Disk Drive (HDD).

##### Technical description

- **name**: `get_device_rotational`
- **description**: This function checks if a block device is rotational or not in a Linux system. It returns '1' in case of an error.
- **globals**: None
- **arguments**: 
    - `$1`: `dev` - a string representing the block device to check
- **outputs**: The function outputs either '0' (for non-rotational devices) or '1' (for rotational devices and in case of an error).
- **returns**: The function doesn't have a specific return statement, so the last command's status is returned, i.e., the status of 'echo'.
- **example usage**: 

```bash
if [[ "$(get_device_rotational sda)" -eq "0" ]]; then
    echo "Device is an SSD"
fi
```

##### Quality and security recommendations

1. To increase the robustness of the function, error handling should be expanded. Instead of defaulting to '1' for errors, a different unique value or message should be returned.
2. It’s a good practice to validate the input to the function. Ensure the script properly handles cases where the device doesn't exist or the device name provided is invalid.
3. There is potential for a race condition if the device's type changes after the function checks it and before its return is used. Depending on how critical this is, consider ways to avoid this type of situation.
4. Security-wise, make sure the script is being run with appropriate permissions to read the device information.
5. Comment the function adequately to ensure that its use and return cases are clear to other developers.

