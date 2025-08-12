#### `unmount_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 8736c022aa1702dffb2efe53cc382894bbe29e4a44b302d6fe6c2f67439871c6

##### Function overview

The function `unmount_distro_iso` is used to unmount a given Linux distribution's ISO file. The function accepts a distribution string and uses it to create a mount point path which is then unmounted if it is currently mounted.

##### Technical description

- **name**: unmount_distro_iso
- **description**: This function unmounts the ISO file of a specified Linux distribution if it is currently mounted. If it is not mounted, the function just logs information about it not being mounted and returns 0.
- **globals**: [ HPS_DISTROS_DIR: This is a directory path where the distribution is located ]
- **arguments**: [ $1: Distribution string used to create the mount point path, No other arguments ]
- **outputs**: Logs info on whether the ISO was successfully unmounted or if it failed.
- **returns**: 
    - 0 if the mount point is not currently mounted or if the ISO file was unmounted successfully.
    - 1 if it failed to unmount the ISO file.
- **example usage**:
    ```bash
    unmount_distro_iso Ubuntu
    ```

##### Quality and security recommendations

1. Always validate inputs: It might be possible to pass in arguments that could lead to unmounting of directories that were not intended. Validate the provided distribution string to avoid these scenarios.
2. Error Handling: The error handling currently only logs the failed unmount but the script continues regardless. It might be danger in some cases to continue with the script if an unmount fails, depending on the script.
3. Redirection: Redirection of stdout and stderr may hide valuable debugging information in the event of unexpected errors, consider logging them to a file instead.
4. Process handling: It might be helpful to handler the case where the `umount` command may be stuck due to a busy device or a stale file handle.

