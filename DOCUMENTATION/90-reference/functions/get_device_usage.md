### `get_device_usage`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 859cf1265955125053e13b61c6c4bfa14f3715f652ae3ee914eb7e3927870233

### Function overview

The function `get_device_usage()` is used to fetch the usage details about a device. The function accepts a device identifier as an argument and returns a comma-separated string of mount points where the device is in use. If the device is not used anywhere, it returns "unused".

### Technical description

- **Name**: get_device_usage
- **Description**: This function utilizes Linux command line utilities to decipher the usage of a given device. The device identifier is passed as an argument and usage details are then obtained with the 'lsblk' command. The list of places where the device is in use is compiled into a comma-separated string. If the device is not currently in use anywhere, "unused" is returned.
- **Globals**: None
- **Arguments**: 
   - $1: Device identifier (e.g., /dev/sda1)
- **Outputs**: Comma-separated string of device usage locations or "unused" if the device has no usage records.
- **Returns**: 0 on success.
- **Example Usage**:

```bash
usage=$(get_device_usage "/dev/sda1")
echo $usage
```

### Quality and security recommendations

1. Input validation: This function currently performs no validation on input. It would be beneficial to add checks to ensure that the argument passed is actually a valid device identifier.
2. Error handling: Updates could be done to the function to make it handle, recover from, or report any errors that may occur during the execution of command line utilities used.
3. Use of unassigned variables: In the current format, if `lsblk` fails to execute, `usage` will be unset causing an 'unbound variable' error to be thrown. Consider setting a default value for `usage` to prevent this.
4. Secure handling of command substitution: Use the "$()" construct for command substitution to avoid potential security issues with backticks. The current implementation already follows this recommendation.

