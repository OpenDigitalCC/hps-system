### `host_config`

Contained in `lib/functions.d/host-functions.sh`

Function signature: e3395cb667c86565ac27cd12907de2a73dd934fe68e2741bcb6178e42eb80743

### Function overview

`host_config` is a Shell function that allows operations on configuration values associated with a host's MAC address. The function is capable of getting a configuration value, checking if a key exists, validating a key's value, and setting a key's value. The configuration data is stored in associative array `HOST_CONFIG`, and loaded from a configuration file located at `${HPS_HOST_CONFIG_DIR}/${mac}.conf`.

### Technical description

- **Name:** host_config
- **Description:** A Shell function to get, check and set configuration values for a specific MAC address.
- **Globals:** 
  - `__HOST_CONFIG_PARSED`: Indicates if a config file has been parsed.
  - `__HOST_CONFIG_MAC`: The currently loaded MAC address.
  - `__HOST_CONFIG_FILE`: The configuration file to load.
- **Arguments:**
  - `$1`: The MAC address of the host.
  - `$2`: The command to run on the configuration (get, exists, equals, or set).
  - `$3`: The key in the configuration to operate on.
  - `$4`: The value to set in the configuration, if the command is `set`.
- **Outputs:** Logs an error message when an invalid key or command is provided.
- **Returns:** `0` if operation is successful, `1` if a specified key does not exist, `2` if an invalid key format or command is provided, `3` if it fails to create a config directory or to write a configuration file.
- **Example usage:**
```bash
host_config '00:11:22:33:44:55' 'get' 'my_key'
host_config '00:11:22:33:44:55' 'exists' 'my_key'
host_config '00:11:22:33:44:55' 'equals' 'my_key' 'my_value'
host_config '00:11:22:33:44:55' 'set' 'my_key' 'my_value'
```

### Quality and security recommendations
1. Use printf instead of echo for more predictable and consistent output.
2. Be careful with the execution of `host_post_config_hooks` function, make sure it does not introduce security vulnerabilities.
3. Ensure the configuration directory and file have correct file permissions to prevent unauthorized access to the configuration.

