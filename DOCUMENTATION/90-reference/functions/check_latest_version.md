#### `check_latest_version`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: 3b874dd0168548a5363b9c63f357dab1016d452e1155213b1190930b50bb44c5

##### Function overview

This Bash function, `check_latest_version`, checks the latest version of an Operating System (OS) based on parameters passed to the function. Specifically, it needs the CPU architecture, the manufacturer, and the OS name. If the OS is Rocky Linux, it fetches the HTML of the Rocky Linux downloads page and greps for the version number in the HTML. It retrieves all versions, sorts them in descending order, and outputs the latest version. If the OS variant is unknown, the function returns an error.

##### Technical description

- **Name**: `check_latest_version`
- **Description**: The function checks and outputs the latest version of an Operating System (OS) from its downloads page based on the input parameters. It works specifically with Rocky Linux.
- **Globals**: None.
- **Arguments**: 
  - `$1`: CPU architecture (Description of the CPU architecture)
  - `$2`: Manufacturer (Description of the manufacturer)
  - `$3`: OS Name (Name of the Operating System)
- **Outputs**: 
  - Error message if it fails to fetch the download page or the OS variant is unknown
  - Message stating the latest version of the operating system
- **Returns**: 
  - `1` If it fails to fetch the download page, finds no versions for the OS, or if the OS variant is unknown
  - `0` If it successfully gets the latest version of the OS
- **Example Usage**: 

```Bash
  check_latest_version "x86_64" "Intel" "rockylinux" 
```

##### Quality and security recommendations

1. Curl is operating without a timeout, which can cause the function to hang indefinitely if the server fails to respond. Incorporating a reasonable timeout can prevent this.
2. The function should validate the identifiers (`$cpu`, `$mfr`, and `$osname`) against known values before proceeding for extra security.
3. Error handling/messages can be improved to provide more specific and meaningful information for debugging purposes.
4. SSL verification is turned off in the curl command. This can be a security risk.
5. The function should handle other OS types, not just Rocky Linux, to make it more versatile.
6. The regular expression in the `grep` command could be improved to better match version patterns and avoid false positives.
7. The function currently runs on a set URL, which makes it less flexible. Adding ability to handle different URLs will make the function more reusable.

