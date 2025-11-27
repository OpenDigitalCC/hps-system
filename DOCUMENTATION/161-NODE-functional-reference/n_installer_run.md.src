### `n_installer_run`

Contained in `node-manager/alpine-3/+INSTALLING/installer-functions.sh`

Function signature: d059d8ab8cb8ce3656dca63dc8b16af5dfa85629dbb5732522194909b33d1f04

### Function overview

The `n_installer_run` is a Bash function designed to automate the process of installing the Alpine SCH system on a remote host. It takes no arguments and expects to run in an environment where other `n_` functions and global variables are predefined. It sequentially calls other installation functions, providing detailed logging of the execution process, and updates the status of installation on the remote host.

### Technical description

- **Name:** `n_installer_run`
- **Description:** The function sequentially runs system installation steps, logs the actions and errors, and keeps the remote host updated with the state of the installation.
- **Globals:**
    - `STATE`: reflects the current state of the installation;
    - `INSTALL_ERROR`: reflects the error during installation steps.
- **Arguments:** None
- **Outputs:** Logs messages to the remote log about the status of each installation step. 
- **Returns:** 
    - `1` if Disk detection step failed;
    - `2` if Partitioning step failed;
    - `3` if Formatting step failed;
    - `4` if Alpine installation step failed;
    - `5` if HPS init installation step failed;
    - `6` if Finalization step failed;
    - `0` in event of reaching the bottom of function, implying an error since finalization is supposed to reboot.
- **Example usage:** The function is called without arguments, like so: `n_installer_run`

### Quality and security recommendations

1. Create local worker functions or scripts for each installation step to improve readability, testability, and maintainability of the code.
2. Use more descriptive identifiers for the global variables to avoid potential naming conflicts.
3. Handle and validate possible errors and exceptions in a more comprehensive way, focusing on potential system issues.
4. Include more detailed logging for troubleshooting purposes and clarity.
5. Verify permissions and authenticate all system-level actions to improve security.
6. Implement timeouts to prevent hanging processes during the installation steps.

