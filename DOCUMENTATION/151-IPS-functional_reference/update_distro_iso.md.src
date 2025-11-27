### `update_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: a0dbc05086e473d99eb0bcb51d5eebbb8b04237c7f7d828c90a17cc8eceac8f1

### Function overview

The bash function `update_distro_iso()` is used to update the ISO file of the provided Linux distribution string. The function first unmounts the current ISO, prompts the user to update the ISO file, and then re-mounts it. The function takes one argument, `DISTRO_STRING`, and uses it to construct the ISO file and mount point location paths. If the function encounters any issues, such as if the provided distribution string is empty, the mount point remaining after attempting to unmount, or the ISO file does not exist, it returns an error to the command line and exits with a status code of 1.

### Technical description

- **Name:** `update_distro_iso()`
- **Description:** This shell function unmounts a specified Linux distribution ISO, prompts the user to update the ISO, and then remounts it.
- **Globals:** No globals are used in this function.
- **Arguments:**
    - `$1: DISTRO_STRING` Description: A string that identifies the Linux distribution ISO (format: `<CPU>-<MFR>-<OSNAME>-<OSVER>`).
- **Outputs:** Informational and error messages directed to the command line. 
- **Returns:** `1` if any errors occur, such as the DISTRO_STRING argument missing, the mount point still being present after attempting to unmount, or the ISO file not existing.
- **Example Usage:** `update_distro_iso "x86-Intel-Ubuntu-20.04"`

### Quality and security recommendations

1. This function assumes specific directory structure and filenames based on the `DISTRO_STRING`. It would be more robust and secure if it independently verified the path and filename before proceeding. 
2. To improve function's robustness, handle other potential errors, such as permission issues when attempting to unmount or mount the ISO file, or non-standard user input.
3. Function currently has no mechanism for verifying that the updated ISO file is valid or correctly formatted. Incorporate a verification step after the user updates the ISO.
4. To further enhance security, sanitize the user input to prevent command injection or make sure that the user input does not contain any special shell characters.

