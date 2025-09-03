### `has_sch_host`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 379b6704d9af414555293ef691b70449d39306ef567e44aabf9ef70f91fa692d

### Function Overview

The `has_sch_host` function is designed to check if there is any configuration file in the specified directory (`$HPS_HOST_CONFIG_DIR`) that contains a certain type 'SCH'. It first checks if the specified directory exists. If not, it outputs an error message and returns 1 to indicate an error. If the directory exists, it checks every `.conf` file in it for the presence of 'TYPE=SCH'. If at least one file with 'TYPE=SCH' is found, it returns 0 (True). If no such file is found, it returns 1 (False).

### Technical Description

- **name**: `has_sch_host`
- **description**: This function checks if there is any configuration file in the specific directory that contains "TYPE=SCH".
- **globals**: 
    - `HPS_HOST_CONFIG_DIR`: Directory to search for configuration files.
- **arguments**: None
- **outputs**: An error message if the specified directory does not exist.
- **returns**: 1 if the specified directory doesn't exist or no file containing "TYPE=SCH" is found. 0 if at least one file containing "TYPE=SCH" is found.
- **example usage**: `if has_sch_host; then echo "SCH host config found"; else echo "SCH host config not found"; fi`

### Quality and Security recommendations
1. It would be safer to use an absolute path for `$HPS_HOST_CONFIG_DIR` to avoid ambiguity and confusion.
2. It is recommended to standardize the configuration files' extensions, such as `.conf`, for better searchability.
3. Consider improving the error-handling mechanism to make it more robust, for example by detailing which scenarios result in which errors.
4. Further sanitize the search pattern '(^TYPE=SCH)' to prevent potential command injections.
5. Utilize built-in shell checks to validate that "${HPS_HOST_CONFIG_DIR}" is, in fact, a directory, not a file.

