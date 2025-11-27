### `get_all_hosts_by_keyvalue`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 05e58488251a9243210a5e975395a66c035bc1d2eaf596466d1c914f2e66feda

### Function Overview
The function `get_all_hosts_by_keyvalue()` searches for hosts within the active cluster that matches the given key-value pair. It makes use of auxiliary functions and Bash built-in commands to ensure it finds the correct hosts. The hosts are identified by their filenames, which get outputted when found.

### Technical Description
- **Name**: `get_all_hosts_by_keyvalue`
- **Description**: This function traverses all host configuration files in the active cluster's directory, searching for the given key-value pairs. It transforms the provided key to uppercase and the provided value to lowercase before the search to ensure consistent matching.
- **Globals**: None
- **Arguments**: 
  - `$1`: search_key - The key to search for in the host configuration files.
  - `$2`: search_value - The value to match with the provided key in the host configuration files.
- **Outputs**: If a match is found, the filename of the host configuration file, sans `.conf` extension, is echoed to stdout.
- **Returns**: 1 if either search_key or search_value is empty, or if the active cluster hosts directory does not exist. Returns 0 if at least one match is found, and 1 if no matches were found.
- **Example Usage**: `get_all_hosts_by_keyvalue "HOST_NAME" "examplehost"`

### Quality and Security Recommendations
1. Always ensure the caller is aware that the function is case sensitive and that the case of the input strings is adjusted to fit the data context.
2. To guarantee the security of the cluster, the function should have a way to handle situations when it cannot correctly access or read the host files. It can be set to exit or inform the user to check permissions.
3. To ensure code quality, consider implementing input validation on the `search_key` and `search_value` parameters to ensure they are non-null strings before transforming them. This function currently silently fails if either of the parameters is missing, which could lead to unexpected behaviour.
4. Lastly, handle edge-case scenarios such as incorrectly formatted host files or presence of special characters that might not be considered in the current implementation.

