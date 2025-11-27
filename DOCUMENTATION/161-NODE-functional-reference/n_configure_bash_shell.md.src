### `n_configure_bash_shell`

Contained in `node-manager/base/n_shell-config.sh`

Function signature: c83730f9e26d12f2581923a5fe9680453330d4ab55e3ed697ef18a019bf3a73e

### Function overview
The `n_configure_bash_shell()` function facilitates seamless bash shell configuration as a preferred shell. The function initiates with a status log styled as "[INFO] Configuring bash as default shell". The function checks whether bash shell is installed and then proceeds to change the /bin/sh symlink from its current target to bash. Once the symlink has been successfully configured to bash, the function creates a profile.d drop-in feature for additional versatility in command executions. The function provides an informative output log if the bash shell configuration is completed successfully, and returns status codes depending on the execution status.

### Technical description
- **Name**: n_configure_bash_shell
- **Description**: Configures bash as the default shell, checks if the bash shell is installed, modifies the /bin/sh symlink from its current state to bash, and finally creates a profile.d drop-in file in /etc/profile.d/.
- **Globals**: None.
- **Arguments**: None. 
- **Outputs**: Status and error messages are outputted to stderr to inform the user about the current status of the function.
- **Returns**: The function primarily returns three codes upon its completion: 
  1. Returns 0 if the function execution is successful.
  2. Returns 1 if there is an error in either creating the bash symlink or if the bash shell is absent.
  3. Returns 2 if the function fails to either create a profile drop-in or set permissions to it. 
- **Example Usage**: 
  ```
  n_configure_bash_shell
  ```

### Quality and security recommendations
1. Include more conditional statements to check other possible points of failure, such as checking if the current shell is already bash.
2. Handle possible exceptions such as the absence of some files or directories the function depends on.
3. Encapsulate the global variables used within the function to ensure there would be no conflicts with other scripts.
4. Develop a rollback mechanism that reverts any changes made if the function execution fails at any point.
5. The error messages should be more descriptive to better assist in troubleshooting.
6. User input should be validated and sanitized to mitigate the possibility of code injection.
7. Input parameters should be handled properly to improve the function’s reusability.
8. Log files should be maintained to keep track of every operation for auditing and troubleshooting purposes.
9. Ensure the script is running with minimal permissions to reduce possible risks.

