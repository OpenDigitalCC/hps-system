## `get_device_usage`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview

The `get_device_usage` function is a Bash shell function that retrieves the usage status of a specific device. This function works by extracting information from the `lsblk` command output to grasp the usage scenario of the specified device. This entire process is facilitated through a series of commands and piping outputs to manipulate the data into a suitable format before outputting it.

### Technical description

**Name:**  
`get_device_usage`

**Description:**  
The function fetches and outputs the mount point statuses of a specified linked device. If there is no output or the device is not used, it outputs "unused".

**Globals:**  
None

**Arguments:**  
- `$1: dev` - The specified device to check its mount point status.

**Outputs:**  
If the device is used, it returns a comma-separated string representing the mount points where the device is being used. If the device is not used, it returns the string "unused".

**Returns:**  
The function does not have a specific return value as it echoes its result directly.

**Example usage:**
```bash
get_device_usage /dev/sda1
```
This example will output used mount points of the `/dev/sda1` device.

### Quality and security recommendations

1. Error Handling: Include error checking and handling mechanisms to deal with unexpected input or failures from the `lsblk` command. 

2. Input Validation: Validate the device argument to ensure it's a valid device before attempting to run `lsblk`.

3. Code Simplification: Seek ways to simplify the function for readability. This might mean breaking down the line containing `lsblk`, `grep`, `tr` and `sed` into more manageable sections.

4. Secure Handling of Variables: Use `$dev` inside double quotes in the `lsblk` command to prevent word splitting and filename expansion which might lead to potential command injection or unexpected behavior.

5. Quiet errors suppression: Consider adding `-e` and `-u` options to prevent the script from running with uninitialized variables and to make the script exit when a command fails. This will make debugging easier when something goes wrong.

