## `get_active_cluster_filename`

Contained in `lib/functions.d/cluster-functions.sh`

### Function overview
The `get_active_cluster_filename` function is used to find and return the path to the `cluster.conf` file in an active cluster directory. 

This Bash function primarily makes use of the `readlink` utility to retrieve the target of a symbolic link to an active cluster.

### Technical description
- **Name:** `get_active_cluster_filename`
- **Description:** This function returns the path to `cluster.conf` in the directory of the active cluster. It first checks if a symbolic link to the active cluster exists. If it does, it then resolves the full path to the target of the symbolic link and appends `cluster.conf` to generate the full path of interest.
- **Globals:** 
    - `HPS_CLUSTER_CONFIG_BASE_DIR: The base directory for the cluster configuration.`
- **Arguments:**
    - `None`
- **Outputs:**
    - `The fully-qualified path to cluster.conf within the active cluster directory.`
    - `Error messages, when the symbolic link to an active cluster does not exist or cannot be resolved.`
- **Returns:**
    - `The function outputs a non-null status if the symbolic link does not exist or the target of the symbolic link cannot be resolved. Otherwise, it returns a null status.`
- **Example Usage:**
  ```bash
  get_active_cluster_filename
  ```

### Quality and security recommendations
- For this function, it's highly advised to validate before using the `HPS_CLUSTER_CONFIG_BASE_DIR` environment variable, checking if it indeed corresponds to an existing directory.
- Keep the permissions of the file `cluster.conf` and its directories restricted to avoid unauthorized access or modifications.
- It's better to suppress the possible error message thrown by the `readlink` command to avoid exposure of sensitive system information.
- The function does not handle cases where `cluster.conf` does not exist in the directory. Adding a secondary check to verify the existence of `cluster.conf` before returning the path could reduce the possibility of file not found errors downstream.

