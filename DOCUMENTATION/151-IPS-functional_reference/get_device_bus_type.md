### `get_device_bus_type`

Contained in `lib/functions.d/storage_functions.sh`

Function signature: 71e77c52eb2ba1d481c9ef51c928878b08e2c1088eeb0bf2fbe433c62633a476

### Function overview

The function `get_device_bus_type()` takes one argument, which represents a device, and returns the device bus type based on the device name or device property defined in the local environment. If the device name starts with `/dev/nvme`, it will echo "NVMe". If not, it then checks if the device is rotational, if it's not rotational, it echoes "SSD", otherwise, it echoes "HDD".

### Technical description

- **Name:** `get_device_bus_type`
- **Description:** This function identifies the type of bus a provided device is using. It checks whether the input is a Non-Volatile Memory Express (NVMe) device, a Solid State Drive (SSD), or Hard Disk Drive (HDD) by analyzing its name or its rotational property.
- **Globals:** None
- **Arguments:** 
    - `$1: dev` A string that represents the device. 
- **Outputs:** 
    - If the device name starts with `/dev/nvme`, it outputs "NVMe". 
    - Otherwise, if the device is not rotational, it outputs "SSD".  
    - Otherwise, it outputs "HDD".   
- **Returns:** None
- **Example usage:** `get_device_bus_type /dev/nvme0n1`

### Quality and security recommendations
1. Always validate the input to ensure that the device provided exists in the system. 
2. Consult the device properties from a trusted source, or directly from the system if possible, instead of purely relying on the device name pattern.
3. Maintain the single-responsibility principle. The function may benefit from being split into multiple smaller functions, each with its own responsibilities: one for checking if the device is NVMe, another for checking if the device is an SSD, and another for checking if the device is an HDD.
4. Always handle potential errors or exceptional cases to avoid unexpected behaviors. In this function, an else-case would be beneficial to handle situations where the device is neither an NVMe device, SSD, nor HDD.

