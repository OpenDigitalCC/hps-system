### `host_config_exists`

Contained in `lib/functions.d/host-functions.sh`

Function signature: 34de36858dffe5d99bd23615eca3110b87f3a65c04849bd3f82c9ba9fb2194ea

### Function Overview

`host_config_exists` is a bash function that is used to check if the configuration file for a particular host (identified by its MAC address) exists and is readable.

### Technical Description

- **Name:** `host_config_exists`
- **Description:** It accepts a MAC address as an argument and verifies if a corresponding configuration file exists on the local system. To ensure the check is reliable, the function employs `get_host_conf_filename`, which performs the actual existence and readability checks.
- **Globals:** None
- **Arguments:**
  - `$1`: MAC address (required) - The MAC address of the host for which the configuration file's existence is being checked.
- **Outputs:** This function does not output anything to STDOUT; it only uses exit codes to indicate results.
- **Returns:** Returns are exit codes and have the following meanings;
  - `0` - The configuration file exists and is readable.
  - `1` - No MAC address provided or the configuration file does not exist or is not readable.
- **Example Usage:** 

```bash
if host_config_exists "01:23:45:67:89:ab"; then
  echo "Configuration exists for host"
else
  echo "Configuration does not exist for host"
fi
```

### Quality and Security Recommendations

1. Always validate externally supplied variables before using them in the function.
2. Consider logging error messages in case of an exception or an unexpected scenario.
3. Remember to keep config files secured with correct permissions to avoid unauthorized access.
4. Always keep the function up to date considering any changes made in the `get_host_conf_filename` function since it relies on it.
5. Avoid using globals as they may produce unpredictable results, thus reducing the function's reusability.

