### `check_and_download_latest_rocky`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 95853858409b34c65eb8d886732c7cec3b9e2f99fb6a3b3d95b1bc9d2780fed7

### Function Overview

The function `check_and_download_latest_rocky` checks for the latest version of Rocky Linux ISO in the specified architecture (x86_64) and downloads it if it does not already exist. The function also ensures the correct directory structure exists for storing the downloaded ISO. It includes checks for the latest version and whether the ISO already exists in the local directory. If it does not, it then proceeds to download the ISO using curl and displays appropriate messages. Subsequently, the function extracts the downloaded ISO for use with PXE booting.

### Technical Description

- **Name:** `check_and_download_latest_rocky`
- **Description:** This function checks for the latest version of Rocky Linux ISO, downloads it if it doesn't already exist, and extracts it for use with PXE.
- **Globals**: 
   - `base_url`: base URL for fetching Rocky Linux ISOs
   - `arch`: The architecture of the ISO (default: x86_64)
   - `iso_pattern`: Describes the type of ISO to download (default: minimal)
- **Arguments**: None
- **Outputs**: Log and echo messages regarding the program's progress and operations. These messages include the latest version number, downloading status, ISO availability, and further steps that are carried out by the function.
- **Returns**: None. The function can exit early with a status of 1 if it cannot detect the version.
- **Example Usage**:
   ```bash
   check_and_download_latest_rocky
   ```

### Quality and Security Recommendations

1. Avoid the user of `local` keyword in the global scope, as its behavior might differ across bash versions.
2. Validate and sanitize inputs to prevent command injection attacks.
3. Include error handling for network operations.
4. Consider using a more secure method of downloading the file, potentially through an encrypted connection.
5. Check that requisite permissions exist for creating directories and downloading files.
6. Implement logging for greater visibility for debugging and auditing.
7. Performance improvements could be considered by avoiding unneeded downloads if the ISO already exists. Check for file integrity after download to prevent using a corrupted file.

