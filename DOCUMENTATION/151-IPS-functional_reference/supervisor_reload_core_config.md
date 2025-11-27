### `supervisor_reload_core_config`

Contained in `lib/functions.d/supervisor-functions.sh`

Function signature: 908b803c09dae08b0c269eda962224cbee23deb1e098eefe33f75098c3aa5c80

### Function overview

The `supervisor_reload_core_config()` function in bash is used to reload the configuration of the Supervisor core. This function fetches the path to the Supervisor configuration, then logs and executes two commands: `reread` and `update`. Both of these commands are executed via `supervisorctl` with the configuration file as the argument. By re-reading and updating, any changes made to the configuration file are applied without the need to restart the Supervisor service.

### Technical description

- *Name*: `supervisor_reload_core_config()`
- *Description*: This bash function fetches the path to the Supervisor configuration, then logs and executes `reread` and `update` commands using `supervisorctl`.
- *Globals*: 
  - `SUPERVISORD_CONF`: Points to the path where the Supervisor configuration file is located.
- *Arguments*: None
- *Outputs*: Logs the output of the `supervisorctl` `reread` and `update` commands.
- *Returns*: Nothing. It performs actions and output logs but does not provide a return value.
- *Example usage*:
    ```
    supervisor_reload_core_config
    ```
### Quality and security recommendations

1. Always ensure that the `supervisorctl` utility is available in the system and is up to date for correct functioning of this bash function.
2. Make sure the function has correct permissions set and can access the required `SUPERVISORD_CONF` path. This is essential for the function to perform correctly without any permission-related issues.
3. Add error handling for the function. Currently, it does not handle any potential errors that might occur while getting the Supervisor configuration path or executing `supervisorctl` commands.
4. In case of sensitive data printed in logs, make sure the logs are protected and securely stored.
5. Regularly review the logged data and function performance to detect any potential function- or configuration-related issues.

