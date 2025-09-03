### `unmount_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 8736c022aa1702dffb2efe53cc382894bbe29e4a44b302d6fe6c2f67439871c6

### Function Overview

The function `unmount_distro_iso` is used to unmount a distribution ISO. Given the string name of a distribution, it attempts to unmount the ISO if it is currently mounted. The ISOs are stored in the directory specified by the global variable `HPS_DISTROS_DIR`. If the ISO is not mounted, it returns 0, otherwise it logs the attempts to unmount the ISO and returns 0 if it is successfully unmounted and 1 otherwise.

### Technical Description

- **name**: unmount_distro_iso
- **description**: Attempts to unmount a given distribution ISO.
- **globals**: 
   - HPS_DISTROS_DIR: The directory of where the ISO's are stored.
- **arguments**: 
  - $1: string name of the distribution (DISTRO_STRING)
  - $2: none
- **outputs**: Logs info level messages documenting the unmounting attempt.
- **returns**:
  - Returns 0 if the ISO is not mounted or successful in unmounting.
  - Returns 1 if it fails to unmount the ISO.
- **example usage**: unmount_distro_iso ubuntu

### Quality and Security Recommendations

1. Add error checking for the input arguments. Currently the function assumes that the input will be correct and does not check if the distribution string is empty or if it contains illegal characters.
2. Improve logging. On failure, consider logging the error message output from the `mount` command.
3. Use absolute paths. Relying on relative paths can lead to unexpected behaviour, depending on the working directory when the script is executed.
4. Check that `HPS_DISTROS_DIR` value is set before using it to avoid errors.
5. Make sure that appropriate permissions and ownership settings are in place. This can prevent unauthorized access or modifications.

