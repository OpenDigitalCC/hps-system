## `has_sch_host`

Contained in `lib/functions.d/host-functions.sh`

### Function Overview

The function `has_sch_host()` checks if there are any configuration files (`*.conf`) in the configuration directory (`HPS_HOST_CONFIG_DIR`) that are of type 'SCH'. If such a configuration file exists, the function succeeds, otherwise, it fails. If the configuration directory does not exist, an error message is output and the function returns failure.

### Technical Description

- Name: `has_sch_host`
- Description: This function scans through the configuration directory for `.conf` files and checks if there is at least one file of type `'SCH'`. If such a file exists, the function returns success, otherwise it returns failure. If the configuration directory does not exist, an error message is output and the function returns failure.
- Globals: 
  - `HPS_HOST_CONFIG_DIR`: This global variable is used to define the path of the host configuration directory that is to be searched.
- Arguments: None
- Outputs: Error message if the host config directory specified by `HPS_HOST_CONFIG_DIR` is not found.
- Returns: 
  - `0` if at least one SCH type config file is found.
  - `1` if no SCH type config file is found or if the config directory is not found.
- Example Usage:
  ```bash
  HPS_HOST_CONFIG_DIR="/path/to/config/dir"
  if has_sch_host; then
    echo "SCH host found."
  else
    echo "No SCH host found."
  fi
  ```

### Quality and Security Recommendations

1. Always enclose path variables in quotes to avoid issues with spaces or special characters in file paths.
2. It would be a good practice to confirm that the configuration files being searched are readable before running the `grep` command.
3. The script assumes that the script user has read permissions to all directories and files involved. A check should be implemented to ensure that the current user has the necessary permissions before executing the function.
4. Consider using more meaningful exit codes or provide them as constants at the beginning of the script for easier debugging.
5. Proper error handling can be done for the situation where the `HPS_HOST_CONFIG_DIR` variable is empty or not set.

