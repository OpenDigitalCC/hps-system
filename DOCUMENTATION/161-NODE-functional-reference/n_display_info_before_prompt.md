### `n_display_info_before_prompt`

Contained in `lib/node-functions.d/common.d/console.sh`

Function signature: dcac048f62180791d143d456e76ba9be0d27cf9a94e052158bdc2101bc2a17cd

### Function overview

The bash function `n_display_info_before_prompt()` serves to display basic node information on the console every time it is restarted. The function first logs that the node information is being displayed and then checks whether the console is disabled by scanning through `/etc/inittab`. If the console is disabled, a log about it is created and the display will be handled by init respawn instead. Else, the function makes sure that the `n_node_information` is available and updates the issue file with the relevant node information. This issue file is then displayed on the console providing the node info logs.

### Technical description

- **Name**: `n_display_info_before_prompt()`
- **Description**: This function log's the node information, checks if the console is disabled, generates node info logs, and creates updates the issue file to be displayed on console.
- **Globals**: `${console_disabled}`, a binary variable to check if console is disabled or not.
- **Arguments**: No arguments accepted.
- **Outputs**: Logs of node information, sends them to remote logs when necessary, and displays them on the console.
- **Returns**: The function returns 0 indicating successful execution.
- **Example usage**: To use this function, call it without any arguments like so: `n_display_info_before_prompt`.

### Quality and security recommendations

1. Handle errors when the `n_node_information` is not available or fails to execute. This would make the function more resilient. 
2. Use full paths for all binaries to avoid dependency on `PATH` that can be exploited in some cases.
3. Restrict editing rights to `/etc/issue` to prevent tampering.
4. Document the requirements and side effects of the function more explicitly.
5. Validate and sanitize any external inputs used in the function to avoid injection attacks.
6. Be cautious about symlink attacks, especially when writing to `/etc/issue`. Make sure that the intended real file gets edited.
7. Implement some form of rate limiting to the function to prevent abuse.

