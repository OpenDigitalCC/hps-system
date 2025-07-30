## `get_device_bus_type`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview
The `get_device_bus_type` function is a bash command that is used to determine the bus type of a given device. The function takes in a device as an argument and checks its file path to see if it matches the criteria for different bus types (NVMe, SSD, or HDD). If the device is an NVMe device, the function will directly output "NVMe". For devices that do not match the NVMe naming convention, the function will call a different function `get_device_rotational` with the device as an argument. If that function returns "0", indicating that the device is a non-rotational device, the bus type of the device is assumed to be "SSD". If the device is a rotational device, it is assumed to be "HDD". 

### Technical description
- **name**: `get_device_bus_type`
- **description**: A function to determine the bus type of a device. The possible bus types it can return are "NVMe", "SSD", or "HDD".
- **globals**: None
- **arguments**: [ `$1`: A string that represents the device path ]
- **outputs**: The bus type of the device.
- **returns**: 0 if successfully executed, non-zero on error.
- **example usage**: 
```bash
bus_type=$(get_device_bus_type "/dev/nvme0n1")
echo $bus_type # Outputs: NVMe
```

### Quality and security recommendations
- There should be more rigorous error checking in place. For example, the function should check if the argument passed is a valid device path. 
- The function doesn't handle errors from the `get_device_rotational` function. It should include error handling mechanism for this function.
- The function could return an error when a device type is not recognized or the input is not expected, rather than making an assumption it is a HDD.
- Instead of directly echoing the string of device type, consider using return codes for different types of devices, which could make the function more usable programmatically.
- Make sure that the function has read access to the file path specified before attempting to execute operations on it.
- Avoid potential command injections by validating the input to the function.
- It should handle the case sensitivity of device names. For example, NVMe could be in lower-case as well.

