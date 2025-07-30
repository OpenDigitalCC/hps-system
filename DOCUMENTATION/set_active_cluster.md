## `set_active_cluster`

Contained in `lib/functions.d/cluster-functions.sh`

### Function Overview
The `set_active_cluster` function is used to set a specified cluster as the active one in the system. It receives the cluster name as the argument and forms the cluster directory accordingly, linking it as the active cluster. This function also checks the existence of the cluster directory and the `cluster.conf` file to ensure correct input and functionality.

### Technical Description
- **Name**: set_active_cluster
- **Description**: This function sets the active cluster for a given system. It achieves this by creating a symbolic link to the specified cluster's directory from a base directory. Prior to linking, it verifies the existence of the cluster directory and a `cluster.conf` file within.
- **Globals**: 
  - `HPS_CLUSTER_CONFIG_BASE_DIR`: the base directory for cluster configurations
- **Arguments**: 
  - `$1`: `cluster_name`, the name of the cluster to be set as active
- **Outputs**: 
  - If the cluster directory does not exist: outputs an error message "[x] Cluster directory not found: $cluster_dir"
  - If the `cluster.conf` file does not exist: outputs an error message "[x] cluster.conf not found in: $cluster_dir"
  - On successful execution: outputs success message "[OK] Active cluster set to: $cluster_name"
- **Returns**: 
   - returns 1 if the cluster directory does not exist
   - returns 2 if the cluster.conf file does not exist
- **Example Usage**: 
```bash
set_active_cluster "test-cluster"
```

### Quality and Security Recommendations

1. Ensure that the `cluster_name` argument is sanitized and only accepts valid names, thereby preventing directory traversal attacks.
2. Check the write permissions on the base directory and gracefully handle scenarios where the function does not have the requisite permissions.
3. The function currently does not handle cases where the symbolic link operation fails. Error handling for such scenarios with meaningful message would improve the robustness of the script.
4. Consider encrypting important/confidential data present in the `cluster.conf` file, as the path to it could potentially be exposed.

