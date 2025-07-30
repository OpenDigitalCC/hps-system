## `check_and_download_latest_rocky`

Contained in `lib/functions.d/iso-functions.sh`

### Function Overview
The function `check_and_download_latest_rocky` is designed to check for the latest version of Rocky Linux available for the x86_64 architecture and download the minimal ISO file if not already present on the system. The function uses `cURL` to download the ISO file, if not found locally. It also log the latest version number for debugging purposes and creates necessary directories for storing ISO files.

### Technical Description
- **Name:** check_and_download_latest_rocky
- **Description:** Checks for the latest version of Rocky Linux available and downloads the ISO file if not present in the local system. The downloaded ISO is minimal for `x86_64` architecture.
- **Globals:**
  - HPS_DISTROS_DIR: The directory in which the ISO file will be stored.
- **Arguments:** No arguments required.
- **Outputs:** Downloads the ISO file. Prints the status of ISO file (whether downloading or already present).
- **Returns:** Does not return anything but exits with status 1 if the latest version is not detected.
- **Example Usage:** 
```bash
check_and_download_latest_rocky
```

### Quality and Security Recommendations
- Always validate the URL before using cURL for downloads.
- Implement error handling for failed cURL downloads and directory creations.
- Check if the global variable `HPS_DISTROS_DIR` is set before the function is called.
- Consider adding an argument to specify the architecture or ISO type gaining more flexibility.
- For security, consider verifying the checksum of the downloaded ISO to ensure it is not tampered with.

