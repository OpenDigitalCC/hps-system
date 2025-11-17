### `_collect_cluster_dirs`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 21a54dd1fed816cbbecd01967b98b68192e6453200d8c224a543b3e6b074b633

### Function Overview

The function `_collect_cluster_dirs()` is used to collect all directories from a base directory (excluding symbolic links). The base directory is specified by the global variable `HPS_CLUSTER_CONFIG_BASE_DIR`. The names of directories are stored in an array, which is passed to the function via a reference variable. If the base directory doesn't exist, the function prints an error message and exits with status zero. 

### Technical Description

- **Name:** `_collect_cluster_dirs()`
- **Description:** This bash function collects all the directory entries from the base directory specified by the `HPS_CLUSTER_CONFIG_BASE_DIR` global variable and stores them in the referenced array. It skips symbolic links and any non-directory entries.
- **Globals:** 
  - `HPS_CLUSTER_CONFIG_BASE_DIR`: Description not provided in the sample function. Presumably, this global variable specifies the base directory in which the function searches for directories.
- **Arguments:**
  1. `$1`: This is a reference to an array. The names of directories found will be added to this array.
- **Outputs:** 
  - If the base directory doesn't exist, an error message is written to the standard error output.
  - The function modifies the array passed to it via the reference variable, adding names of directories found.
- **Returns:**
  - The function always returns zero.
- **Example Usage:** 

```
# Assume that the global variable HPS_CLUSTER_CONFIG_BASE_DIR is 
# already set to some valid directory path  
declare -A my_array
_collect_cluster_dirs my_array
```

### Quality and Security Recommendations

1. Document the purpose and usage of global variables used by the function.
2. Consider having the function return non-zero status when an error is encountered, such as when the base directory doesn't exist.
3. Avoid polluting the global scope by unsetting local variables at the end of the function.
4. It would be a good security practice to sanitize inputs to the function or ensure they are of the expected type.
5. Include error handling for cases where the argument passed is not a valid reference to an array.

