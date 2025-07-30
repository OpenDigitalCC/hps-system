## `initialise_distro_string`

Contained in `lib/functions.d/configure-distro.sh`

### Function overview

The function `initialise_distro_string()` is primarily intended to identify and provide a unique string representation of the system's operating distribution (distro), its CPU architecture, version number and manufacturer. The function first fetches the CPU type using the `uname -m` command and the manufacturer is predefined as "linux". Then, it checks for the existence of '/etc/os-release' file. If this file exists, it's sourced and the distro name(`osname`) and version(`osver`) are extracted from the environment variables `ID` and `VERSION_ID` respectively, then converted to lowercase. If the file doesn't exist, 'unknown' is assigned to both `osname` and `osver`. Finally, it concatenates and echoes these information in a specific format - `<cpu>-<mfr>-<osname>-<osver>`.

### Technical description

- **Name**: `initialise_distro_string`
- **Description**: This function collects and reports system information in a string format, featuring the architecture, manufacturer, distro name, and version. 
- **Globals:**
  - None used explicitly
- **Arguments**: None
- **Outputs:** 
  - Echoes a string consisting of CPU architecture, manufacturer, distribution name, and distribution version all separated by hyphen(-).  
- **Returns:**
  - None
- **Example usage**:
   
   ```
   $ initialise_distro_string
   ```

### Quality and security recommendations

1. Add documentation for this function, describing what it does, its inputs, outputs and return values.
2. Implement error handling for if `uname -m` command fails to execute. Currently, it silently fails in that case, which may lead to unexpected results.
3. Check if the variables `ID` and `VERSION_ID` exist in the `/etc/os-release` file before assigning them to `osname` and `osver`.
4. Validate/verify the data read from `/etc/os-release` file. It's a potential security risk to trust this data implicitly.
5. Consider using a more granular access control method for determining whether `/etc/os-release` exists and can be read. Currently, a failure to access this file would default the OS name and version to 'unknown', which may not be a accurate reflection of the system status.

