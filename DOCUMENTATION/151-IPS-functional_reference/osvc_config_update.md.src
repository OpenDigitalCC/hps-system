### `osvc_config_update`

Contained in `lib/functions.d/opensvc-functions.sh`

Function signature: 623bd8e4588409e783c922c0cd2b96d347d9f58a1f1e5c0efabb5d906e5719ef

### Function overview
The `osvc_config_update` function updates the OpenSVC cluster configuration by setting the entered key=value pairs. This function first checks if at least one key=value pair was entered as argument. If not found, it logs an error message and exits with a return status of 1. If all is well, it sets the entered arguments with each key=value as an argument to `om cluster config update`. The successful or unsuccessful update is logged and the function returns with a status of 0 or 1.

### Technical description
Following are the technical details for the function `osvc_config_update`:

- **name**: `osvc_config_update`
- **description**: This function updates the OpenSVC cluster configuration with key=value pairs entered as arguments.
- **globals**: `set_args: An array to store the --set with key=value pair for the cluster configuration update`.
- **arguments**: `$@: Key=value pairs for updating the cluster configuration`.
- **outputs**: Logs the setting of cluster configurations as well as success or failure of update.
- **returns**: `0 if the cluster configuration updated successfully. 1 if it fails or if no arguments provided`.
- **example usage**: `osvc_config_update database=postgres user=admin`

### Quality and security recommendations
1. Function should validate the key=value pairs for known configurations before processing to avoid any issues.
2. Proper error handling should be done when the command to update the cluster configuration fails.
3. There should be a limit on the number of key=value pairs that could be processed at once to prevent any resource issues.
4. Log the output of command to update the configuration for debugging in case of any failures.
5. All data, including log messages and return values, should be properly sanitized to prevent any security threats.

