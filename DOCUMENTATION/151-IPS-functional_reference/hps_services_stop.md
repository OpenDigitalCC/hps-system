### `hps_services_stop`

Contained in `lib/functions.d/system-functions.sh`

Function signature: 8389cadf05a55bb98c0cc0b40a84671a6cc4e156fdaaafee6f327e84dff29f00

### Function overview

The function `hps_services_stop()` is utilized to halt all running services under the control of the Supervisor program. The function operates by calling the supervisor control command (`supervisorctl`) and specifying the path to the Supervisor configuration file, which obtains from invoking another function (`get_path_cluster_services_dir`). It's an essential function for maintaining system stability and clean shutdown processes.

### Technical description

- **Name:** `hps_services_stop()`
- **Description:** This function stops all services managed by Supervisor, by calling the `supervisorctl` command along with the path to the configuration file.
- **Globals:** None.
- **Arguments:** None.
- **Outputs:** The function outputs any notifications or errors from the `supervisorctl` command. If successful, it will output standard messages from `supervisorctl` signifying the successful stopping of all services.
- **Returns:** It might return exit codes from the `supervisorctl` command. In general, if all services stopped successfully, a zero (signifying success) will be returned. Non-zero if any error occurs.
- **Example usage:** `hps_services_stop` (since the function does not require arguments, it can be invoked directly via the function name)

### Quality and security recommendations

1. Ensure proper user permissions: Make certain the function is only executed by users with proper permissions to halt the services. Access to such commands should be strictly regulated.
2. Error Handling: Incorporate error handling to catch any issues that might arise from the `supervisorctl` command. It may not always be able to halt services for various reasons.
3. Logging: Implement logging to keep track of when and why specific services were stopped. This can be beneficial for auditing and problem-solving purposes.
4. Documentation: Maintain clear documentation of this function to facilitate its use and maintenance.
5. Secure Path: Avoid manipulating the function such that the path input for the configuration file could be substituted or tampered with by an untrusted source.

