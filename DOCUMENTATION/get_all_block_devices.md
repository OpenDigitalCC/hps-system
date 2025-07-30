## `get_all_block_devices`

Contained in `lib/functions.d/storage_functions.sh`

### Function overview

The `get_all_block_devices` function is a Bash function that fetches all block devices from the `sys/block` directory in a Unix-based system. For each device, it obtains the device name, checks whether the device type is 'disk', and if so, it prints this device name. The function excludes non-disk types such as loop, md, dm, and others.

### Technical description

- **Name:** get_all_block_devices
- **Description:** This function iterates through all the files in the `/sys/block/` directory. For each file, it verifies if the device type is 'disk'. If it is, it prints the device name.
- **Globals:** 
   - `devname` : It stores the name of the device file.
- **Arguments:** 
   - No Arguments are needed for this function.
- **Outputs:** 
   - It outputs the names of block devices where the device type is 'disk'.
- **Returns:**
   - The function does not explicitly return a value, but it results in having the disk type block devices' names printed.
- **Example usage:**
    - `get_all_block_devices`
    
On executing this function, it will print all the block device names where the device type is 'disk'.

### Quality and security recommendations

1. **Defensive Programming**: Check if `/sys/block/` directory exists before proceeding. It will avoid possible errors.
2. **Error Handling**: Handle possibilities where `get_device_type` function call may fail.
3. **Security**: Avoid printing the device names directly. Depending on the context, disclosing those can be a security risk.
4. **Improving Readability**: Comment each section of code so that the function becomes self-explanatory.
5. **Follow a coding style guide**: Consistency could make the code easier to understand or maintain.

