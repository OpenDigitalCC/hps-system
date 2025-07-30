## `update_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview

The `update_distro_iso` function in Bash aims to assist in the handling of a Linux distribution ISO file. It gets the name of a distribution (DISTRO_STRING) as a parameter, specifies the path to the ISO file and its mount point, and checks for the non-existence of the provided distribution name. If the distribution string is available, it will attempt to unmount it. If unmounting fails or the ISO file does not exist, it will display an error and abort the operation. But if it exists, it prompts the user to update the ISO file, and upon the user's confirmation, it attempts to re-mount the ISO file.

### Technical description
- **name**: `update_distro_iso`
- **description**: A Bash function that handles the unmounting, updating, and remounting of a Linux distribution ISO file.
- **globals**: `[ HPS_DISTROS_DIR: A global variable that holds the root directory for multiple Linux distributions. ]`
- **arguments**: `[ $1: Distinctive string representing a Linux distribution, typically in the format <CPU>-<MFR>-<OSNAME>-<OSVER> ]`
- **outputs**: Outputs to stdout, mainly informing the user about the status of the ISO file, like whether it is mounted/unmounted, or whether the user can update the ISO file or not.
- **returns**:  Returns `1` if the DISTRO_STRING is not provided, the iso-file of the given distribution is not found or mounting or unmounting fails.
- **example usage**:

    ```bash
    update_distro_iso ARM-Manufacturer-OSname-OSversion
    ```

### Quality and security recommendations

- Always guard against file path injection. Validate inputs thoroughly, and consider if they might include relative path specifiers that could lead to improper filesystem access.
- The function uses the local keyword which makes the variable only visible within the function. Also, keep in mind that even when declaring local variables, if not initialized, they can inherit the value of a global variable of the same name, so be careful with variable initialization.
- Always handle errors correctly. It is beneficial to exit when something goes wrong, rather than continuing on and possibly causing more problems down the line. In this script, if any problem occurs, it returns a non-zero value.
- Consider making the output more user friendly, especially when it comes to error messages. Where possible, provide hints or suggestions for the user. For example, if the ISO file is not found, consider suggesting where the user could find a valid ISO.

