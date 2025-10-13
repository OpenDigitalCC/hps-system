### `get_device_speed`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: a3925bc33db6a5252197ab449a78edcdfb4d9117f6e067cedb4b22c2eaea3a3e

### Function overview

The function `get_device_speed` measures the read speed of a particular device.

### Technical description

- **name:** `get_device_speed`
- **description:** This bash function measures and outputs the read speed of a given device. It reads data from the specified device using the `dd` command and pipes the output to the `grep` command to filter the speed data. In case the speed data can't be retrieved, it prints "N/A".
- **globals:** None
- **arguments:**
    - `$1`: This refers to the device for which the read speed is being measured.
- **outputs:** It outputs the read speed of the provided device in the format '[0-9.]\+ MB/s', else if it can't fetch the data, it prints "N/A".
- **returns:** It won't return any standard exit codes, but the output of the speed of the device.
- **example usage:** 
```bash
get_device_speed "/dev/sda1"
```

### Quality and security recommendations

1. Add proper error handling: We should have a way to handle situations where the device does not exist, is not readable or the `dd` command is not available.
2. Return error codes: This function doesn't have a return value, it just emits the output. To improve its usability in scripts, it would be better to return distinct codes for different error conditions.
3. Check for needed utilities: It would be great if function checks for presence of `dd` and `grep` commands at the start of execution.
4. Input sanitation: Inputs should be sanitized or validated to prevent potential security risks. Validate the device name accordingly.
5. Improve the output: To increase the usability of the function, it could return both the raw speed data and a human-readable string.

