#### `get_active_cluster_file`

Contained in `lib/functions.d/cluster-functions.sh`

Function signature: 688ac6268430b453c3ca87ba80fb648cfbbf4b3b63dabdcbb2f8a76ed8fb685d

##### Function Overview
The function `get_active_cluster_file` serves to return the contents of the active cluster configuration. It operations on a local link (`HPS_CLUSTER_CONFIG_DIR/active-cluster`) that is expected to be a symbolic link to the location of the active cluster config file (`cluster.conf`). It checks if this link exists and resolves to a valid file, in which case it will output the contents of that file. If there are any errors (the link doesn't exist, it cannot be resolved, or the resolved target is not a file), a corresponding error message is echoed and the function return with a status code of `1`.

##### Technical Description
**Name:** `get_active_cluster_file`

**Description:** This function returns the contents of the active cluster configuration file.

**Globals:** [ `HPS_CLUSTER_CONFIG_DIR`: the directory where the cluster configuration files are stored ]

**Arguments:** [ None ]

**Outputs:** Either the contents of the active cluster configuration file, or an error message if something went wrong

**Returns:** `0` if successful, `1` otherwise

**Example Usage:**
```
source cluster-utils.sh
get_active_cluster_file
```

##### Quality and Security Recommendations
1. Use more specific error codes for different error cases (e.g. `1` for missing link, `2` for unresolved link, etc.) for easier diagnosis and handling of different error conditions.
2. Use `realpath` instead of `readlink -f` to resolve symbolic links for better portability (not all systems have `readlink -f`).
3. Consider using `readlink -m` instead of `readlink -f` to resolve symbolic links without failing when the target doesn't exist, as this function might be used in a context where it's acceptable for the target to later be created.
4. Validate the contents of the configuration file before returning them to ensure they match an expected format and prevent potential code injection.
5. To prevent file path injection attacks, ensure that `HPS_CLUSTER_CONFIG_DIR` cannot be modified by untrusted users. Consider making "active-cluster" a constant rather than hardcoding it in multiple places.

