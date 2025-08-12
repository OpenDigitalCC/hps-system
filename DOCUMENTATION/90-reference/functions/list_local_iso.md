#### `list_local_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 2551c5d34fea622a4876a48c635391772020f951a812cc21a423cc6b87227a67

##### Function overview

The `list_local_iso()` function is designed to search and list iso files that match a specific naming pattern in a certain directory. The naming pattern derives from the CPU, manufacturer, operating system name and optionally, the operating system version. Important directories and files are managed with safety checks. Results of iso file search are displayed to the user with an alert mechanism implemented in case no matching iso files are found.

##### Technical description

**Name:** 
`list_local_iso()`

**Description:**
This function searches for iso files in a specific directory that match a naming pattern based on the CPU, manufacturer, operating system name and optionally, the operating system version.

**Globals:**
- `iso_dir` : the directory on the local system where the iso files are stored

**Arguments:**
- `$1: cpu`: The CPU model
- `$2: mfr`: Manufacturer information
- `$3: osname`: Name of the operating system
- `$4: osver`: (Optional) Operating system version

**Outputs:**
Prints out the name of any iso files found that match the naming convention.

**Returns:**
1 if no iso files were found that match the naming convention.

**Example usage:**
```bash
list_local_iso "Intel" "Dell" "Ubuntu" "18.04"
```

##### Quality and security recommendations

1. Add error checks for input parameters like invalid CPU, manufacturer, or OS name to enhance usability.
2. Implement permission checks before accessing `iso_dir` directory to prevent unwarranted access.
3. Enhance the pattern matching logic to prevent unintended matches.
4. Include logging for tracking and troubleshooting.
5. Improve the return codes mechanism to provide more specific error messages in case of failure.
6. Introduce a silent mode for suppressing output whenever needed. This will be helpful during automated processes.

