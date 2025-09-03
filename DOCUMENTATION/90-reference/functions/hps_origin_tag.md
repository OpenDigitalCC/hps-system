### `hps_origin_tag`

Contained in `lib/functions.d/system-functions.sh`

Function signature: 7cb345cab5af5348e693c4093a5262f82a902f7c5455f50302572d52570efcaa

### Function overview

The **hps_origin_tag** function is designed to generate an origin tag based on the context of where it is called. The function primarily uses the following information to construct this origin tag:
- Optional override value passed to the function
- Current PID, username and hostname if running in a TTY environment
- Client IP or MAC address, if available and running in a non-TTY environment
- Current PID, if running in a non-TTY environment with no available IP or MAC

This function may be primarily used for logging or tracking the origin of different processes or actions within a system.

### Technical description

The technical specifications for this function are:

- **Name**: hps_origin_tag
- **Description**: This function generates an origin tag using several pieces of contextual data, such as the process ID, user, host, and optionally, the client MAC or IP address.
- **Globals**: None directly, the function uses the system-defined \$HOSTNAME and \$REMOTE_ADDR variables if available.
- **Arguments**: \$1 (optional) - An override value that, if provided, will be used as the tag instead of any other checks.
- **Outputs**: Prints a string to stdout. This string will be a 'pid', 'user:host', 'mac', or 'IP' tag based on the available data and presence of a TTY environment.
- **Returns**: Always 0 (success)
- **Example usage**:
   ```bash
   origin_tag=$(hps_origin_tag "override") # Uses the provided override
   origin_tag=$(hps_origin_tag) # Generates a tag based on context
   ```

### Quality and security recommendations

1. **Sanitize inputs**: The function currently does not perform any checks or sanitization on the input override string. Potentially, this could lead to unexpected behavior if the override contains special characters or whitespace. 
2. **Check for command availability**: The function assumes that `id`, `hostname` and similar commands will be available, and only executes them in a subshell if they are allowed to fail. It's recommended to explicitly check for the availability of these commands before proceeding.
3. **Error checking**: The function currently suppresses all command error outputs. Although it handles the most common issues, it should also consider checking and handling other types of errors (e.g., if `printf` fails for some reason).
4. **Unset variables**: Although the function handles unset variables gracefully with the `${VAR:-}` notation, it does not explicitly check if `$HOSTNAME` or `$REMOTE_ADDR` are set before trying to use them, potentially leading to subtle bugs. It's suggested to add these checks.
5. **Security of Information displayed**: The function shares information like the user and host in the tags it generates. Be aware that sharing such details can be a security concern, depending on how and where the function is used.

