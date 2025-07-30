## `verify_checksum_signature`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview

The `verify_checksum_signature` function provides verification capabilities for downloaded ISO files. It checks the existence of an ISO file specific to a given CPU, manufacturer, OS name, and OS version from a local directory. If the ISO file exists, it cross verifies the ISO's checksum using a remote CHECKSUM file and its GPG signature. The function currently only supports Rocky Linux and reports if the required verification methods for other operating systems are not implemented. It also handles cleanup of temporary files used during the process.

### Technical description

- **Name**: `verify_checksum_signature`

- **Description**: The function checks that an ISO file exists and verifies the signature and the checksum of the ISO file. If the checksum or signature do not match the expected values, the function returns an error. The function currently is specifically designed to handle the checksum verification process for Rocky Linux.

- **Globals**: `[ HPS_DISTROS_DIR: The directory to find the iso files ]`

- **Arguments**: `[ $1: The architecture of the CPU, $2: The manufacturer of the CPU, $3: The name of the os, $4: The version of the os ]`

- **Outputs**: The function provides console outputs for each stage of the process, and detailed reports when errors are encountered.

- **Returns**: It can return 0 if the operation was successful i.e. the ISO exists and its checksum and signature match. It returns 1 if the ISO file wasn't found or if the hashes or signatures don't match, or if the verification process hasn't been implemented for the specified operating system.

- **Example usage**:
```bash
verify_checksum_signature "x86_64" "Intel" "rockylinux" "8.5"
```

### Quality and security recommendations

1. Implement error handling for failed curl operations to robustly handle external dependencies.
2. Extend the validation for other operating systems beyond Rocky Linux.
3. Consider allowing the specification of external file paths as input, which would increase the function's flexibility in accessing different directories.
4. Use central configuration for external URLs to ease maintenance.
5. Consider adding a manual override option to bypass the verification process when needed.

