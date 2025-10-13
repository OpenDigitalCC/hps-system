### `download_iso`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: a769efc53df917e64e3dbdfb8acb70dff4b4cb4a89efd3b55a689c47cde86e91

### Function overview

The function `download_iso` retrieves a specific version of an Operating System (OS) installation ISO file based on certain parameters such as the CPU architecture, the manufacturer, the name and version of the OS.


### Technical description

The function is defined as follows:

- **Name:** `download_iso`
- **Description:** Downloads an ISO file for a certain OS from a base URL, builds the proper download URL and the filename of the downloaded ISO file, checks if the ISO file already exists, and if not, downloads the ISO file and saves it to a designated directory. In case of download failure, it cleans up the failed download file. Currently, only "rockylinux" is supported as the OS name.
- **Globals:** No global variables used.
- **Arguments:**
  - `$1: CPU architecture`
  - `$2: Manufacturer`
  - `$3: OS name`
  - `$4: OS version`
- **Outputs:** Prints status messages about the download process, such as whether the ISO file already exists or if the OS variant is unsupported, the status of ISO download process, etc.
- **Returns:** 0 if the ISO file already exists or if it was successfully downloaded; 1 in case of any failures, such as unsupported OS variant or a failed download.
- **Example usage:** `download_iso x86_64 intel rockylinux 10`


### Quality and security recommendations

1. Consider adding more OS support, not just Rocky Linux.
2. Catch and properly handle potential problems, such as issues with the directory creation (`mkdir -p "$iso_dir"`), to prevent unexpected results or vulnerabilities.
3. Implement checksum validation after download to ensure the downloaded ISO file is correct and wasn't tampered with during transit.
4. Refactor the case block for OS names into separate functions for better readability and maintainability.
5. Use secure coding practices and constant code reviews to avoid potential security issues.
6. Test the function thoroughly under different conditions and scenarios to ensure it behaves properly.

