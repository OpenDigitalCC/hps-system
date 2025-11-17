### `check_and_download_latest_rocky`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: ac86f8c78c7149b4fbc3125a2f52dd65b160ad01f437b5eeb5b504bd1a90c6b1

### Function overview

This shell function `check_and_download_latest_rocky`, written in bash script, is designed to check for the latest version of Rocky Linux for a specific architecture and download the ISO file if it is missing. It sets up the target base directory and checks whether the latest version ISO file is present. If it is not present, it downloads the ISO from the base url which is initially defined.

### Technical description

- **Name**: `check_and_download_latest_rocky`
- **Description**: This bash function checks and downloads the latest version of Rocky Linux for a specific architecture if it is missing.
- **Globals**: `HPS_DISTROS_DIR`: Directory for storing ISOs.
- **Arguments**: None.
- **Outputs**: Logs and messages about the process and final results.
- **Returns**: None in this function but could return 1 if erred in practical usage.
- **Example Usage**: `check_and_download_latest_rocky`. As it doesn't require any arguments, the function can be called without providing any.

### Quality and security recommendations

1. **Validating inputs**: Input variables, especially those sourced from outside the function such as `HPS_DISTROS_DIR`, should be checked and validated to ensure they are correct and safe.
2. **Error trapping**: Consider adding more error trapping to handle situations where commands within the function fail. 
3. **Use More Robust Code**: String operations on paths can be replaced with more robust code using `dirname` and `basename`.
4. **Use `https://`:** Always use secure protocol (https) while downloading files for ensured security.
5. **Checksum Verification:** For further security, the downloaded ISO could be verified against a known checksum to ensure its integrity. Any mismatches should trigger a warning or error.
6. **Permission and Access:** Ensure proper permission schemes for the directories and files mentioned in the function.

