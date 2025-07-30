## `host_config`

Contained in `lib/functions.d/host-functions.sh`

### Function Overview
This function, called `host_config()`, is used to handle a configuration file for a specified host. The host is defined by its MAC address. The function can read the configuration file, check if a key exists, compare a key's value to a supplied value, and even set a new value for a key in both the running script and the physical configuration file.

The function is idempotent, meaning the config file is only read once during the execution of the script, regardless of how many times the function is called.

Particular actions to perform are determined by the command sent as the second argument, which can be 'get', 'exists', 'equals', 'set', or any other for an error message.

### Technical Description
- **Name:** `host_config`
- **Description:** used to handle a host configuration defined by its MAC address in various ways.
- **Globals:** 
  - `VAR`: Briefly describe the VAR global variable here
- **Arguments:** 
  - `$1`: MAC address used to locate and identify specific host config.
  - `$2`: Command to execute on the configuration file (can be 'get', 'exists', 'equals', or 'set').
  - `$3`: Key to be manipulated or inquired about in the host configuration.
  - `$4`: (Optional) Value to be used in conjunction with the command argument.
- **Outputs:** Increments a counter `__HOST_CONFIG_PARSED` denoting that the config file was parsed. Writes to the host's config file.
- **Returns:** Exit status of the function. Returns `2` for an invalid command
- **Example Usage:** 
```bash
host_config "01:23:45:67:89:ab" "set" "TIMEZONE" "UTC"
```

### Quality and Security Recommendations
1. Code comments are clear and well-written. Continue this practice.
2. Consider implementing input validation for the MAC address and other arguments.
3. Ensure that permissions on the configuration file prevent unprivileged users from reading or altering it.
4. If the configuration file contains sensitive data, consider implementing encryption measures.
5. Error messages should ideally print to `stderr`, which is already done for invalid commands.
6. Provide a usage message when the function is called incorrectly. This could be embedded in the existing error message for invalid commands.

