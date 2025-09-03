### `find_hps_config`

Contained in `lib/functions.sh`

Function signature: 2b1359b9639780889fba67b113809b966b3326fe6600551c16100c71c64f76ef

### Function Overview

The `find_hps_config` function finds and returns the location of the HPS (High Performance Storage) configuration file from an array of possible locations. If it finds a valid location, the function prints out the location and ends successfully with a zero-status. If the function fails to find a valid location, it ends with a non-zero status.

### Technical Description

- **Name:** `find_hps_config`
- **Description:** The function iterates over the `HPS_CONFIG_LOCATIONS` array and assigns the first non-empty and existent file location to the `found` variable. The function prints out the `found` location, and if it is non-empty, the function is successful and returns 0; otherwise, it ends with a return of 1.
- **Globals:** [`HPS_CONFIG_LOCATIONS`]: An array of possible configuration file locations.
- **Arguments:** _Not applicable in this context_
- **Outputs:** Prints the configuration file’s location if available.
- **Returns:** 0 if the function is successful in finding a configuration. Otherwise, it returns 1.
- **Example usage:**
```
HPS_CONFIG_LOCATIONS=("/etc/hps/config" "/usr/local/etc/hps/config")
find_hps_config
```

### Quality and Security Recommendations

1. The function might silently fail if the `HPS_CONFIG_LOCATIONS` array is not set with valid locations. Guardrails could be put in place to check if the array is set and non-empty before proceeding.
2. The `HPS_CONFIG_LOCATIONS` array should contain carefully considered locations only. Including directories where a malicious user can create files could lead to security vulnerabilities.
3. When a valid file is found, the function stops looking for further files. A more robust function might also check if the located configuration file contains expected data.
4. Surrounding the function argument "$candidate" with double quotes avoids problems with file names that contain spaces or other special characters.
5. Use `set -e` and `set -u` options at the start of the script for a safer script. The `-e` ensures that the script ends if any command, pipeline, or sub-shell exits with a non-zero status. The `-u` option ensures the script exits if an undefined variable is used.

