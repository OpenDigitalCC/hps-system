### `get_active_cluster_dir`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: bea86c9b08f47ce60a2602b8a8391990588b8ca0b96c0252ba0070cc3623cfce

### Function overview

The `get_active_cluster_dir` function is fundamental to resolving symlinks and retrieving the path of the currently active cluster directory in a system. It defines multiple local variables to find and check the authenticity of this directory, subsequently echoing its path if satisfactory conditions are fulfilled.

### Technical description

- **Name**: `get_active_cluster_dir`
- **Description**: This function works to resolve the symlink of the active cluster and retrieve its directory. It does this by storing the symlink and its full path in local variables, verifying their validity, checking if the stored full path is a directory, and if so, outputs the directory. It returns an error if the symlink fails to resolve or the target isn't a directory.
- **Globals**: None.
- **Arguments**: None.
- **Outputs**: If successful, the function will print the directory of the active cluster. Error messages will be printed to stderr in any of the following cases: 
  - The symlink can't be resolved. 
  - The active cluster target is not a directory.
- **Returns**: 0 if the function is successful. Returns 1 if the symlink can't be resolved or the target is not a directory.
- **Example Usage**:
  ```
  get_active_cluster_dir 
  ```

### Quality and security recommendations

1. Verify if the `get_active_cluster_link` function and the `get_cluster_dir` function used within `get_active_cluster_dir` are secure and optimized. The efficiency of `get_active_cluster_dir` is highly dependent on the performance of these two.
2. Error messages are redirected to stderr, which is a best practice and should be continued.
3. Ensure that this function is running with the right privileges - it should not have more permissions than what is required to read the link and possibly traverse directories.
4. Sanitize the output of the `readlink` and `basename` command to prevent potential path manipulation or symbolic link attacks.
5. Implement unit tests for this function to safeguard it from potential edge cases and bugs.

