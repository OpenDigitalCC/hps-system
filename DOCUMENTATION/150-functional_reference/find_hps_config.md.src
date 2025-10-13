### `find_hps_config`

Contained in `lib/functions.sh`

Function signature: 2b1359b9639780889fba67b113809b966b3326fe6600551c16100c71c64f76ef

### Function Overview

This function, `find_hps_config()`, is a simple Bash script function that iterates over an array `HPS_CONFIG_LOCATIONS`. It checks for existing files in the specified locations. Once it comes across the first existing file, it assigns the location to a local variable `found` and breaks the loop. The function then outputs the value of `found` and returns a success status code `0`. If no files are found in any of the locations in the array, the function returns a failure status code `1`.

### Technical Description

- **Name:** `{find_hps_config()}`
- **Description:** This function iterates over an array `HPS_CONFIG_LOCATIONS`, checking each location for existing files. The first existing file found is assigned to the local variable `found`, which is then echoed out. The function returns `0` when a file is found and `1` when not.
- **Globals:** `[HPS_CONFIG_LOCATIONS: An array of file paths where the function will look for existing files]`
- **Arguments:** `[None]`
- **Outputs:** The filepath of the first existing file found in the array `HPS_CONFIG_LOCATIONS`. If no file is found, it does not produce any output.
- **Returns:** `0` if an existing file location is found, `1` if not.
- **Example Usage:**
    ```bash
    HPS_CONFIG_LOCATIONS=("/path/to/file1" "/path/to/file2" "/path/to/file3")
    find_hps_config
    ```

### Quality and Security Recommendations

1. Ensure the array `HPS_CONFIG_LOCATIONS` only contains paths to trusted, secure locations to prevent any unintended access to malicious files.
2. Check whether files found at any of the locations are not just existing but also readable before assigning to the variable `found`.
3. Document this function on usage and expected inputs and outputs, especially since it does not have any named input arguments. This will help avoid any potential misuse of the function.
4. Implement error handling to capture scenarios where the `HPS_CONFIG_LOCATIONS` is either not an array or is an empty array. This will improve the function reliability.
5. Validate and sanitize the file paths to ensure they are not misused to access unintended parts of the file system, adding an extra layer of security.

