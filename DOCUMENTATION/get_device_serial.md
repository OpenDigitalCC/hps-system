## `get_device_serial`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview

The `get_device_serial()` function is a Bash method useful for querying hardware properties in Linux systems. It uses the `udevadm` command to fetch device properties, specifically the `ID_SERIAL` property, which is the unique identifier for a device. This function receives a device name as input and returns the corresponding serial number. If it cannot find the serial number, it outputs "unknown".

### Technical description

**Name**:  
`get_device_serial`

**Description**:  
This Bash function is designed to extract a hardware device's unique identifier (serial number) in Linux systems. It's important in scenarios where it's necessary to programmatically identify specific hardware for any task. The `udevadm` command is used alongside `grep`, `cut`, and `echo` utilities for finer manipulation of the retrieved device properties.

**Globals**:  
None.

**Arguments**:  
- `$1`: Device name. The hardware device to query the serial number for.

**Outputs**:  
The function outputs the hardware device's serial number. If the serial number cannot be located, it outputs "unknown".

**Returns**:  
No value is returned.

**Example usage**:  
```bash
get_device_serial /dev/sda
```

### Quality and security recommendations

1. Input sanitization: Add checks to validate that the input is a valid device path before proceeding.
2. Error handling: Rather than simply outputting "unknown", consider adding more robust error handling to provide diagnostic information in case of execution errors.
3. Silent failure: Provide a fallback or a warning if `udevadm` is not present/installed in the system.
4. Command injection: Even though this function is probably safe from command injection vulnerabilities (assuming untrusted input can never be a device path), it's good practice to ensure script variables are only used in safe contexts.

