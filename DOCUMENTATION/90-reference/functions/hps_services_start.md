### `hps_services_start`

Contained in `lib/functions.d/system-functions.sh`

Function signature: d803223c5cd9a326d513c4b57b5085266767da7cb4e9c6c99acebea677274834

### Function overview

The `hps_services_start` function is meant to start all services under supervisor control. It first configures the supervisor services, then reloads the supervisor configuration. After that, it uses the `supervisorctl` command to start all the services defined in the supervisord configuration file.

### Technical description
Here is a definition block for `hps_services_start` function.

- Name: hps_services_start
- Description: This function starts all services under supervisor control.
- Globals: [ HPS_SERVICE_CONFIG_DIR: The directory that includes the supervisord configuration file]
- Arguments: None
- Outputs: It does not return any output as it interacts directly with the supervisor control manager to configure and start services.
- Returns: The status code of the `supervisorctl start all` command.
- Example Usage: 

```bash
hps_services_start
```

### Quality and security recommendations
Here are a few improvements that could be made:

1. Add error handling: The function does not handle any potential errors that might occur during starting the services. Proper error handling can be implemented to return useful error messages and halt the script execution when necessary.
2. Validate variable: The variable `HPS_SERVICE_CONFIG_DIR` should be validated before passing it to the `supervisorctl` command to prevent potential command injection attacks.
3. Add Documentation: Each step in the function could use commenting explaining what it does in detail. This would help future developers understand the function more easily.
4. Status Check: After executing the `supervisorctl` command, the function should check and confirm whether the services have indeed been started or not.

