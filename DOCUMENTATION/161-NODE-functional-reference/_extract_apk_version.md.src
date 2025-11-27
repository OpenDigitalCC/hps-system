### `_extract_apk_version`

Contained in `node-manager/alpine-3/alpine-lib-functions.sh`

Function signature: eb0d9b3cde2db7f28ef70b36d8d6c4d6407f51ef1ca999daff92c5de88823f30

### Function Overview

The function `_extract_apk_version` is used to extract an Application Package (APK) version from a given filename. The function accepts two arguments, the filename and the package name, and processes the filename to remove the package name prefix and the .apk suffix, thus returning the version of the APK.

### Technical Description

- **Name**: `_extract_apk_version`
- **Description**: Extracts the version information from an APK filename by removing the package name prefix and the .apk suffix.
- **Globals**: None.
- **Arguments**: [$1: `filename` (name of the APK file), $2: `pkg_name` (name of the package)]
- **Outputs**: Version information extracted from the filename.
- **Returns**: Returns the version information string.
- **Example usage**: 
```sh
_extract_apk_version package-1.0.0.apk package
# output: 1.0.0
```

### Quality and Security Recommendations

1. Consider validating the inputs: Currently, the function doesn't check if the inputs are valid before processing them. You should validate whether the filename and package name provided follow the expected format.
2. Adding error handling: The function doesn't have any error handling if the filename or package name doesn't match the expected structure. It'd be beneficial to add some error handling to let the user know why the function might not be working as expected.
3. Sanitization of inputs: Although Bash scripting does not pose traditional vulnerabilities to injection attacks as seen in other forms of programming, it is still good practice to sanitize inputs to avoid unexpected behaviors.
4. Usage of local variables: The function already uses local variables which is good for encapsulation but its usage should be continued to avoid inadvertent changes in global variables.
5. Write a more descriptive comment: The current comment only briefly describes the function's purpose. A better comment might also mention the format of the filename, what inputs are expected, and what output is given.

