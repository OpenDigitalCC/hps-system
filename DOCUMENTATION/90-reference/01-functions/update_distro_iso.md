#### `update_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 2cc9510e14e685d9bd46ee12b37cf92d19a872fbfd40ed5f9884b79c76dc02d6

##### Function Overview

The function `update_distro_iso()` is a Bash shell function designed to manage the unmounting, update and re-mounting of an ISO file that corresponds to a distribution system. The function will ask the user to manually update the ISO file before re-mounting it. The main use case for this function is when an update is required on the ISO file.

##### Technical Description

- Name: `update_distro_iso`
- Description: This function unmounts an ISO file related to a particular distribution system, allows the user to manually update the ISO file, then it re-mounts the updated ISO file back to its original mount point.
- Globals: [ `HPS_DISTROS_DIR`: This variable stores the path of the directory where the ISO file to update is located. ]
- Arguments: 
  - `$1`: `DISTRO_STRING` -  This argument corresponds to a string representing the particular distribution system.
- Outputs: This function outputs various statuses and instructions to the user in the terminal.
- Returns: Returns 1 if there is an error at any point in the function: either if the `DISTRO_STRING` is empty, if the unmounting fails, if the mount point is still in use after unmounting, if the ISO file is not found, or if re-mounting fails.
- Example usage: `update_distro_iso <CPU>-<MFR>-<OSNAME>-<OSVER>`

##### Quality and Security Recommendations

1. Fork the process that unmounts and then re-mounts the ISO to prevent potential lock-up scenarios if the user doesn't follow through with the manual update.
2. Include error checking after the re-mount operation to ensure that mounting was successful before proceeding.
3. Implement logging of function actions to help debug any potential future issues.
4. Consider encapsulating user prompts to make them more robust and prevent incorrect user input.
5. Review the global variable `HPS_DISTROS_DIR` to ensure that it properly restricts access to required directories only.

