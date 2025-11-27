### `supervisor_reload_services`

Contained in `lib/functions.d/supervisor-functions.sh`

Function signature: f7f5dbec5d6c487b41efa7323a44d1ec6d88cb0befd10f9de4bdfd11727c57bf

### Function overview

The function `supervisor_reload_services()` is designed to send a `HUP` signal (Hang UP) to services managed by `supervisord`. The function primarily verifies if the supervisord configuration file exists and then decides the target of the HUP signal. It logs the outcome of executing the HUP signal.

### Technical description

- **Name:** `supervisor_reload_services()`'
- **Description:** This function sends a HUP signal to either a specific `supervisord` service or all `supervisord` services, based on the provided arguments.
- **Globals:** `SUPERVISORD_CONF: The path to the supervisord configuration file.`
- **Arguments:** `$1: The name of the service to signal. If this argument is not provided, the function sends a HUP signal to all supervisor services.`
- **Outputs:** Logs an error message if the `SUPERVISORD_CONF` is empty or if the configuration file doesn't exist. It also logs the results of sending the HUP signal.
- **Returns:** Returns 0 if the HUP signal was sent successfully, returns 1 if the `SUPERVISORD_CONF` is empty or if the configuration file doesn't exist, and returns 2 if failure in sending the HUP signal.
- **Example usage:**
  ```bash
  supervisor_reload_services my_service
  ```

### Quality and security recommendations
1. It's recommended to validate the input for `service_name`, ensuring it does not contain harmful characters that could lead to command injection vulnerabilities.
2. Logging should be correctly implemented to help troubleshooting and to avoid leaking sensitive information in case of errors.
3. Instead of returning numeric values, consider creating an enumeration of error types and return these for better readability.
4. Always consider edge cases where the SUPERVISORD_CONF is incorrectly set or the configuration file does not exist. This function is already handling these cases gracefully.
5. Caution should be taken into account when dealing with highly privileged services to avoid violating the principle of least privilege.

