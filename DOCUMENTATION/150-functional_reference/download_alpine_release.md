### `download_alpine_release`

Contained in `lib/functions.d/tch-build.sh`

Function signature: f1438a9265c0b60b2947c704f30ee5980245150741b8578a6cb28e185b7cd407

### Function Overview
The bash function `download_alpine_release()` aims to download a specific version of the Alpine Linux distribution. If no version is specified, it will try to determine and download the latest available version. The specific requirements of this function include a specified Alpine version input and a path location under the `HPS_RESOURCES` environment variable where the downloaded file will be stored.

### Technical Description
- **Name**: `download_alpine_release()`
- **Description**: This shell function is designed to download the specified version of the Alpine iso and save it under a defined path. If no version is specified, it downloads the latest version. If the file already exists in destination path, it does not download but returns the file path.
- **Globals**: 
  - `HPS_RESOURCES`: The destination directory for the downloaded Alpine ISO. If not set, function will return error.
- **Arguments**: 
  - `$1` (optional): Version of the Alpine Linux distribution to download.
- **Outputs**: 
  - Outputs log messages via `hps_log()` function.
  - Prints the file path of the downloaded ISO.
- **Returns**:
  - `0` for successful downloads or if the file is already available.
  - `1` for missing `HPS_RESOURCES` or for failure in detecting the latest Alpine version.
  - `2` for failure in downloading the file.
- **Example Usage**: 
  ```bash
  download_alpine_release 3.20.2
  ```

### Quality and Security Recommendations
1. Add input validation to ensure correct format of the `alpine_version` if provided.
2. Introduce a verbose mode to provide additional information during the download process.
3. Implement checksum validation after download to ensure the integrity of the downloaded iso.
4. Make the function more general by allowing the user to define which architecture (x86_64, armv7, etc.) they would like to download instead of always downloading the x86_64 version.
5. The `HPS_RESOURCES` variable should be verified not only as a non-empty string but also as a valid writable directory.

