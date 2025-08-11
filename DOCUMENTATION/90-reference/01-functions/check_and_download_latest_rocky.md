#### `check_and_download_latest_rocky`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: ac86f8c78c7149b4fbc3125a2f52dd65b160ad01f437b5eeb5b504bd1a90c6b1

##### Function Overview

The `check_and_download_latest_rocky` function in Bash is used to check for and download the latest version of Rocky Linux in ISO format. It will first check for the latest version available at a defined URL and then proceed to download it if the ISO does not already exist in the specified directory. Additionally, it sends the ISO for extraction to support PXE booting.

##### Technical Description

- Function name: `check_and_download_latest_rocky`
- Description: This function, written in Bash, checks for the latest version of Rocky Linux at the provided URL, downloads it as an ISO file if it does not exist in the user defined directory, and sends the ISO for extraction to support PXE boot functionalities. 
- Globals: [ `HPS_DISTROS_DIR`: this is the directory where the downloaded ISOs are stored ]
- Arguments: None
- Outputs: Echo statements informing the user of the current process (check for latest version, downloading the ISO or finding it already present in the directory).
- Returns: The function does not explicitly return a value. However, the effect of function is the Rocky Linux ISO being downloaded and stored in the user defined directory.
- Example Usage: `check_and_download_latest_rocky`

##### Quality and Security Recommendations

1. The function does not currently have any error handing built in. It is recommended to add error handling steps to make this function more robust and user-friendly.
2. As a good practice for bash scripts, it is suggested to quote your variables as to avoid unexpected behavior from word splitting and pathname expansion. For example, use `"$iso_path"` instead of `$iso_path`.
3. Make download URL, architecture, and other variables taking static values parameters to the function to make it more reusable and flexible.
4. Replace echo statements for user feedback with a proper and more detailed logging system for easier debugging and traceability.
5. Always validate the downloaded ISO to ensure its integrity and safety. This function currently may download an ISO but does not complete any kind of validity or safety check on it.
6. Secure your curl download with the appropriate security flags. The flags `--fail --show-error --location` are not enough to ensure a secure download.

