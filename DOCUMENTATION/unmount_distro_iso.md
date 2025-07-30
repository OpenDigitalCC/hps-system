## `unmount_distro_iso`

Contained in `lib/functions.d/iso-functions.sh`

### Function overview

The `unmount_distro_iso` function is used for unmounting distribution ISO files in Linux operating system. It takes in a string that defines the distribution and unmounts the corresponding ISO file. A log message is generated if the distribution ISO is not mounted or fails to unmount.

### Technical description

**Name**: 
`unmount_distro_iso`

**Description**: 
This function unmounts an ISO file of a given Linux distribution. It checks if the distribution ISO is already mounted, if not it logs an info. If it is, it unmounts the ISO file and logs the unmount operation's status.

**Globals**:
- `HPS_DISTROS_DIR`: Directory path of distributions

**Arguments**:
- `$1`: Name of the Linux distribution to unmount
- `$2`: Not used in this function

**Outputs**: 
Logs info messages relating to the mount point and unmount operation status.

**Returns**: 
Returns 0 if the mount point was not mounted or if the dismount was successful. Returns 1 if it fails to unmount the distribution ISO.

**Example usage**: 
`unmount_distro_iso ubuntu-20`

### Quality and security recommendations

- Always verify if the `DISTRO_STRING` argument has been provided before using it
- It would be a good idea to handle other error cases, like permission denied or directory not found
- Consider checking for potential security vulnerabilities, like command injection, since file and directory paths are used as an argument to system commands
- Utilize clear and concise logging messages to aid in future debugging or incident response.
- Enforce the principle of least privilege: users should only have permissions to resources they need, this can help limit the potential fallout of a compromised user account.

