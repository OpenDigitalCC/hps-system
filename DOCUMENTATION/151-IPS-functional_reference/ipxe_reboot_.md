### `ipxe_reboot `

Contained in `lib/functions.d/ipxe-menu-functions.sh`

Function signature: c2e2fb28eaa8f9898d8b5cb181b2b278c884005d1a98813c38797c3225f12b52

### Function overview

The function, `ipxe_reboot`, accepts a single argument, `MSG`, logging that a reboot was requested with `MSG` as a parameter, outputs specific headers using the `ipxe_header` function, and then echoes `MSG`. If `MSG` is not an empty string, it echoes that the system is rebooting, puts the system to sleep for 5 seconds, and then reboots the system.


### Technical description

 - **Name**: `ipxe_reboot`
 - **Description**: This function logs an info message showing that a reboot is requested, outputs headers using another function `ipxe_header`, checks if `MSG` (first input argument) is not a null string and echoes it if true. It then echoes "Rebooting...", puts the system to sleep for 5 seconds and then reboots the system.
 - **Globals**: None
 - **Arguments**:
   - `$1 (MSG)`: The message to be logged and echoed just before the reboot command. It's optional, and if it's null or not defined, it won't be used.
 - **Outputs**: Echoed statements to the standard output for logging and status updates.
 - **Returns**: No value is returned as the terminal will be closed upon successful function execution because of the `reboot` command.
 - **Example usage**: `ipxe_reboot "System updates are completed"`

### Quality and security recommendations

1. Always make sure to validate the input parameters. Even though this function does not explicitly use user-provided inputs, it's still a good practice.
2. The `reboot` command is a powerful system command. Ensure this function is only accessible to and executable by authorized users and applications to prevent misuse.
3. There are no command success/failure checks in the function. Consider adding error handling or command result checks to make the function more robust.
4. In an environment where the system log is reviewed or parsed, consider standardizing the log format to make the logs more readable.
5. The function depends on another function, `ipxe_header`. Ensure this dependant function is robust, secure, and available where `ipxe_reboot` is used to avoid runtime errors.
6. Avoid hard-coding values such as the sleep duration. It would be a better practice to make such values configurable.

