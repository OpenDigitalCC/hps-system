## `hps_services_stop`

Contained in `lib/functions.d/system-functions.sh`

### Function overview
The `hps_services_stop` function is a bash function that stops all services managed by the HPS (High Performance Systems) service manager. The function uses the `supervisorctl` command, with a configuration file defined by `HPS_SERVICE_CONFIG_DIR` global variable.

### Technical description

- **Name**: `hps_services_stop`
- **Description**: Stops all services managed by the HPS service manager.
- **Globals**: 
  - `HPS_SERVICE_CONFIG_DIR`: Absolute path to the directory containing supervisord configuration file.
- **Arguments**: None.
- **Outputs**: Any output or error message from the `supervisorctl` command.
- **Returns**: The exit status of the last command executed, in this case the `supervisorctl` command.
- **Example usage**:
```
# Given the configuration file is at "/etc/hps/supervisord.conf"
export HPS_SERVICE_CONFIG_DIR=/etc/hps
hps_services_stop
```

### Quality and security recommendations
- The function should validate that `HPS_SERVICE_CONFIG_DIR` variable is set and is not an empty string.
- It should check if the `supervisord.conf` file actually exists at the specified location before attempting to perform any operations.
- To ensure security, the user running this script should have the minimal privileges necessary to stop the services.
- The function can be enhanced to handle errors and exceptions thrown by the `supervisorctl` command.
- Any outputs and error messages should be logged for later reviewing.

