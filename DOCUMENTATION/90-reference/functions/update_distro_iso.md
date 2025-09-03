### `update_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 2cc9510e14e685d9bd46ee12b37cf92d19a872fbfd40ed5f9884b79c76dc02d6

### Function overview

The `update_distro_iso` function is a Bash function used to update an ISO image of a given Linux distribution. This function takes a single string argument `DISTRO_STRING` representing the distribution to update. It then unmounts the respective distribution ISO, prompts users to update the ISO file manually, checks if the ISO file exists and is properly updated, and finally re-mounts the ISO. If any step fails, the function returns with an exit code of 1. 

### Technical description

- **Name:** `update_distro_iso`
- **Description:** This bash function is designed to update the ISO image of a desired Linux distribution. It unmounts the currently mounted ISO, prompts user to manually update the ISO file, verifies if the updated ISO file exists, and remounts the updated ISO. If any of these steps fails, it outputs an error message and exits with a 1 status.
- **Globals:** [ `HPS_DISTROS_DIR`: Directory path where the Linux distributions ISO are stored ]
- **Arguments:** [ `$1: DISTRO_STRING`: String representing the Linux distribution to be updated ]
- **Outputs:** Messages detailing the status and results of each operation, including potential errors.
- **Returns:** The function returns 1 if any step of the process fails. If everything proceeds smoothly, there is no explicit return statement, so the function's status is the exit status of the last command executed (per bash's standard behavior). 
- **Example usage:**
    ```shell
    update_distro_iso "x86-Ubuntu-16.04"
    ```

### Quality and security recommendations

1. Validate that `DISTRO_STRING` is not empty at the beginning of the function to avoid unnecessary operations.
2. Consider checking that the manual ISO update was successful after the `Press ENTER when ready to re-mount...` statement.
3. Implement file existence and readability checks before trying to unmount or mount ISO files to avoid potential errors.
4. Consider using explicit return and exit codes to help clarify the function's behavior during debugging.
5. It's a good practice to use proper sanitization to free shell commands from potential code injection attacks. Ensure that user inputs are sanitized and safe before constructing paths based on them.

