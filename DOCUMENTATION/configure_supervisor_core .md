## `configure_supervisor_core `

Contained in `lib/functions.d/configure-supervisor.sh`

### Function overview

The function `configure_supervisor_core` generates a supervisord configuration file at the location specified by the `SUPERVISORD_CONF` environment variable. This function also creates the directory `/var/log/supervisor` if it doesn't already exist. The configuration file includes settings for supervisord, supervisorctl, rpcinterface, and unix_http_server. Message output is provided to track the function's progress.

### Technical description

- **Name**: `configure_supervisor_core`
- **Description**: The function generates a supervisord configuration file with mandatory fields.
- **Globals**: [ `HPS_SERVICE_CONFIG_DIR`: The directory where the supervisord configuration file is to be stored. ]
- **Arguments**: None.
- **Outputs**: Prints messages on stdout about the function’s progress and completion.
- **Returns**: None.
- **Example usage**: The function is used as `configure_supervisor_core`
  
### Quality and security recommendations

1. Use more descriptive names for variables, and include comments explaining what each variable is used for.
2. Should configure error handling so if the supervisor service can't be created for any reason, it returns a meaningful error message.
3. The "admin" username is hardcoded, it is recommended to store usernames in environment variables or some sort of secure and encrypted configuration that can be loaded at runtime.
4. The password is currently hardcoded as "ignored-but-needed", this should be replaced with a more secure method, such as a randomly generated password or one provided securely at runtime. Alternatively, it could be removed if it isn't needed.
5. Consider setting the supervisor to run as a non-root user for increased security.
6. Use explicit file permissions when creating directory to prevent unauthorized access.

