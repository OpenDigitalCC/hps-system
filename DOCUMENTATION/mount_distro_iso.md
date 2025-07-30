## `mount_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

### Function Overview

`mount_distro_iso` is a Bash function that is used for mounting ISO images of different Linux distributions on your system. It takes two arguments: `DISTRO_STRING` which is the string identifier of the Linux distribution, and `iso_path` which is the path to the ISO file. Using these, the function mounts the ISO file to a provided mount point. If the ISO file or the mount point does not exist, it logs error messages and returns appropriate values.

### Technical Description

- **Name:** `mount_distro_iso`
- **Description:** This function mounts a given Linux distribution ISO file to a defined mount point. It first checks if the ISO file exists and if the mount point is already in use. If the ISO file doesn't exist, it exits with a return value of 1 indicating an error. If the mount point is already in use, it exits with a return value of 0, indicating that no new action is required. Otherwise, it creates the mount point directory if it doesn't exist, then mounts the ISO file to it.
- **Globals:** `HPS_DISTROS_DIR` describes the directory where the distributions' ISO files are stored.
- **Arguments**: 
     - `$1`: `DISTRO_STRING`, a string representing the name of the Linux distribution, used to find the ISO within the specified directory.
     - `$2`: `iso_path`, path where the ISO file of the distribution is located.
- **Outputs:** Information and error logging information directly to stdout.
- **Returns:** Returns 1 if the required ISO isn't found or 0 if no actions are needed as the ISO is already mounted. No return value is mentioned when actions have been successfully performed, which means it reduces to exit status of the last `mount` command.
- **Example usage:** `mount_distro_iso ubuntu ./iso/ubuntu.iso`


### Quality and Security Recommendations

1. The function should validate its input arguments to mitigate potential command injection vulnerabilities.
2. It should return a distinct status code in case of success.
3. The error messages should be sent to stderr instead of stdout.
4. Check if the file being mounted is indeed an ISO file with file extension checks or file magic checks.
5. The function should log detailed errors from the `mount` command on failure.
6. Add an unmount feature as well, to return the system to its original state after operations on the mounted ISOs are done to save system resources.
7. Document and handle abnormal behaviors such as lack of permissions to create a directory or to mount files.

