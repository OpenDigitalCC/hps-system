### `get_iso_path`

Contained in `lib/functions.d/iso-functions.sh`

Function signature: c9a43a62bf1aba8fb474972e5a14edb51e00a6b3ad7b99ced97edcfedfb00929

### Function Overview

The `get_iso_path` function is used in Bash to construct the path to the ISO file in a distribution directory. It verifies if the `HPS_DISTROS_DIR` global variable is set and is a directory, and if so, it concatenates the string "/iso" to it. If `HPS_DISTROS_DIR` is either not set or not a directory, it outputs an error message and returns an exit status of 1.

### Technical Description

- **Name**: `get_iso_path`
- **Description**: This function constructs the path to the ISO file within a specified directory by appending "/iso" to the `HPS_DISTROS_DIR` global variable. If `HPS_DISTROS_DIR` is not a directory or isn't set, it reports an error and exits with a status of 1.
- **Globals**:
  - `HPS_DISTROS_DIR`: The directory where distributions are stored.
- **Arguments**:
  - None.
- **Outputs**:
  - The full constructed ISO path if `HPS_DISTROS_DIR` is set and is a directory.
  - An error message directed to stderr if `HPS_DISTROS_DIR` is not set or is not a directory.
- **Returns**: 
  - 0 if the function successfully prints the path.
  - 1 if the `HPS_DISTROS_DIR` is not set or not a directory.
- **Example usage**:

```bash
path=$(get_iso_path)
if [[ $? -eq 0 ]]; then
  echo "The ISO path is: $path"
else
  echo "Unable to get ISO path."
fi
```

### Quality and Security Recommendations

1. Check if the `HPS_DISTROS_DIR` is an absolute path. Relative paths can be manipulated in unexpected ways.
2. Check if the directory is readable and not empty.
3. Apply proper error-handling to ensure meaningful error messages are returned to help in debug efforts.
4. Document the expected behavior of this function thoroughly to avoid confusion or misuse.
5. Use `set -u` to catch unset variables in the script, which may help catch bugs or errors.
6. Use `set -e` to stop script execution upon encountering an error, which can be beneficial to prevent script from continuing in an unpredictable state.

