### `n_installer_detect_target_disks`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: 6968bad72645a951cd649277eb09aee62c1718628ae0c39ceefd1a11567253dc

### Function overview

The function `n_installer_detect_target_disks()` is designed to scan and select disks suitable for an installation of an Operating System. During its execution, this function checks if a RAID configuration is requested. If that condition is fulfilled, it searches for two suitable disks. Otherwise, it carries on in single-disk mode. To qualify as suitable, a disk must be non-removable, of the right device type, a whole disk (not a partition), and has its size greater than or equal to a specified minimum. If the function finds suitable disks, it checks whether they are clean, i.e., do not have existing data that might interfere with the new installation. This function also handles error conditions, such as when no suitable disks are found or the disks are not clean.

### Technical description

- **name**: `n_installer_detect_target_disks`
- **description**: Searches for and selects disks that are suitable for OS installation. Supports RAID configuration and single-disk mode.
- **globals**: 
  - `ROOT_RAID`: determines whether a RAID configuration is requested (`1`) or not (`""`, `!=1`)
- **arguments**: None
- **outputs**: Logs messages about the progress and errors encountered during the execution.
- **returns**: 
  - `0`- if at least one disk is found and all found disks are clean
  - `1` - if no suitable disks are found or failed to store the OS disk to IPS
  - `2` - if less than 2 disks are found while `ROOT_RAID` is set to `1`
  - `3` - if installation cannot proceed due to unclean disks
- **example usage**: `n_installer_detect_target_disks`

### Quality and security recommendations

1. Implement stricter error checks and return different codes for distinct types of errors. This would help with debugging and allow better reaction to specific errors.
2. Provide a more secure way to clean disks. Overwriting existing data with zeros could make it harder for malicious actors to recover the old data.
3. Make sure that user-specified parameters (like `ROOT_RAID` value) are sanitized properly. Incorrect values should either produce an intelligible warning or be defaulted to safe values to prevent unexpected behavior.
4. Include input validations for making the function robust, especially when verifying the disk type.
5. Always ensure that the system being worked on has proper permissions to avoid any security breaches.

