### `n_rescue_cleanup`

Contained in `node-manager/alpine-3/RESCUE/rescue-functions.sh`

Function signature: 1b08a28bfc2d05fe8dc5a06588d0b41d3ac5914b62017d8da2f93b2af383c8f3

### Function overview

The `n_rescue_cleanup` function is an integral part of a Bash script that helps perform various clean up operations on disk partitions. It does so by parsing arguments, logging remote information, reading and validating disk configurations, performing safety checks on the disk, unmounting filesystems, stopping MD arrays, zeroing superblocks, wiping filesystem signatures, clearing host configurations, and sets the final state of the node based on user input.

### Technical Description

- **Name**: `n_rescue_cleanup`
- **Description**: This function is designed to clean up disk partitions and associated configurations. This is typically used in system setup and recovery scenarios.
- **Globals**: `n_rescue_cleanup` does not appear to rely on any global variables.
- **Arguments**: `n_rescue_cleanup` takes the following optional arguments:
    1. `-f|--force`: Bypasses user interaction and confirmation prompts.
    2. `--wipe-table`: Wipes the partition table of the given disk.
    3. `[disk]`: The disk to cleanup
- **Outputs**: The function outputs logs and information to stderr throughout its execution. It will display information on operations such as unmounting filesystems, stopping MD arrays, wiping filesystem signatures, clearing host configurations, etc.
- **Returns**: The function will return numeric status codes corresponding to various exit points in the function, including `0` if everything completes successfully.
- **Example usage**: `n_rescue_cleanup /dev/sda` would be used to cleanup the disk at `/dev/sda`.

### Quality and Security Recommendations

1. Handle sensitive data: Ensure usage of this function in a script does not risk exposure of sensitive data (e.g. machine names, IP addresses) in logs or error messages.
2. Error handling: Improve on error handling, ensuring all possible error cases are covered and the output is logged.
3. Input validation: Be cautious of data that is passed into the function. Verify the disk input argument before proceeding with the function execution.
4. Use `-e` bash flag: This function might benefit from the `-e` bash flag, which causes the shell to exit if any invoked command exits with a non-zero status.
5. User prompts: In scripts meant to run without human interaction, it would be beneficial to remove or bypass user confirmation prompts.
6. Clearer documentation: While the function is reasonably well-commented, it could be beneficial to provide an upfront comment block detailing the function, its arguments, return values, and side effects.
7. Environment independence: Rely on environment variables and configuration files instead of hardcoded values to make the script adaptable to different environments.

