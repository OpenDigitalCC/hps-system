## `get_device_size`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview
The function `get_device_size` is used in Bash to retrieve the size of specified device. It takes as input the device name, then uses the `lsblk` command to determine and return the size of the device. If the size cannot be obtained, it will return "unknown".

### Technical description

- **Name:** `get_device_size`
- **Description:** The function queries the size of the device specified by the user. If the size is not assessed, presumed as unknown.
- **Globals:** None
- **Arguments:** 
  * `$1:` The name identifier of the device (`dev`) whose size is to be determined.
- **Outputs:** The size of the specified device or the string "unknown" if the size could not be determined.
- **Returns:** Returns 0 on successful execution of the command, and values > 0 on error conditions.
- **Example usage:**
  ```
  get_device_size /dev/sda
  ```
  This command will output the size of the device `/dev/sda`.

### Quality and security recommendations

- Ensure permission checks are in place before executing the function as it interfaces with the system hardware which if accessed without correct permissions can lead to unauthorized information disclosure.
- Validate the input to confirm that the device indeed exists before trying to get its size. This will prevent unnecessary error statements and possible exposure of sensitive information.
- Use error handling to deal with any possible issues that might occur when executing `lsblk`.
- Employ a more precise error message instead of "unknown", as it may benefit the debugging process and the user's understanding of the outcome.

