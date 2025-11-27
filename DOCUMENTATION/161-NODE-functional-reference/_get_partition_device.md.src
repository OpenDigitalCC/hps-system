### `_get_partition_device`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: ad9bf3c98b29acbfb3b9f9599cb8bbe96ebe1077f8e364763a9d6f603ee239f5

### Function overview

The provided Bash script appears to perform disk partitioning operations by determining if the disk is a specific NVMe device and handling RAID related operations if necessary. The `_get_partition_device` function is used for obtaining partition device names. After that, a RAID setup is optionally created using mdadm, depending on the `raid_mode` variable. Successful RAIDs and single disks have their device paths stored in the `boot_device` and `root_device` variables. These paths are then stored to `host_config` using `n_remote_host_variable` function, followed by logging the details into a remote log.

### Technical description

- Name: `_get_partition_device`
- Description: A utility function that helps generate correct device names for partitions, especially accurately handling NVMe device names.
- Globals: 
  - `raid_mode`: Determines RAID setup mode.
  - `disks`: Array holding the disk details.
- Arguments: 
  - `$1`: Represents the disk whose partition is to be identified.
  - `$2`: Represents the partition number on the disk.
- Outputs: Echoes the correct partition device name.
- Returns: Doesn't explicitly return a value. However, `echo` statements implicitly become the return values which can be captured in command substitution (`$()`).
- Example Usage:  
  ```
  local disk1_partition_2=$(_get_partition_device "$disk1" 2)
  ```

### Quality and security recommendations

1. The script globally handles multiple disks, partitions and other variables. Use of more localized scope for variables, when possible, would enhance the code quality.
2. The return codes such as '3' and '1' are hardcoded. It's a better practice to use meaningful constant variables for return codes.
3. Errors are logged with related messages but those parts of the script don't exit or stop. Depending on severity, the script could stop at errors.
4. Check for the existence of the required commands like `mdadm` at the beginning of the script for better practice.
5. For security, the script could incorporate additional checks or user prompts before creating, modifying, or deleting disks or partitions.
6. All input and output operations should be validated and sanitized to prevent potential security risks.

