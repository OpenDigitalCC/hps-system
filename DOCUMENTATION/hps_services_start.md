## `hps_services_start`

Contained in `lib/functions.d/system-functions.sh`

### Function overview

The `hps_services_start` function primarily serves to initiate all the services defined in the supervisor configuration by using the supervisor control (supervisorctl) command. It manages this through a clear pipeline of operations which starts with configuration set up and ends with all the defined services starting up.

### Technical description

- **Name**: hps_services_start
- **Description**: A function that configures supervisor services, reloads the supervisor configuration, and starts all services defined in the supervisor configuration.
- **Globals**: HPS_SERVICE_CONFIG_DIR: Directory path to the supervisord configuration file.
- **Arguments**: None
- **Outputs**: Not explicitly defined, but can include any output from the `configure_supervisor_services`, `reload_supervisor_config`, and `supervisorctl` commands.
- **Returns**: Not explicitly defined, but depends on the success of the `configure_supervisor_services`, `reload_supervisor_config`, and `supervisorctl` commands.
- **Example usage**:

```bash
hps_services_start
```
This example calls the function without any arguments, resulting in the configuration services being setup, supervisor configuration being reloaded, and all services defined in the supervisor configuration starting up.

### Quality and Security Recommendations

- Validate the environment variable `$HPS_SERVICE_CONFIG_DIR` to ensure it contains the correct path to the supervisord configuration file. Incorrect values or paths might lead to unforeseen errors.
- Ensure robust error handling mechanisms are in place to manage failures from `configure_supervisor_services`, `reload_supervisor_config`, and `supervisorctl` commands.
- Confirm that appropriate access controls are enforced around the function usage to maintain security and restrict unauthorized individuals.
- Implement proper logging mechanisms to capture any errors or debug information for future troubleshooting and audits.
- Ensure supervisord services are configured with least required permissions to mitigate any security vulnerabilities.
- Regularly update and patch supervisor and its components to secure against any known vulnerabilities.

